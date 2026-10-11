// Full-system bench: the whole machine from reset behind the MiSTer memory subsystem, the ROM image
// streamed in through the loader, video out. Runs N frames and writes the frames asked for as raw
// RGB (288 x 224, 32-bit little-endian 0x00RRGGBB), a per-frame trace, and the audio as a WAV.
//
//   tb_mm <image.rom> <eeprom.nv> <frames> <out-prefix>
//
// Environment:
//   SNAPFRAMES=a,b,c   frames whose picture is saved as <prefix>.f<N>.rgb (default: the last)
//   SCHED=survey       MAME's scripted inputs of tools/lua/dump_state.lua (coin, start, buttons), by frame
//   SCHEDLAG=n         apply the SCHED inputs n frames later (this core's timeline trails MAME's by about 2)
//   SKIPDLY=1          cut the boot's software delay loop (512 x 8,192 iterations, 217 frames) to 512 x 17
//   SKIPCHK=1          patch the program (any set: the call site is found by its code) to jump over the
//                      power-on memory check: a simulation shortcut, not part of any image
//   AUDIO=1            write <prefix>.wav (48 kHz stereo)
//   TRACE=1            one line a frame in <prefix>.trace
//   DUMPSTATE=a,b,c    at the end of those frames, write the video chips' registers and RAMs to
//                      <prefix>.state_<N>.txt in the sections of MAME's tools/lua/dump_state.lua
//                      (tools/cmp_state.py compares the two)
#include "Vtb_mm_top.h"
#include "Vtb_mm_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <set>
#include <map>
#include <string>
#include <algorithm>

static const int VIS_W = 288, VIS_H = 224;

static Vtb_mm_top *dut;
static unsigned long long cycles = 0;
static inline void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }

