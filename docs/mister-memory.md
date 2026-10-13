# The MiSTer memory partition

The machine (`rtl/mm_core.sv`) sees seven ROM ports and a tile RAM port, all level request / one-cycle ack. What sits behind them is
`target/mister/mm_mem.sv`, derived from the Gaiapolis core's memory system (`docs/mister-memory.md` of gaiapolis-mister has the
reasoning for the partition and the caches, which carries over unchanged). What differs here is the data: this game's tiles and
sprites have a fifth bit plane and its rotating plane is 8bpp.

| | MiSTer (DE10-Nano + SDRAM module) |
|---|---|
| SDRAM | 32 MB, 16 bit |
| DDR3 | the HPS's 1 GB, 64 bit, shared with Linux and the scaler |
| block RAM | 5.6 Mbit (553 M10K) |

## The partition

```
SDRAM   tiles         1.5 MB   3-word bursts   a tile row = 4 chunky bytes + the fifth plane's byte (+1 pad byte)       K056832
        sprites       10 MB    5-word bursts   a 16-pixel row = 4 words of the low planes + 1 word of the fifth plane   K055673
        PCM           4 MB     single words                                                                            two K054539s
        68000 program 2 MB     behind a 16 KB cache, 8-word line fills
        Z80 program   256 KB   behind a  4 KB cache, 8-word line fills
DDR3    ROZ characters 1.5 MB  128-word tile = 32 beats, buffered whole, streamed to the plane's tile cache
        ROZ map        512 KB  2 beats per tile miss (prefetched together)
block   K056832 tile RAM  64K x 16, byte enables
RAM
```

SDRAM word addresses (24 bits): tiles `0x000000`, PCM `0x180000`, sprites `0x380000`, program `0x880000`, sound program `0x980000`
(20 MB of the 32).

### Why the planes are interleaved at load time
A burst on the SDRAM controller is a run of consecutive words in one open row. Keeping each fifth plane in a region of its own
would have cost a second access per tile row and per sprite row (about 10 clocks of overhead each); the loader instead writes the
image's separate regions into one interleaved stream:

* tile row `g` (an 8-byte group in the image: `b0 b1 b2 b3 | plane5 | 0 0 0`): words `3g, 3g+1, 3g+2` of the tile region, the
  third holding `{plane5, 0}`; the image's fourth word of the group is dropped.
* sprite row `u`: words `5u .. 5u+3` are the image's 64-bit word, `5u+4` the fifth-plane word from the image's second sprite region.

The tile port then returns `{w0, w1, w2[15:8]}` (40 bits) and the sprite port `{w0..w3, w4}` (80 bits).

### The ROZ plane (DDR3)
Characters are 8bpp: a tile is 256 bytes = 128 16-bit words (two pixels each, the even column in the high byte), stored at load
time as `{x / 2, row}` within the tile -- the order the plane's cache is addressed in, so a block streams straight into it: 32 beats of
64 bits at `DD_CHR + tile * 32`. The map is two 256 KB halves (attribute byte, tile low byte), a tile needing one byte of each at the
same index; a miss in the first half prefetches the second's beat too, and each half keeps its last beat (8 neighbouring tiles).
The plane's tile cache holds `NENT` tiles (64: 16 M10K blocks, the same as Gaiapolis' 128 4bpp tiles).

## The loader

The ROM image (`mra/*.mra`, `0x1640000` bytes, layout in the MRA header and `mm_mem.sv`) arrives from the HPS a byte at a time.
Pairs are merged into words, queued in a 64-entry FIFO (`dl_wait` holds the HPS off at 32), and a dispatcher classifies each
word by image offset, computes its address (the interleaves above) and writes it: SDRAM as a byte-enabled word, DDR3 as a 64-bit
beat with byte enables. The caches are swept on every download start. The default EEPROM is a separate download (MRA index 2),
and the same index is used to save and restore it (`<nvram>`).

### Fast load (the MRA's `address=` attribute)
With `address="0x32000000"` on the index-0 `<rom>`, a recent Main_MiSTer copies the whole assembled image into the DDR3 at that
byte address in one `memcpy`, bracketed by a download that has no data bytes: it starts with `ioctl_addr` = the image's length
(an ordinary download starts at 0, which is how `MonsterMaulers.sv` tells them apart: `fast_dl`) and ends with it. The core stays in
reset from the start until `mm_mem` has pushed the whole image through the loader (`fl_done`). `mm_mem` reads the image back in
256-byte blocks (a 32-beat burst, the same burst and buffer as a ROZ character block, which are idle in reset), swaps each
little-endian halfword to the image's big-endian word and pushes it into the loader's FIFO, as long as the FIFO has room; the dispatcher
behind it is unchanged, so the layout is the one above. Nothing else of the DDR3 is touched: the window's offset 0x400000 beats
(byte 0x32000000) is clear of the ROZ data (0 to 0x50000 beats) and the Flip Screen buffers (0x80000). One rule: a block that finds
the FIFO full goes back to the idle state of the DDR3 state machine and resumes there, because the loader's own DDR3 writes (ROZ
characters and map) are served from it and sit at the head of the FIFO. The loader accepts about a word per 8 clocks, so the 11.7
million words take 90.7 million clocks (0.95 s); that, not the DDR3, is the limit. `sim/run_memrd.sh` with `FAST=1` and
`sim/emu/run_emu.sh` with `FAST=1` model the HPS side.

