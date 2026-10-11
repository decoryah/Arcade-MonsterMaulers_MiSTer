// Full-frame bench: every video block plus the mixer, one whole frame from a
// frozen state, out as RGB for comparison against MAME's snapshot of the same frame.
//
//   tb_frame <state.txt> <image.rom> <zoom.hex> <recip.hex> <out.rgb>
// The image is the flat ROM image the core loads (tools/mra_build.py on mra/*.mra).
#include "Vtb_frame_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>

static const int VIS_W = 288, VIS_H = 224, VIS_Y0 = 17, HTOTAL = 384, PIXCLK = 16;
static const long IMG_TILE = 0x240000, TILE_LEN = 0x400000;
static const long IMG_CHR = 0x640000, CHR_LEN = 0x180000;
static const long IMG_MAP = 0x7C0000, MAP_LEN = 0x80000;
static const long IMG_SPR = 0xC40000, SPR_LEN = 0x800000;
static const long IMG_SPR5 = 0x1440000, SPR5_LEN = 0x200000;

static Vtb_frame_top *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

struct State {
    std::map<std::string, std::vector<unsigned>> f;
    std::vector<std::vector<unsigned>> vram;
};

static State load_state(const char *path) {
    State st; st.vram.resize(17);
    FILE *fp = fopen(path, "r");
    if (!fp) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    char *line = nullptr; size_t cap = 0;
    while (getline(&line, &cap, fp) > 0) {
        if (line[0] == '#') continue;
        char *save = nullptr;
        char *key = strtok_r(line, " \t\n", &save);
        if (!key) continue;
        int page = -1;
        if (!strcmp(key, "VRAM")) page = atoi(strtok_r(nullptr, " \t\n", &save));
        std::vector<unsigned> v; char *t;
        while ((t = strtok_r(nullptr, " \t\n", &save))) v.push_back((unsigned)strtoul(t, nullptr, 16));
        if (page >= 0) st.vram[page] = v; else st.f[key] = v;
    }
    free(line); fclose(fp);
    return st;
}

static std::vector<unsigned> load_hex(const char *path) {
    std::vector<unsigned> v; char buf[64];
    FILE *fp = fopen(path, "r");
    if (!fp) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    while (fgets(buf, sizeof buf, fp)) v.push_back((unsigned)strtoul(buf, nullptr, 16));
    fclose(fp); return v;
}

