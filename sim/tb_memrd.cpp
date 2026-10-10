// Memory-subsystem gate: the ROM image goes in through the loader (or straight into the chips with
// BACKDOOR=1), then every region is read back through the ports the machine uses -- 68000 program,
// Z80 program, PCM, tile rows (3-word bursts), ROZ map, sprite rows (5-word bursts), ROZ character
// blocks (DDR3, 128 words in {x/2, row} order) -- and compared with the image, at random addresses
// and at the ends of every region.
//
//   tb_memrd <image.rom> [reads per port, default 20000]
// Environment: BACKDOOR=1 places the image directly (the same address arithmetic as the loader),
//              SEED=n
#include "Vtb_memrd_top.h"
#include "Vtb_memrd_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static Vtb_memrd_top *dut;
static unsigned long long cycles = 0;
static inline void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }

static std::vector<unsigned char> img;
static const size_t O_PROG = 0x0, O_SND = 0x200000, O_TILE = 0x240000, O_CHR = 0x640000, O_MAP = 0x7C0000,
                    O_PCM = 0x840000, O_SPR = 0xC40000, O_SPR5 = 0x1440000, O_END = 0x1640000;
static unsigned long long errors = 0;

static unsigned long long rng_s = 88172645463325252ull;
static unsigned rnd() { rng_s ^= rng_s << 13; rng_s ^= rng_s >> 7; rng_s ^= rng_s << 17; return (unsigned)(rng_s >> 16); }

#define WAIT_ACK(ack, what)                                                              \
    { int g = 0; while (!dut->ack) { tick(); if (++g > 20000) { printf("TIMEOUT %s\n", what); errors++; return; } } }

static void gap() { for (int i = 0, n = rnd() % 5; i < n; i++) tick(); }

