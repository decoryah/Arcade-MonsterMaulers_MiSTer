// Replays a K054539 register-write log (tools/lua/k539_log.lua) through both chips and writes each output sample.
//
//   tb_k539 <image.rom> <writes.txt> <first sample> <last sample> <out.bin> [clocks per sample, default 600] [warm-up samples, default 48000]
//
// The sample ROM is the image's PCM region (byte 0x840000, 4 MB). Writes are applied before the sample they
// precede; the chips' own state is built up from the first write of the log, so <first sample> only chooses
// where the output starts; samples before <first sample> - <warm-up> are not clocked at all (their writes are still
// applied), which is exact while the chips are silent there. out.bin: int16 little-endian l1 r1 l2 r2 per sample.
#include "Vtb_k539_top.h"
#include "Vtb_k539_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static Vtb_k539_top *dut;
static inline void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

struct W { long t; int chip, reg, val; };

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 6) { fprintf(stderr, "usage: %s image writes first last out [clocks]\n", argv[0]); return 2; }
    long first = atol(argv[3]), last = atol(argv[4]);
    int cps = argc > 6 ? atoi(argv[6]) : 600;
    long warm = argc > 7 ? atol(argv[7]) : 48000;
    long skip_to = first - warm;
    dut = new Vtb_k539_top;
    {
        FILE *f = fopen(argv[1], "rb"); if (!f) { perror("image"); return 1; }
        fseek(f, 0x840000, SEEK_SET);
        std::vector<unsigned char> b(1 << 22);
        if (fread(b.data(), 1, b.size(), f) != b.size()) { fprintf(stderr, "short image\n"); return 1; }
        fclose(f);
        auto &m = dut->rootp->tb_k539_top__DOT__pcm;
        for (size_t i = 0; i < b.size(); i++) m[i] = b[i];
    }
    std::vector<W> w;
    {
        FILE *f = fopen(argv[2], "r"); if (!f) { perror("writes"); return 1; }
        long t; int c, r, v;
        while (fscanf(f, "%ld %d %d %d", &t, &c, &r, &v) == 4) w.push_back({t, c, r, v});
        fclose(f);
    }
    fprintf(stderr, "%zu writes\n", w.size());
    FILE *out = fopen(argv[5], "wb");

    dut->cs1 = dut->cs2 = dut->wr = 0; dut->cen_48k = 0; dut->reset = 1;
    for (int i = 0; i < 20; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 20; i++) tick();

    size_t wi = 0;
    for (long s = 0; s <= last; s++) {
        // everything the Z80 wrote at or before this sample
        while (wi < w.size() && w[wi].t <= s) {
            dut->cs1 = w[wi].chip == 1; dut->cs2 = w[wi].chip == 2; dut->wr = 1;
            dut->addr = w[wi].reg; dut->wdata = w[wi].val;
            tick();
            dut->cs1 = dut->cs2 = dut->wr = 0;
            tick();
            wi++;
        }
        if (s < skip_to) continue;                      // silent lead-in: registers only
        dut->cen_48k = 1; tick(); dut->cen_48k = 0;
        for (int i = 1; i < cps; i++) tick();
        if (s >= first) {
            short v[4] = { (short)dut->l1, (short)dut->r1, (short)dut->l2, (short)dut->r2 };
            fwrite(v, 2, 4, out);
        }
        if ((s & 0x3ffff) == 0) fprintf(stderr, "sample %ld / %ld\r", s, last);
    }
    fclose(out);
    fprintf(stderr, "\ndone\n");
    return 0;
}