## Video

The 6 MHz pixel clock comes from the 96 MHz system clock (a pixel every 16 clocks; a 384-pixel line is 6,144 clocks, the budget the
renderers were designed against; the sprite drawer works up to seven lines ahead through a ring of line buffers
(`spr_sched.sv`) and reads its rows through a 512-row cache (`spr_rowcache.sv`), because the dragon fights put up to ~190 tile rows on a line, each
one an SDRAM burst). The mixer's 16-clock schedule is described in `rtl/mm_mixer.sv`. Flip Screen (`flip_buf.sv`)
turns the finished picture 180 degrees through two DDR3 frame buffers, as in the Gaiapolis core, with `W = 288`. CRT Adjust is
rmonic79's module, as there; with this raster the picture is 288 pixels in a line of 384, starting 72 pixels after the hsync
pulse starts and ending 24 before the next, so H-Size goes to +4 (read period 64 + n quarter-clocks) and H-Position to +20.

## The scandoubler needs the horizontal blank alone

`sys/scandoubler.v` (Scandoubler Fx, MiSTer.ini's `forced_scandoubler`) takes its line timing from the edges of
`HBlank`: `hb` falling starts a line (`hcnt`, `sd_hcnt`, `hde_start` and the sampling of `vb_in` hang on it) and it
shifts `vs_in` / `vb_in` through at those edges; `arcade_video` itself samples `VBlank` on `HBlank`'s falling edge.
So `HBlank` has to toggle on every line of the frame, the vertical blank lines included, with `VBlank` separate.
This core gave it `~de`, where `de` is the visible *rectangle* (`in_active_x && in_active_y`): `HBlank` stayed high
through the whole vertical blank, the scandoubler's line counters ran on through the blank lines, and the doubled
output had no vertical sync and no vertical blank (measured with `sim/emu/run_sd.sh`, the raster module into
`arcade_video` alone: `vs_sd` and `vb_sd` constant 0 while the mixer's `vs_g` pulsed; `VGA_VS` 0 rises in 14 M
clocks). The 15 kHz path is not affected, because `arcade_video` without the scandoubler uses the combined blank for
`VGA_DE` only, which is why the board tests on 15 kHz analog and on Direct Video did not show it. Sound plays, the
picture is frozen, and MiSTer's video info says ~31.5 kHz.

`mm_video.sv` now also outputs `hde` (`in_active_x`, level with `de`), through `mm_core.sv`; `MonsterMaulers.sv`
gives `arcade_video` `HBlank = ~hde` (registered with the rest in `vq_hbh`) and `VBlank = vblank`. `VGA_DE` comes
out the same rows as before (the video mixer ANDs the two). CRT Adjust and Flip Screen keep the combined blank
(`hblank_c`), which is what they want; CRT Adjust is gated off while the scandoubler is in use.

Measured with `sim/emu/run_sd.sh` (the raster is 384 x 264 pixels of 16 clocks): with the scandoubler on (forced, CRT 25 /
50 / 75 %) 528 lines a frame, 448 picture rows of 288 pixels (576 with HQ2x), a line every 3,072 clocks, frame period
exactly 1,622,016 clocks = 16 x 384 x 264, each source line twice in order; with it off 264 lines, 224 rows, 6,144
clocks a line.

## Verification

* `sim/run_memrd.sh <image>` (`tb_memrd_top.sv`, `tb_memrd.cpp`): `mm_mem` and `ddr_arb` behind a behavioural SDRAM chip and Avalon
  DDR3 with every read port exposed. The image goes in through the loader a byte at a time (or, with `BACKDOOR=1`, straight into
  the chips by the same address arithmetic), then each region is read back through the port the machine uses -- 68000 program,
  Z80 program, PCM, tile rows (3-word bursts), ROZ map, sprite rows (5-word bursts) and ROZ character blocks (the DDR3's 32-beat
  streams, checked word by word in `{x / 2, row}` order) -- at the ends of every region and at random addresses, and compared with
  the image. 0 errors in 4,000 reads a port with the streamed image (90 M clocks, about 0.93 s of board time to load).
* `sim/tb_mm.cpp` with `ROMCHK=1` does the same on every tile / sprite / map read the renderers make while the game runs.