static void rd_prog(unsigned a) {      // a: word address
    dut->prog_addr = a; dut->prog_req = 1; WAIT_ACK(prog_ack, "prog");
    unsigned want = ((unsigned)img[O_PROG + 2 * a] << 8) | img[O_PROG + 2 * a + 1];
    if (dut->prog_q != want) { if (errors < 20) printf("PROG w=%06x got %04x want %04x\n", a, dut->prog_q, want); errors++; }
    dut->prog_req = 0; tick(); tick(); gap();
}
static void rd_snd(unsigned a) {
    dut->snd_addr = a; dut->snd_req = 1; WAIT_ACK(snd_ack, "snd");
    unsigned want = img[O_SND + a];
    if (dut->snd_q != want) { if (errors < 20) printf("SND a=%05x got %02x want %02x\n", a, dut->snd_q, want); errors++; }
    dut->snd_req = 0; tick(); tick(); gap();
}
static void rd_pcm(unsigned a) {
    dut->pcm_addr = a; dut->pcm_req = 1; WAIT_ACK(pcm_ack, "pcm");
    unsigned want = img[O_PCM + a];
    if (dut->pcm_q != want) { if (errors < 20) printf("PCM a=%06x got %02x want %02x\n", a, dut->pcm_q, want); errors++; }
    dut->pcm_req = 0; tick(); tick(); gap();
}
static void rd_tile(unsigned a) {
    dut->tile_addr = a; dut->tile_req = 1; WAIT_ACK(tile_ack, "tile");
    unsigned long long want = 0;
    for (int b = 0; b < 5; b++) want = (want << 8) | img[O_TILE + (size_t)a * 8 + b];
    unsigned long long got = dut->tile_q;
    if (got != want) { if (errors < 20) printf("TILE g=%05x got %010llx want %010llx\n", a, got, want); errors++; }
    dut->tile_req = 0; tick(); tick(); gap();
}
static void rd_map(unsigned a) {
    dut->map_addr = a; dut->map_req = 1; WAIT_ACK(map_ack, "map");
    unsigned e = a & ~1u;
    unsigned want = ((unsigned)img[O_MAP + e] << 8) | img[O_MAP + e + 1];
    if (dut->map_q != want) { if (errors < 20) printf("MAP a=%05x got %04x want %04x\n", a, dut->map_q, want); errors++; }
    dut->map_req = 0; tick(); tick(); gap();
}
static void rd_spr(unsigned a) {
    dut->spr_addr = a; dut->spr_req = 1; WAIT_ACK(spr_ack, "spr");
    unsigned long long hi = 0;
    for (int b = 0; b < 8; b++) hi = (hi << 8) | img[O_SPR + (size_t)a * 8 + b];
    unsigned p5 = ((unsigned)img[O_SPR5 + (size_t)a * 2] << 8) | img[O_SPR5 + (size_t)a * 2 + 1];
    // 80 bits in three 32-bit words: [79:16] the row, [15:0] the fifth plane
    unsigned long long qhi = ((unsigned long long)dut->spr_q[2] << 48) | ((unsigned long long)dut->spr_q[1] << 16) | (dut->spr_q[0] >> 16);
    unsigned qp5 = dut->spr_q[0] & 0xffff;
    if (qhi != hi || qp5 != p5) { if (errors < 20) printf("SPR u=%05x got %016llx/%04x want %016llx/%04x\n", a, qhi, qp5, hi, p5); errors++; }
    dut->spr_req = 0; tick(); tick(); gap();
}
static void rd_blk(unsigned t) {
    std::vector<int> got(128, -1);
    dut->blk_addr = t; dut->blk_req = 1;
    int g = 0;
    while (!dut->blk_ack) {
        tick();
        if (dut->blk_wr) got[dut->blk_idx] = dut->blk_data;
        if (++g > 20000) { printf("TIMEOUT blk\n"); errors++; return; }
    }
    if (dut->blk_wr) got[dut->blk_idx] = dut->blk_data;
    int bad = 0;
    for (int w = 0; w < 128; w++) {
        int idx = ((w & 7) << 4) | (w >> 3);
        unsigned want = ((unsigned)img[O_CHR + (size_t)t * 256 + w * 2] << 8) | img[O_CHR + (size_t)t * 256 + w * 2 + 1];
        if (got[idx] != (int)want) { if (!bad && errors < 20) printf("BLK tile %04x word %d (idx %d): got %04x want %04x\n", t, w, idx, got[idx] & 0xffff, want); bad++; }
    }
    if (bad) errors++;
    dut->blk_req = 0; tick(); tick(); gap();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <image.rom> [reads]\n", argv[0]); return 2; }
    int N = argc > 2 ? atoi(argv[2]) : 20000;
    { FILE *f = fopen(argv[1], "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
      img.resize(O_END); if (fread(img.data(), 1, O_END, f) != O_END) { fprintf(stderr, "short image\n"); return 1; } fclose(f); }
    if (getenv("SEED")) rng_s ^= (unsigned long long)atoll(getenv("SEED")) * 0x9E3779B97F4A7C15ull;
    dut = new Vtb_memrd_top;
    dut->reset = 1; dut->dl_start = 0; dut->dl_we = 0;
    dut->prog_req = dut->snd_req = dut->pcm_req = dut->tile_req = dut->map_req = dut->spr_req = dut->blk_req = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->reset = 0;
    for (long w = 0; !dut->mem_ready; w++) { tick(); if (w > 2000000) { printf("memory never became ready\n"); return 1; } }
    printf("memory ready after %llu clocks\n", cycles);

    unsigned long long t0 = cycles;
    if (getenv("BACKDOOR") && atoi(getenv("BACKDOOR"))) {
        auto &sd = dut->rootp->tb_memrd_top__DOT__chip__DOT__mem;
        auto &dd = dut->rootp->tb_memrd_top__DOT__ddr__DOT__mem;
        const unsigned SD_TILE = 0x000000, SD_PCM = 0x180000, SD_SPR = 0x380000, SD_PROG = 0x880000, SD_SND = 0x980000;
        const unsigned DD_MAP = 0x00000, DD_CHR = 0x20000;
        for (size_t wa = 0; wa < O_END / 2; wa++) {
            unsigned v = ((unsigned)img[wa * 2] << 8) | img[wa * 2 + 1];
            size_t b = wa * 2;
            if (b < 0x200000) sd[SD_PROG + wa] = v;
            else if (b < 0x240000) sd[SD_SND + (wa - 0x100000)] = v;
            else if (b < 0x640000) { size_t r = wa - 0x120000; if ((r & 3) < 3) sd[SD_TILE + 3 * (r >> 2) + (r & 3)] = v; }
            else if (b < 0x7C0000) {
                size_t r = wa - 0x320000;
                unsigned w16 = (unsigned)(((r >> 7) << 7) | ((r & 7) << 4) | ((r >> 3) & 15));
                dd[DD_CHR + (w16 >> 2)] = (dd[DD_CHR + (w16 >> 2)] & ~(0xffffULL << (16 * (w16 & 3)))) | ((unsigned long long)v << (16 * (w16 & 3)));
            } else if (b < 0x840000) {
                size_t r = wa - 0x3E0000;
                dd[DD_MAP + (r >> 2)] = (dd[DD_MAP + (r >> 2)] & ~(0xffffULL << (16 * (r & 3)))) | ((unsigned long long)v << (16 * (r & 3)));
            } else if (b < 0xC40000) sd[SD_PCM + (wa - 0x420000)] = v;
            else if (b < 0x1440000) { size_t r = wa - 0x620000; sd[SD_SPR + 5 * (r >> 2) + (r & 3)] = v; }
            else sd[SD_SPR + 5 * (wa - 0xA20000) + 4] = v;
        }
        printf("image placed by the backdoor\n");
    } else {
        dut->dl_start = 1; tick(); dut->dl_start = 0;
        for (size_t i = 0; i < O_END; i++) {
            while (dut->dl_wait) tick();
            dut->dl_we = 1; dut->dl_addr = (unsigned)i; dut->dl_data = img[i]; tick();
            dut->dl_we = 0;
        }
        for (int i = 0; i < 6000; i++) tick();
        printf("image streamed in %llu clocks\n", cycles - t0);
    }
    // the caches are swept at the start of a download; give them time to finish
    for (int i = 0; i < 20000; i++) tick();

    // the ends of every region, then random addresses
    rd_prog(0); rd_prog(1); rd_prog(0x1fffff >> 1); rd_prog(0x100000 >> 1);
    rd_snd(0); rd_snd(0x3ffff);
    rd_pcm(0); rd_pcm(0x3fffff);
    rd_tile(0); rd_tile(1); rd_tile(0x7ffff); rd_tile(0x80000 - 1 - 255);
    rd_map(0); rd_map(0x7fffe); rd_map(0x40000);
    rd_spr(0); rd_spr(0xfffff); rd_spr(0x7ffff);
    rd_blk(0); rd_blk(1); rd_blk(6143);
    for (int i = 0; i < N; i++) {
        rd_prog(rnd() & 0x1fffff >> 0 & 0xfffff);                       // 1 MB of word addresses (2 MB)
        rd_snd(rnd() & 0x3ffff);
        rd_pcm(rnd() & 0x3fffff);
        rd_tile(rnd() & 0x7ffff);
        rd_map(rnd() & 0x7ffff);
        rd_spr(rnd() & 0xfffff);
        if ((i & 7) == 0) rd_blk(rnd() % 6144);
        if (errors > 50) break;
    }
    printf("%s: %llu errors, %llu clocks, ddr overflow %d\n", errors ? "FAIL" : "PASS", errors, cycles, (int)dut->ddr_overflow);
    delete dut;
    return errors ? 1 : 0;
}