static std::vector<unsigned char> load_region(FILE *rf, long off, long len, const char *what) {
    std::vector<unsigned char> d(len);
    fseek(rf, off, SEEK_SET);
    if (fread(d.data(), 1, len, rf) != (size_t)len) { fprintf(stderr, "short read of %s\n", what); exit(1); }
    return d;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 6) { fprintf(stderr, "usage: %s <state.txt> <image> <zoom.hex> <recip.hex> <out.rgb>\n", argv[0]); return 2; }
    State st = load_state(argv[1]);
    FILE *rf = fopen(argv[2], "rb");
    if (!rf) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }
    auto tiles = load_region(rf, IMG_TILE, TILE_LEN, "tiles");
    auto rchr  = load_region(rf, IMG_CHR, CHR_LEN, "gfx3");
    auto rmap  = load_region(rf, IMG_MAP, MAP_LEN, "gfx4");
    auto spr   = load_region(rf, IMG_SPR, SPR_LEN, "sprites");
    auto spr5  = load_region(rf, IMG_SPR5, SPR5_LEN, "sprite fifth plane");
    fclose(rf);
    auto zoomtab = load_hex(argv[3]), reciptab = load_hex(argv[4]);

    dut = new Vtb_frame_top;
    dut->reset = 1; for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;

    auto &k56 = st.f["K56REGS"]; auto &k55 = st.f["K55REGS"]; auto &k38 = st.f["K38REGS"];
    auto &k46 = st.f["K46REGS"]; auto &k47 = st.f["K47REGS"];
    for (int i = 0; i < 32; i++) { dut->k56_we = 1; dut->k56_addr = i; dut->k56_data = k56[i]; tick(); }
    dut->k56_we = 0;
    for (int i = 0; i < 48; i++) { dut->k55_we = 1; dut->k55_addr = i; dut->k55_data = k55[i] & 0xff; tick(); }
    dut->k55_we = 0;
    for (int i = 0; i < 16; i++) { dut->k38_we = 1; dut->k38_addr = i; dut->k38_data = k38[i]; tick(); }
    dut->k38_we = 0;
    auto &ct = st.f["ROZCT16"];
    for (int i = 0; i < 16; i++) { dut->rozc_we = 1; dut->rozc_addr = i; dut->rozc_data = ct[i]; tick(); }
    dut->rozc_we = 0;
    auto &cl = st.f["ROZCLIP"];
    for (int i = 0; i < 2; i++) { dut->clip_we = 1; dut->clip_addr = i; dut->clip_data = cl[i]; tick(); }
    dut->clip_we = 0;
    dut->cfg_we = 1;
    dut->roz_enable_i = (st.f["ROZCTRL"][0] >> 8) & 1;
    dut->opset_i = k47[6];
    dut->k46r5_i = k46[5] & 0xff;
    dut->k46offx_i = ((k46[0] & 0xff) << 8) | (k46[1] & 0xff);
    dut->k46offy_i = ((k46[2] & 0xff) << 8) | (k46[3] & 0xff);
    tick(); dut->cfg_we = 0;

    for (int page = 0; page < 16; page++)
        for (size_t i = 0; i < st.vram[page].size(); i++) {
            dut->vram_we = 1; dut->vram_waddr = (page << 12) | i; dut->vram_wdata = st.vram[page][i]; tick();
        }
    dut->vram_we = 0;
    auto &pal = st.f["PALETTE"];
    for (int i = 0; i < 2048; i++) {
        dut->pal_we = 1; dut->pal_waddr = i;
        dut->pal_wdata = ((pal[i*2] & 0xff) << 16) | pal[i*2+1]; tick();
    }
    dut->pal_we = 0;
    auto &li = st.f["ROZLI16"];
    for (size_t i = 0; i < li.size() && i < 2048; i++) { dut->li_we = 1; dut->li_waddr = i; dut->li_wdata = li[i]; tick(); }
    dut->li_we = 0;
    auto &sr = st.f["SPRITERAM"];
    for (size_t i = 0; i < sr.size() && i < 2048; i++) { dut->sram_we = 1; dut->sram_waddr = i; dut->sram_wdata = sr[i]; tick(); }
    dut->sram_we = 0;
    // tile ROM: 8-byte groups, the first five bytes are the row's {four chunky bytes, fifth plane}
    for (long g = 0; g < TILE_LEN / 8; g++) {
        unsigned long long v = 0;
        for (int b = 0; b < 5; b++) v = (v << 8) | tiles[g*8+b];
        dut->trom_we = 1; dut->trom_waddr = g; dut->trom_wdata = v; tick();
    }
    dut->trom_we = 0;
    for (long w = 0; w < MAP_LEN / 2; w++) { dut->mrom_we = 1; dut->mrom_waddr = w; dut->mrom_wdata = ((unsigned)rmap[w*2] << 8) | rmap[w*2+1]; tick(); }
    dut->mrom_we = 0;
    // ROZ characters: a tile is 256 bytes, 16 rows of 16 pixels; word w = row * 8 + x / 2, streamed at {x / 2, row}
    for (long t = 0; t < CHR_LEN / 256; t++)
        for (int w = 0; w < 128; w++) {
            int idx = ((w & 7) << 4) | (w >> 3);
            dut->crom_we = 1; dut->crom_waddr = (t << 7) | idx;
            dut->crom_wdata = ((unsigned)rchr[t*256 + w*2] << 8) | rchr[t*256 + w*2 + 1]; tick();
        }
    dut->crom_we = 0;
    for (long u = 0; u < SPR_LEN / 8; u++) {
        unsigned long long hi = 0;
        for (int b = 0; b < 8; b++) hi = (hi << 8) | spr[u*8+b];
        unsigned p5 = ((unsigned)spr5[u*2] << 8) | spr5[u*2+1];
        // {row64, p5} as an 80-bit word: [79:16] row, [15:0] fifth plane
        dut->srom_wdata[0] = (unsigned)((hi << 16) & 0xffffffffu) | p5;
        dut->srom_wdata[1] = (unsigned)(hi >> 16);
        dut->srom_wdata[2] = (unsigned)(hi >> 48);
        dut->srom_we = 1; dut->srom_waddr = u; tick();
    }
    dut->srom_we = 0;
    for (size_t i = 0; i < zoomtab.size(); i++) { dut->tab_we = 1; dut->tab_sel = 0; dut->tab_waddr = i; dut->tab_wdata = zoomtab[i]; tick(); }
    for (size_t i = 0; i < reciptab.size(); i++) { dut->tab_we = 1; dut->tab_sel = 1; dut->tab_waddr = i; dut->tab_wdata = reciptab[i]; tick(); }
    dut->tab_we = 0;

    // build the object list, as the vblank pass would
    dut->build = 1; tick(); dut->build = 0;
    long c = 0;
    while (!dut->build_done) { tick(); if (++c > 2000000) { fprintf(stderr, "objlist hung\n"); return 1; } }
    printf("object list built in %ld clocks%c", c, 10);

    std::vector<unsigned> out(VIS_H * VIS_W, 0);
    long worst = 0, worst_tm = 0, worst_roz = 0, worst_dr = 0;
    int min_lead = 99;
    long hist[64] = {0}, worst_hist[64] = {0}; int worst_hist_line = -1;
    auto render_line = [&](int raster_y) -> long {
        dut->line_start = 1; dut->line = raster_y; tick(); dut->line_start = 0;
        long n = 0;
        long n_tm = 0, n_roz = 0, n_dr = 0;
        memset(hist, 0, sizeof hist);
        while (dut->busy) {
            tick(); if (++n > 2000000) { fprintf(stderr, "line %d hung\n", raster_y); exit(1); }
            if (dut->busy_src & 4) n_tm = n; if (dut->busy_src & 2) n_roz = n; if (dut->busy_src & 1) { n_dr = n; hist[dut->dbg_dr_st & 63]++; }
        }
        if (n_tm > worst_tm) worst_tm = n_tm; if (n_roz > worst_roz) worst_roz = n_roz;
        if (n_dr > worst_dr) { worst_dr = n_dr; memcpy(worst_hist, hist, sizeof hist); worst_hist_line = raster_y; }
        return n;
    };
    // the frame's pre-start, as mm_video gives it a few raster lines early; the sprite drawer starts on the new list
    // and runs through the vblank as far as its ring allows (SPR_LEAD lines before the picture)
    const int SPR_LEAD = 3;
    dut->hcount_i = 0;
    auto prologue = [&]() {
        dut->vcount = VIS_Y0 - 1;
        dut->prestart = 1; tick(); dut->prestart = 0;
        for (int k = 0; k < 5 * HTOTAL * PIXCLK; k++) tick();     // five raster lines before the first pulse
        long w = 0;
        while (dut->spr_done_line < VIS_Y0 + SPR_LEAD - 1 && w < 4000000) { tick(); w++; }
        render_line(VIS_Y0);
    };
    prologue();
    dut->px_valid = 1;
    // REALTIME=1: the renderers get what the raster gives them -- one line period, 6144 clocks, from each pulse, while the
    // line before is scanned out -- and are restarted by the next pulse if still busy, as in mm_video; the memories'
    // latencies (+LAT_*) then decide which lines come out short. Default: each line is rendered to completion.
    const bool realtime = getenv("REALTIME") != nullptr;
    // TEAR=<state.txt>: the game rewrites sprite RAM while the frame is drawn (it does, between about visible rows 47 and
    // 135); the words that differ in that second state are written from TEAR_FROM to TEAR_TO (rows, default 47..135),
    // after the object list was built from this state, and the drawer reads whatever the RAM holds when it gets there
    std::vector<std::pair<int, unsigned>> tear;
    if (getenv("TEAR")) {
        State b = load_state(getenv("TEAR"));
        auto &sa = st.f["SPRITERAM"]; auto &sb = b.f["SPRITERAM"];
        for (size_t k = 0; k < 2048 && k < sb.size() && k < sa.size(); k++) if (sa[k] != sb[k]) tear.push_back({(int)k, sb[k]});
        printf("TEAR: %zu sprite RAM words change during the frame%c", tear.size(), 10);
    }
    size_t tear_i = 0;
    const int tear_y0 = getenv("TEAR_FROM") ? atoi(getenv("TEAR_FROM")) : 47, tear_y1 = getenv("TEAR_TO") ? atoi(getenv("TEAR_TO")) : 135;
    int overrun_lines = 0;
    const int passes = getenv("PASSES") ? atoi(getenv("PASSES")) : 1;
    std::vector<int> overrun_rows;
    for (int pass = 0; pass < passes && realtime; pass++) {
    overrun_lines = 0; overrun_rows.clear();
    if (pass > 0) {
        printf("after pass %d: cache %u hits, %u misses, %d lines late\n", pass, (unsigned)dut->cache_hits, (unsigned)dut->cache_misses, overrun_lines);
        tear_i = 0;
        // the next frame, as in the prologue: its list is built again, the drawer starts over
        dut->build = 1; tick(); dut->build = 0;
        { long c2 = 0; while (!dut->build_done) { tick(); if (++c2 > 2000000) { fprintf(stderr, "objlist hung\n"); return 1; } } }
        prologue();
    }
    for (int y = 0; y < VIS_H && realtime; y++) {
        dut->vcount = VIS_Y0 + y; dut->hcount_i = 24;
        dut->line_start = 1; dut->line = VIS_Y0 + y + 1; tick(); dut->line_start = 0;
        long n = 1;
        if (!tear.empty() && y >= tear_y0 && y <= tear_y1 && tear_i < tear.size()) {
            size_t cnt = (tear.size() - tear_i) / (size_t)(tear_y1 - y + 1);
            if (y == tear_y1) cnt = tear.size() - tear_i;
            for (size_t k = 0; k < cnt; k++, tear_i++) { dut->sram_we = 1; dut->sram_waddr = tear[tear_i].first; dut->sram_wdata = tear[tear_i].second; tick(); n++; }
            dut->sram_we = 0;
        }
        for (int x = 0; x < VIS_W; x++) {
            dut->px = x; dut->cen_pix = 1; tick(); dut->cen_pix = 0; n++;
            for (int k = 0; k < PIXCLK - 1; k++) { tick(); n++; }
            out[y * VIS_W + x] = dut->rgb;
        }
        for (; n < (long)HTOTAL * PIXCLK; n++) tick();
        // what mm_video samples as the next line begins
        dut->vcount = VIS_Y0 + y + 1; dut->eval();
        if (dut->busy) { overrun_lines++; overrun_rows.push_back(y); }
        if (dut->roz_lead < min_lead && y < VIS_H - 8) min_lead = dut->roz_lead;
    }
    }
    if (realtime) {
        printf("REALTIME: %d of %d lines were still being rendered when the next pulse came", overrun_lines, VIS_H);
        if (!overrun_rows.empty()) { printf(" (rows"); for (int r : overrun_rows) printf(" %d", r); printf(")"); }
        printf("\n");
    }
    printf("sprite row cache: %u hits, %u misses\n", (unsigned)dut->cache_hits, (unsigned)dut->cache_misses);
    dut->hcount_i = 0;
    for (int y = 0; y < VIS_H && !realtime; y++) {
        dut->vcount = VIS_Y0 + y;
        long n = render_line(VIS_Y0 + y + 1);
        if (n > worst) worst = n;
        // after the wait: lines in hand beyond the one due (1 = just in time); the
        // frame's last lines are left out, there is nothing left to run ahead into
        if (y < VIS_H - 8 && dut->roz_lead < min_lead) min_lead = dut->roz_lead;
        for (int x = 0; x < VIS_W; x++) {
            // a 16-clock pixel as mm_video paces it: px changes on the tick,
            // the mixer latches and sequences at fixed phases after it
            dut->px = x; dut->cen_pix = 1; tick(); dut->cen_pix = 0;
            for (int k = 0; k < PIXCLK - 1; k++) tick();
            out[y * VIS_W + x] = dut->rgb;
        }
        for (int k = 0; k < (HTOTAL - VIS_W) * PIXCLK; k++) tick();    // the line's blanking: 6144 clocks a line in all
    }
    if (dut->unsupported) { fprintf(stderr, "RTL raised `unsupported` (or the object list overflowed)\n"); return 1; }
    if (dut->shadow_overlap) fprintf(stderr, "warning: a pixel was shadowed twice\n");

    FILE *of = fopen(argv[5], "wb");
    if (!of) { fprintf(stderr, "cannot write %s\n", argv[5]); return 1; }
    fwrite(out.data(), 4, out.size(), of); fclose(of);
    if (getenv("HIST")) {
        printf("sprite drawer, worst line (raster %d), clocks per state:", worst_hist_line);
        for (int s = 0; s < 64; s++) if (worst_hist[s]) printf(" %d:%ld", s, worst_hist[s]);
        printf("%c", 10);
    }
    printf("worst line %ld clocks (budget 6144; tilemap %ld, ROZ %ld late, sprites %ld); ROZ lead min %d\n", worst, worst_tm, worst_roz, worst_dr, min_lead);
    delete dut;
    return 0;
}