// the video chips' registers and RAMs as tools/lua/dump_state.lua writes them (a word is 4 hex digits)
static void dump_state(const char *path, int frame) {
    auto &r = *dut->rootp;
    FILE *f = fopen(path, "w"); if (!f) return;
    fprintf(f, "# monster maulers core state, frame %d\nFRAME %d\n", frame, frame);
    auto words = [&](const char *name, int n, auto get) {
        fprintf(f, "%s", name);
        for (int i = 0; i < n; i++) fprintf(f, " %04x", (unsigned)get(i) & 0xffff);
        fprintf(f, "\n");
    };
    words("K56REGS", 32, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__k56regs[i]; });
    words("K56REGSB", 4, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__k56regsb[i]; });
    words("K46REGS", 8, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__k46regs[i]; });
    words("K47REGS", 8, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__k47regs[i]; });
    words("K55REGS", 48, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__k55regs[i]; });
    words("K38REGS", 16, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__k38regs[i]; });
    words("ROZCLIP", 2, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__rozclip[i]; });
    words("PALETTE", 4096, [&](int i) {
        unsigned e = i >> 1;
        return (i & 1) ? r.tb_mm_top__DOT__u_core__DOT__u_main__DOT__pal1[e] : r.tb_mm_top__DOT__u_core__DOT__u_main__DOT__pal0[e]; });
    words("ROZCT16", 16, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__rozctrl[i]; });
    words("ROZLI16", 2048, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__u_main__DOT__rozli[i]; });
    words("SPRITERAM", 2048, [&](int i) { return r.tb_mm_top__DOT__u_core__DOT__u_main__DOT__sram[i]; });
    for (int pg = 0; pg < 16; pg++) {
        char nm[16]; snprintf(nm, sizeof nm, "VRAM %d", pg);
        words(nm, 4096, [&](int i) {
            unsigned a = (pg << 12) | i;
            return ((unsigned)r.tb_mm_top__DOT__u_mem__DOT__u_vram__DOT__ram_hi[a] << 8) | r.tb_mm_top__DOT__u_mem__DOT__u_vram__DOT__ram_lo[a]; });
    }
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: %s <image.rom> <eeprom.nv> <frames> <out-prefix>\n", argv[0]); return 2; }
    int frames = atoi(argv[3]);
    std::string prefix = argv[4];

    std::vector<unsigned char> img;
    { FILE *f = fopen(argv[1], "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
      fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET); img.resize(n);
      if (fread(img.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); return 1; } fclose(f); }
    std::vector<unsigned char> nv(128, 0);
    { FILE *f = fopen(argv[2], "rb"); if (f) { if (fread(nv.data(), 1, 128, f) != 128) fprintf(stderr, "short nv\n"); fclose(f); } }
    // the two shortcuts' patch points are found by their code, so every set (EAA, UAA, JAA) is handled alike
    auto find_code = [&](const std::vector<unsigned char> &pat) -> long {
        for (size_t a = 0x1000; a + pat.size() < 0x8000 && a + pat.size() < img.size(); a++)
            if (!memcmp(&img[a], pat.data(), pat.size())) return (long)a;
        return -1;
    };
    if (getenv("SKIPCHK") && atoi(getenv("SKIPCHK"))) {
        // tst.l d0 / bne.s back / jmp <where the check's success path continues>: the call site, 0x16 bytes
        // before, becomes that jmp ($002eec -> $004114 in the EAA set)
        long h = find_code({0x4a, 0x80, 0x66, 0xee, 0x4e, 0xf9, 0x00, 0x00});
        if (h < 0) { fprintf(stderr, "SKIPCHK: memory-check code not found\n"); return 1; }
        memcpy(&img[h - 0x16], &img[h + 4], 6);
        printf("SKIPCHK: JMP $%02x%02x%02x%02x at $%06lx\n", img[h + 6], img[h + 7], img[h + 8], img[h + 9], (long)(h - 0x16));
    }

    if (getenv("SKIPDLY") && atoi(getenv("SKIPDLY"))) {
        // the boot's software delay (512 x 8,192 iterations of nop / dbf at $00422a in the EAA set: 3.7 s, 217
        // frames) cut to 512 x 17: move.w #$2000,d6 becomes move.w #$0010,d6. Simulation shortcut only;
        // MAME's tools/lua/*.lua apply the same with SKIPDLY=1
        long h = find_code({0x3c, 0x3c, 0x20, 0x00, 0x4e, 0x71, 0x51, 0xce, 0xff, 0xfc});
        if (h < 0) { fprintf(stderr, "SKIPDLY: delay loop not found\n"); return 1; }
        img[h + 2] = 0x00; img[h + 3] = 0x10;
        printf("SKIPDLY: delay loop count $0010 at $%06lx\n", (long)(h + 2));
    }
    std::set<int> snaps;
    if (getenv("SNAPFRAMES")) { char *w = strdup(getenv("SNAPFRAMES")); for (char *t = strtok(w, ","); t; t = strtok(nullptr, ",")) snaps.insert(atoi(t)); }
    std::set<int> dumps;
    if (getenv("DUMPSTATE")) { char *w = strdup(getenv("DUMPSTATE")); for (char *t = strtok(w, ","); t; t = strtok(nullptr, ",")) dumps.insert(atoi(t)); }
    bool survey = getenv("SCHED") && !strcmp(getenv("SCHED"), "survey");
    int schedlag = getenv("SCHEDLAG") ? atoi(getenv("SCHEDLAG")) : 0;   // the machine's timeline runs this many frames behind MAME's
    bool want_audio = getenv("AUDIO") && atoi(getenv("AUDIO"));
    FILE *tr = (getenv("TRACE") && atoi(getenv("TRACE"))) ? fopen((prefix + ".trace").c_str(), "w") : nullptr;

    dut = new Vtb_mm_top;
    dut->reset = 1; dut->dl_hold = 1; dut->dl_start = 0; dut->dl_we = 0; dut->eep_we = 0;
    dut->in0_p1 = 0xffff; dut->in1 = 0xff & ~0x10 & ~0x04; dut->p2 = 0xff;
    for (int i = 0; i < 16; i++) tick();
    dut->reset = 0;
    // wait for the SDRAM's initialisation and the caches
    long w = 0;
    while (!dut->mem_ready) { tick(); if (++w > 2000000) { fprintf(stderr, "memory never became ready\n"); return 1; } }
    printf("memory ready after %llu clocks; loading %zu bytes\n", cycles, img.size());

    bool backdoor = getenv("BACKDOOR") && atoi(getenv("BACKDOOR"));
    unsigned long long t0 = cycles;
    if (backdoor) {
        // straight into the SDRAM and DDR3 models, in the places the loader (target/mister/mm_mem.sv) puts
        // the words: the same address arithmetic, so the loader itself is covered by the streamed run
        auto &sd = dut->rootp->tb_mm_top__DOT__chip__DOT__mem;
        auto &dd = dut->rootp->tb_mm_top__DOT__ddr__DOT__mem;
        const unsigned SD_TILE = 0x000000, SD_PCM = 0x180000, SD_SPR = 0x380000, SD_PROG = 0x880000, SD_SND = 0x980000;
        const unsigned DD_MAP = 0x00000, DD_CHR = 0x20000;
        for (size_t wa = 0; wa < img.size() / 2; wa++) {
            unsigned v = ((unsigned)img[wa * 2] << 8) | img[wa * 2 + 1];
            size_t b = wa * 2;
            if (b < 0x200000) sd[SD_PROG + wa] = v;
            else if (b < 0x240000) sd[SD_SND + (wa - 0x100000)] = v;
            else if (b < 0x640000) {
                size_t r = wa - 0x120000; size_t g = r >> 2; unsigned j = r & 3;
                if (j < 3) sd[SD_TILE + 3 * g + j] = v;
            } else if (b < 0x7C0000) {
                size_t r = wa - 0x320000;
                unsigned w16 = (unsigned)(((r >> 7) << 7) | ((r & 7) << 4) | ((r >> 3) & 15));
                dd[DD_CHR + (w16 >> 2)] = (dd[DD_CHR + (w16 >> 2)] & ~(0xffffULL << (16 * (w16 & 3)))) | ((unsigned long long)v << (16 * (w16 & 3)));
            } else if (b < 0x840000) {
                size_t r = wa - 0x3E0000;
                dd[DD_MAP + (r >> 2)] = (dd[DD_MAP + (r >> 2)] & ~(0xffffULL << (16 * (r & 3)))) | ((unsigned long long)v << (16 * (r & 3)));
            } else if (b < 0xC40000) sd[SD_PCM + (wa - 0x420000)] = v;
            else if (b < 0x1440000) {
                size_t r = wa - 0x620000; size_t u = r >> 2; unsigned j = r & 3;
                sd[SD_SPR + 5 * u + j] = v;
            } else if (b < 0x1640000) {
                size_t k = wa - 0xA20000;
                sd[SD_SPR + 5 * k + 4] = v;
            }
        }
        printf("image placed by the backdoor\n");
    } else {
    // the image, a byte at a time as the HPS delivers it, held off while the loader's FIFO is full
    dut->dl_start = 1; tick(); dut->dl_start = 0;
    for (size_t i = 0; i < img.size(); i++) {
        while (dut->dl_wait) tick();
        dut->dl_we = 1; dut->dl_addr = (unsigned)i; dut->dl_data = img[i]; tick();
        dut->dl_we = 0;
        if ((i & 0xfffff) == 0xfffff) { printf("  %zu MB loaded\n", (i + 1) >> 20); fflush(stdout); }
    }
    dut->dl_we = 0;
    for (int i = 0; i < 4000; i++) tick();                         // the loader drains
    }
    for (int i = 0; i < 128; i++) { dut->eep_we = 1; dut->eep_waddr = i; dut->eep_wdata = nv[i]; tick(); }
    dut->eep_we = 0;
    printf("image loaded in %llu clocks\n", cycles - t0);
    dut->dl_hold = 0;

    std::vector<unsigned> fb(VIS_W * VIS_H, 0);
    std::vector<short> audio;
    int frame = 0, x = 0, y = 0;
    bool prev_vblank = true;
    unsigned long long steps = 0, frame_steps = 0;
    unsigned irq = 0, zsteps = 0, dma_clk = 0, overruns = 0, de_px = 0;
    bool irq_seen = false, prev_irq = false;
    unsigned vc_last = 0xffff;
    bool lat_in = false; unsigned long long lat_t0 = 0; std::map<unsigned, unsigned> lat_hist;
    unsigned last_pc = 0;
    std::map<unsigned, unsigned> pc_hist;
    unsigned in0 = 0xffff;
    auto sched = [&](int n) -> unsigned {       // tools/lua/dump_state.lua's "survey" schedule
        unsigned v = 0xffff;
        if (n > 200 && (n % 120) < 8) v &= ~0x0100u;                                 // coin 1
        if (n > 260 && (n % 90) < 8 && (n % 120) >= 8) v &= ~0x0080u;                // start 1
        if (n > 500) {
            if (n % 11 < 4) v &= ~0x0010u;       // button 1
            if (n % 29 < 3) v &= ~0x0020u;       // button 2
            if (n % 97 < 40) v &= ~0x0002u;      // right
            if (n % 131 > 100) v &= ~0x0001u;    // left
            if (n % 53 < 20) v &= ~0x0004u;      // up
            if (n % 71 > 60) v &= ~0x0008u;      // down
        }
        return v;
    };

    unsigned long long ck0 = cycles;
    // ROMCHK=1: every tile / sprite / map read the renderers complete is compared with what the image holds
    bool romchk = getenv("ROMCHK") && atoi(getenv("ROMCHK"));
    unsigned long long chk_n[3] = {0, 0, 0}, chk_bad[3] = {0, 0, 0};
    bool prev_tack = false, prev_sack = false, prev_mack = false;
    bool watch46 = getenv("WATCH46") && atoi(getenv("WATCH46"));
    unsigned k46_prev[8] = {0};
    while (frame < frames) {
        tick();
        if (romchk) {
            auto &r = *dut->rootp;
            bool ta = r.tb_mm_top__DOT__chk_tile_ack, sa = r.tb_mm_top__DOT__chk_spr_ack, ma = r.tb_mm_top__DOT__chk_map_ack;
            if (ta && !prev_tack) {
                unsigned a = r.tb_mm_top__DOT__chk_tile_addr; unsigned long long q = r.tb_mm_top__DOT__chk_tile_q;
                unsigned long long e = 0; for (int b = 0; b < 5; b++) e = (e << 8) | img[0x240000 + (size_t)a * 8 + b];
                chk_n[0]++;
                if (q != e) { if (chk_bad[0] < 6) printf("TILE a=%05x got %010llx want %010llx (frame %d)\n", a, q, e, frame); chk_bad[0]++; }
            }
            if (sa && !prev_sack) {
                unsigned a = r.tb_mm_top__DOT__chk_spr_addr;
                // 80 bits: [79:16] = the row's 8 bytes, [15:0] = the fifth plane word
                unsigned long long hi = 0; for (int b = 0; b < 8; b++) hi = (hi << 8) | img[0xC40000 + (size_t)a * 8 + b];
                unsigned p5 = ((unsigned)img[0x1440000 + (size_t)a * 2] << 8) | img[0x1440000 + (size_t)a * 2 + 1];
                auto &q = r.tb_mm_top__DOT__chk_spr_q;
                unsigned long long qhi = ((unsigned long long)q[2] << 48) | ((unsigned long long)q[1] << 16) | (q[0] >> 16);
                unsigned qp5 = q[0] & 0xffff;
                chk_n[1]++;
                if (qhi != hi || qp5 != p5) { if (chk_bad[1] < 6) printf("SPR a=%05x got %016llx/%04x want %016llx/%04x (frame %d)\n", a, qhi, qp5, hi, p5, frame); chk_bad[1]++; }
            }
            if (ma && !prev_mack) {
                unsigned a = r.tb_mm_top__DOT__chk_map_addr; unsigned q = r.tb_mm_top__DOT__chk_map_q;
                // the map port returns the 16-bit big-endian pair at the even byte of the 512 KB map region
                unsigned e = ((unsigned)img[0x7C0000 + (a & ~1u)] << 8) | img[0x7C0000 + (a & ~1u) + 1];
                chk_n[2]++;
                if (q != e) { if (chk_bad[2] < 6) printf("MAP a=%05x got %04x want %04x (frame %d)\n", a, q, e, frame); chk_bad[2]++; }
            }
            prev_tack = ta; prev_sack = sa; prev_mack = ma;
        }
        if (watch46) {
            auto &r = *dut->rootp;
            for (int i = 0; i < 8; i++) {
                unsigned v = r.tb_mm_top__DOT__u_core__DOT__k46regs[i];
                if (v != k46_prev[i]) {
                    printf("K46 reg %d: %02x -> %02x  frame %d clk %llu last 68000 fetch pc %06x\n", i, k46_prev[i], v, frame, cycles, last_pc);
                    k46_prev[i] = v;
                }
            }
        }
        {   // the sprite ROM port's latency, request to ack (the memory subsystem under the machine's own traffic)
            auto &r = *dut->rootp;
            bool sr = r.tb_mm_top__DOT__chk_spr_req, sa = r.tb_mm_top__DOT__chk_spr_ack;
            if (sr && !lat_in) { lat_in = true; lat_t0 = cycles; }
            if (sa && lat_in) { lat_hist[(unsigned)(cycles - lat_t0)]++; lat_in = false; }
            if (!sr) lat_in = false;
        }
        if (want_audio && dut->snd_valid) { audio.push_back((short)dut->snd_l); audio.push_back((short)dut->snd_r); }
        if (dut->dbg_zstep) zsteps++;
        if (dut->dbg_dma) dma_clk++;
        if (dut->dbg_vcount != vc_last) { vc_last = dut->dbg_vcount; if (dut->dbg_overrun) overruns++; }
        if (dut->dbg_step) {
            steps++; frame_steps++;
            if (dut->dbg_busstate == 0) { last_pc = dut->dbg_addr; pc_hist[last_pc]++; }
        }
        if (dut->dbg_irq5 && !prev_irq) irq_seen = true;
        prev_irq = dut->dbg_irq5;
        if (dut->cen_pix) {
            if (dut->de) {
                if (y >= 0 && y < VIS_H && x < VIS_W) fb[y * VIS_W + x] = dut->rgb;
                x++; de_px++;
            } else if (x) { x = 0; y++; }
            if (dut->vblank && !prev_vblank) {          // the end of a frame
                frame++;
                if (tr) {
                    unsigned hot = 0, hotn = 0;
                    for (auto &kv : pc_hist) if (kv.second > hotn) { hotn = kv.second; hot = kv.first; }
                    fprintf(tr, "frame %d: steps=%llu irq5=%d objs=%u overrun=%u unsup=%d de_px=%u pc=%06x hot=%06x(%u) zsteps=%u dma=%u eep_dirty=%d\n",
                            frame, frame_steps, irq_seen, (unsigned)dut->dbg_objcount, overruns, (int)dut->dbg_unsupported,
                            de_px, last_pc, hot, hotn, zsteps, dma_clk, (int)dut->eep_dirty);
                    fflush(tr);
                }
                pc_hist.clear(); zsteps = 0; dma_clk = 0; overruns = 0; frame_steps = 0; de_px = 0;
                if (irq_seen) irq++;
                irq_seen = false;
                if (snaps.count(frame) || (snaps.empty() && frame == frames)) {
                    char path[512]; snprintf(path, sizeof path, "%s.f%d.rgb", prefix.c_str(), frame);
                    FILE *o = fopen(path, "wb"); if (o) { fwrite(fb.data(), 4, fb.size(), o); fclose(o); }
                }
                if (dumps.count(frame)) {
                    char path[512]; snprintf(path, sizeof path, "%s.state_%d.txt", prefix.c_str(), frame);
                    dump_state(path, frame);
                }
                if (frame % 50 == 0) {
                    double mcps = (double)(cycles - ck0) / 1e6;
                    printf("frame %d (%.1f M clocks)\n", frame, mcps); fflush(stdout);
                }
                in0 = survey ? sched(frame + 1 - schedlag) : 0xffff;
                dut->in0_p1 = in0;
                y = 0; x = 0;
            }
            prev_vblank = dut->vblank;
        }
    }
    if (romchk) printf("ROM check: tile reads %llu (%llu wrong), sprite reads %llu (%llu wrong), map reads %llu (%llu wrong)\n",
                       chk_n[0], chk_bad[0], chk_n[1], chk_bad[1], chk_n[2], chk_bad[2]);
    printf("%d frames, %llu clocks, %llu 68000 steps (%.0f a frame); IRQ5 in %u frames; unsupported=%d shadow_overlap=%d ddr_overflow=%d\n",
           frames, cycles, steps, (double)steps / frames, irq, (int)dut->dbg_unsupported, (int)dut->dbg_shadow_overlap, (int)dut->ddr_overflow);
    if (!lat_hist.empty()) {
        unsigned long long tot = 0, sum = 0;
        for (auto &kv : lat_hist) { tot += kv.second; sum += (unsigned long long)kv.first * kv.second; }
        auto pct = [&](double q) { unsigned long long acc = 0; for (auto &kv : lat_hist) { acc += kv.second; if (acc >= q * tot) return kv.first; } return 0u; };
        printf("sprite ROM port latency (clocks, request to ack): %llu requests, mean %.1f, p50 %u, p90 %u, p99 %u, max %u\n",
               tot, (double)sum / tot, pct(0.5), pct(0.9), pct(0.99), lat_hist.rbegin()->first);
    }
    if (want_audio) {
        std::string wp = prefix + ".wav";
        FILE *wf = fopen(wp.c_str(), "wb");
        if (wf) {
            unsigned data_bytes = audio.size() * 2, rate = 48000;
            auto u32 = [&](unsigned v) { fputc(v & 255, wf); fputc((v >> 8) & 255, wf); fputc((v >> 16) & 255, wf); fputc((v >> 24) & 255, wf); };
            auto u16 = [&](unsigned v) { fputc(v & 255, wf); fputc((v >> 8) & 255, wf); };
            fwrite("RIFF", 1, 4, wf); u32(36 + data_bytes); fwrite("WAVEfmt ", 1, 8, wf);
            u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16);
            fwrite("data", 1, 4, wf); u32(data_bytes);
            fwrite(audio.data(), 2, audio.size(), wf); fclose(wf);
            printf("audio: %zu stereo samples -> %s\n", audio.size() / 2, wp.c_str());
        }
    }
    if (tr) fclose(tr);
    delete dut;
    return 0;
}
