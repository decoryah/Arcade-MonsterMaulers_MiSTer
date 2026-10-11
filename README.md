# Monster Maulers for MiSTer

Konami's **Monster Maulers** (1993, GX170 "pre-GX" hardware; *Kyukyoku Sentai Dadandarn* in Japan) for the
MiSTer FPGA platform.

The machine descends from the Gaiapolis core that **plasticbugs** wrote for the Analogue Pocket
([analogue-pocket-gaiapolis](https://github.com/plasticbugs/analogue-pocket-gaiapolis)), as carried to MiSTer in
[`Arcade-Gaiapolis_MiSTer`](https://github.com/decoryah/Arcade-Gaiapolis_MiSTer): Gaiapolis and Monster Maulers are boards of one family (MAME's `mystwarr.cpp`; both run the same
68000, Z80, two K054539s, K056832 tilemaps, K053247/K055673 sprites, K053936 rotating plane and K055555 mixer). What this
repository changes in the machine is what the two games do differently -- 5-bit tiles and sprites, an 8-bit rotating
plane with per-line registers, the K055550 in place of the K054000, and a mixer that blends and fades -- and
everything around it is the MiSTer platform layer: memories, clocks, video, audio, controls and ROM/NVRAM loading
(`MonsterMaulers.sv`, `target/mister/`, `rtl/pll*`, `mra/`).

No ROMs or other copyrighted data are in this repository; you supply your own MAME `mmaulers.zip`.

## Status

**Tested on a real MiSTer** by the repository owner, all of it working: the World, USA and Japan sets; the picture, the
intro and in-game music, the sound effects and the controls through several rounds of play; HDMI through a RetroTINK 4K on
Direct Video (59.18 Hz) and a 15 kHz analog output; CRT Adjust and Flip Screen. (The first board test found two faults that
no simulation could show -- see "Release history".)

What was checked besides, in simulation and in the Quartus tool flow, against MAME 0.289 (the reference for every
comparison; MAME marks these sets `MACHINE_IMPERFECT_GRAPHICS`):

* **Video, frame for frame.** `sim/tb_frame*`: a frozen MAME machine state (the Lua probes in `tools/lua/` dump the video
  chips' registers and RAMs) is rendered through the core's tilemap, rotating-plane, sprite and mixer pipeline and
  compared with MAME's own snapshot of that frame. 39 of the 40 frames in the corpus (attract mode, the ROZ stages,
  fades, alpha blends, shadows) are **pixel-identical**; the other has 10 pixels (of 64,512) where MAME darkens one
  pixel with two overlapping shadow sprites and the core applies the shadow once (see "Known differences"). The slowest
  line of those takes 3,432 of the 6,144 clocks a line allows with ideal memory. The dragon fights are heavier (a line of
  up to ~190 tile rows: the dragon's neck and its shadow are chains of 17 objects each, with the fighters and the life
  bar over them), and at the SDRAM's latency they are what the sprite line ring and row cache of 20261011 were added for;
  127 frozen frames of those fights were rendered the same way and compared with the ideal-memory render (see
  "Release history").
* **ROM path.** `tools/make_mra.py`, `tools/mra_build.py` and `tools/mm_rom.py` rebuild MAME's memory regions from the zip
  and `tools/check_regions.py` compares them with what MAME actually loaded (43 slices, all identical).
* **Whole machine.** `sim/tb_mm*`: the real 68000 and Z80 programs from reset, through the loader and the SDRAM /
  DDR3 memory subsystem, video out. With the power-on memory check and the boot's software delay shortcut (as MAME is
  run for the comparison) and MAME's scripted inputs (coin, start, buttons) applied two frames late, the picture of ten
  frames spread over 600 (the intro, the title, a coin, the player select screen) is **pixel-identical** to MAME's of the same game
  moment in eight, differs by two levels of a fade that was mid-way (frame 500: the palette is rewritten while the
  picture is drawn) in one and by ten pixels (the double shadow, below) in one. The game runs one to three frames behind
  MAME's (see "Known differences"), and state dumps of the video chips' registers and RAMs agree with MAME's
  register for register at every dump. `sim/run_memrd.sh` reads every ROM region back through the ports the machine uses,
  after the image went through the loader: 0 errors; and with `ROMCHK=1` every tile, sprite and map read the renderers
  made in 45 frames of the running game (1.46 M, 6,912 and 13,608 reads) returned what the image holds.
* **The MiSTer top level.** `sim/emu/run_emu.sh`: `MonsterMaulers.sv` itself (only `hps_io` and the PLL stubbed; the
  framework's `arcade_video`, scandoubler and gamma modules and the SDRAM / DDR3 interfaces are the real ones) with the
  22 MB image streamed in a byte at a time through the ioctl port, then the EEPROM default. Every word of the image is where
  the ports read it (11,141,120 compared with the chips' arrays), the raster is 384 x 264 x 16 clocks = 59.1856 Hz in
  every frame, the picture is 224 rows of 288 pixels starting 72 pixels after the hsync pulse, and 125 frames after the
  load the **VGA picture is pixel-identical to MAME's** of the same game moment. The EEPROM reads back through the save
  path. Flip Screen (the picture is the overlay's turned 180 degrees, a frame late, exactly) and CRT Adjust (at zero
  amounts the geometry is the unadjusted output's, byte for byte; H-Position +10 starts the picture 160 clocks = 10 pixels
  later, H-Size +2 / -3 makes a line 4752 / 4392 clocks wide, V-Shift +5 puts the first row 5 lines lower) were checked
  there too.
* **Audio.** The first 5.5 s of the game's sound (`tools/cmp_audio.py`, same boot shortcut in MAME): the two channels
  follow MAME's in level within about 1-2 dB per half second (the core's mix is about 1.3 dB louder overall) and their
  envelopes correlate at 0.90, aligned within 20 ms. That is a check of the whole chain (the Z80 program, both K054539s, the
  K054321's volume and channel enables), not of the chips sample by sample (the next bullet is); the stereo channels were
  swapped against MAME before this comparison and are not now.
* **Memory subsystem, Flip Screen.** `sim/run_flip.sh`: Flip Screen's frame buffers behind the DDR3 arbiter, against a
  DDR3 model with random `BUSY`, with the option switched on and off at random points inside frames; every visible pixel
  of every frame is checked (turned 180 degrees from the frame before, or unchanged). 0 errors, 40 frames.
* **Quartus Prime Lite 17.0.2** (MiSTer's toolchain) compiles the project for the 5CSEBA6U23I7: 48 % of the ALMs
  (20,013 of 41,910), 99 % of the block RAM (549 of 553 M10K, so there is almost none left), 69 DSPs, and timing closes
  at 96 MHz with every check positive (setup +0.32 ns, hold +0.25, recovery +1.88, removal +0.70 in the slow 100 C
  model; `releases/monstermaulers_20261011.sta.summary`). The first fit missed by 2 ns at the mixer's palette ->
  brightness -> divide-by-255 step, which is two stages now, and the diagnostic overlay's status word is registered; the
  frame corpus is unchanged by either.
* **K054539 against MAME, chip level** (`sim/run_k539.sh`): the Z80's register writes to both chips are logged from MAME
  (USA set, `tools/lua/k539_log.lua`), replayed through the RTL chips with the sample ROM from the image, and the output is
  compared with MAME's own wav of the same game: RTL / MAME energy 1.00 in every octave band over two separate stretches
  of the intro music (56-68 s and 80-95 s), low-passed correlation 0.94-0.98. The latch semantics replay bit-identical.

## Release history

**20261011** -- the Red Dragon fight's fighters kept their feet. In that fight the fighters' shins and boots were missing
in a band of about ten rows just above the boss's life bar (the toes reappeared from the life bar's row down), at any
position on the screen. The sprite drawer has 6,144 clocks for a line, and the dragon's neck and its shadow put up to ~190
tile rows on the lines above the life bar, each costing the SDRAM's latency; the objects drawn last (the fighters and the
HUD) were what ran out of time. Fixed in three parts, all checked against MAME's frames in simulation and then on the board:

* *A ring of line buffers.* `rtl/spr_sched.sv` starts each sprite line as soon as the drawer is free and its buffer is
  scanned out, up to seven lines ahead of the picture (`k053247_draw`'s `SB` = 3: eight line buffers), so a run of heavy
  lines borrows the time the light lines before it left. A line still unfinished when its picture starts is dropped as it
  stands, as the old per-line pulse did. The Z buffer (all z codes are 0 in this game) and the shadow buffer's duplicate
  read port are gone to pay for the extra buffers.
* *A sprite row cache.* `rtl/spr_rowcache.sv`: 512 rows of 80 bits in front of the sprite ROM port; the dragon's chains
  reuse a few hundred rows every line.
* *The overlay's overrun count counted runs, not lines.* The squares showed "1" for an eleven-line band, which hid this
  fault in earlier photos; they count late lines now (`mm_video`'s `overrun_line`).

In simulation (the same frozen-frame bench, with the SDRAM latency modelled and the drawer given its real 6,144-clock
line): at 48 clocks of sprite ROM latency 99 of 127 frames of the two dragon fights had late lines with the old drawer
(4 to 41 of them); with the row cache and a ring of four line buffers 125 of them had none and the other two 3 and 5 (the
pictures equal the ideal-memory render in 126), and the ring of eight that is built in clears the heaviest frames (the
dragon's fire) even at 72 clocks. The fit is 549 of 553 M10K.

**20261010** -- the first build tested on a board. Two faults the first board test (an earlier build, not published)
showed were fixed before it:

* *Ghost copies and mixed glyph rows in the picture.* Quartus builds the tile layers' and the sprite drawer's two-bank line
  buffers 512 words deep where 576 were declared, so bank 1's pixels 224..287 aliased bank 0's 0..63 -- which no simulator
  shows. They are flat power-of-two arrays now, and `tools/check_ram_depth.py` checks every fit report for the same fault
  (26 RAMs, 0 problems).
* *Weak, crackling music.* Three differences from MAME's `k054539.cpp` in `rtl/k054539.sv`: 16-bit PCM stepped one byte a
  sample and was forced to word alignment (MAME steps two bytes from whatever address), the UPDATE_AT_KEYON latch (position
  writes are held until key-on, MAME's default) was missing, and the reverb ring index lacked MAME's second add of the
  position. The sum of the two chips also saturates now, as MAME's does, instead of wrapping.

The 20261011 RBF is the one that was played on the board; its fitter and timing summaries are
`releases/monstermaulers_20261011.fit.summary`, `.sta.summary` and `.ram_depths.txt` (the 20261010 build's are in the first
commit of the repository's history).

## Install

1. Unzip the release's `MonsterMaulers_MiSTer_20261011.zip` over the root of the SD card, or copy by hand the RBF
   (`releases/monstermaulers_20261011.rbf`) to `/media/fat/_Arcade/cores/` and the three `.mra` files from `mra/` to
   `/media/fat/_Arcade/`. Keep the RBF's `monstermaulers_` name and date: MiSTer finds the core by the MRA's `<rbf>` name
   plus the date, and takes the newest if there are several, so delete older `monstermaulers_*.rbf` files.
2. Put your MAME 0.289 `mmaulers.zip` in `/media/fat/games/mame/` (the parent set; the USA and Japan versions'
   ROMs are in the merged set, or in `mmaulersu.zip` / `dadandrn.zip` next to it). No ROMs are distributed here.
3. Start `Monster Maulers (World ver EAA)` from the Arcade menu. The ROM image is 22 MB and takes a few seconds to load.

## OSD options

| Option | Values | |
|---|---|---|
| Aspect ratio | Original, Full Screen, [ARC1], [ARC2] | Original is 4:3 |
| Flip Screen | Off, On | The picture turned 180 degrees on every output. Done on the finished picture through a frame buffer in the DDR3, so it adds one frame (17 ms) of delay while it is on and nothing when it is off. See below |
| Scandoubler Fx | None, HQ2x, CRT 25%, CRT 50%, CRT 75% | |
| CRT Adjust | submenu: CRT Adjust Off, On; then CRT H-Size 0..+4 / -16..-1, CRT H-Position -48..+20, CRT V-Shift -16..+15 | Fits the picture to a 15 kHz analog (CRT) output: its width, its place in the line and its place in the frame, without the monitor losing sync. Does nothing while the scandoubler is in use. Off by default. See below |
| Test Mode | Off, On | The board's test switch: the game's service menu |
| Audio | Stereo, Mono | The board's mono/stereo input; Mono puts the left mix on both channels |
| Diagnostic overlay | Off, On | Three rows of 32 squares along the bottom of the picture, and the built-in memory test (a few seconds, black screen) after each ROM load |
| SDRAM read capture | Normal, Late | Late samples SDRAM reads one clock later, for a module that answers slowly; try it if the picture is garbage and the overlay shows the SDRAM regions red. At this core's clock phase it is expected to make no difference |
| Reset | | Restarts the machine (the ROM stays loaded) |

**Reading the diagnostic overlay.** Turn it on *before* the ROM loads (OSD, then load the game again), or the memory test is
skipped and its squares stay dark. Row 0: frame counter, PLL locked, memory ready, download, test hold, core reset, IRQ5,
68000 stepped, core resets seen, test done / running, tile RAM ok, Z80 stepped. Row 1: the 68000's address, then the seven
regions read back equal to what was loaded (prog, snd, tile, chr, map, pcm, spr) and sound heard. Row 2: the same regions
read stably twice, DDR3 FIFO overflow, the number of lines last frame that a renderer had not finished when the line's
picture began (binary, left square highest; the sprite drawer, the tilemap and the rotating plane are told apart by
the flags' last three squares), sprites in the list / 4, then flags. Row 1's first 24 squares are the live 68000 bus
address and flicker. In normal play the line count is 0.

The game is horizontal (ROT0), so there is no rotation option. On a gamepad the default mapping is A / B / R for
buttons 1 / 2 / 3, Start for Start and Select for Coin (remap it in MiSTer's usual way). Two players; the board has no
inputs for a third and fourth. From the keyboard: 1 / 2 start, 5 / 6 coin and F2 for the test switch, on top of
MiSTer's usual keyboard-as-joystick. The game's own settings and high scores live in its EEPROM, which MiSTer saves and
restores.

**Flip Screen** is not the board's own flip dip switch, which only asks the video chips to flip: the renderers here do
not implement a global flip, so the finished picture is turned 180 degrees in `target/mister/flip_buf.sv` instead (a
frame buffer pair in the DDR3, the next frame read backwards). The controls are not flipped.

**CRT Adjust** is [rmonic79's MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust) (`modules/crt-adjust`):
the picture goes through a line buffer and only the picture moves, never the sync pulses' rate, so the monitor keeps its
lock while you adjust. The picture is 288 pixels in a line of 384: it starts 72 pixels after the hsync pulse starts and
ends 24 before the next, so it cannot move further right than +20 pixels, and making it wider uses that room up
(+4 is the most that fits at all). Tried on a real CRT.

## What differs from Gaiapolis

| | Gaiapolis | Monster Maulers |
|---|---|---|
| picture | 376 x 224, ROT90, 8 MHz / 508 x 263 | 288 x 224, ROT0, 6 MHz / 384 x 264 = 59.1856 Hz (the board and MAME agree) |
| program | 3 MB | 1.5 MB in a 2 MB map |
| tiles (K056832) | 4bpp | 5bpp, layers that cover the whole 4 x 4 page map |
| sprites (K055673) | 4bpp, colour unit 16 | 5bpp, colour unit 32, z codes suppressed |
| ROZ plane (K053936) | 4bpp tiles, colour per tile | 8bpp tiles, one palette group, per-line "super" mode |
| protection | K054000 | K055550 memset engine |
| mixer | opaque picks, shadows | tile / ROZ / sprite alpha blending (K054338), additive, brightness fades, shadows |
| sound | two K054539 | the same, voice gains for channels 4-7 |

The hardware, region by region (map, chips, the K055550, timing), is in `docs/hardware.md`; the memory partition in
`docs/mister-memory.md`.

## Known differences from MAME

* **A pixel shadowed twice.** The renderer keeps one shadow flag per pixel; MAME's software mixer darkens a pixel once
  for every shadow sprite that covers it. The core sets `dbg_shadow_overlap` (the overlay's row 2) when it happens. One
  frame of the corpus has ten such pixels. Whether the real K055673 darkens twice is not known.
* **The K055550 takes time.** MAME performs the memset of command 0x97 in zero time at the register write; this core's
  engine masters the bus for the word-a-few-clocks the fill takes. The game uses it to clear all sixteen tile RAM pages
  (128 KB) at start-up and again before the attract mode, a quarter of a frame each time, so the game's own timeline
  runs about one frame behind MAME's from the first batch on (state dumps of the two agree register for register, one
  frame apart; `tools/cmp_lag.py`). The chip's real speed is not known.
* The power-on memory check runs for about 1,300 frames (22 s) as in MAME; the Diagnostic overlay shows progress.

## Repository layout

| Path | |
|---|---|
| `MonsterMaulers.sv`, `MonsterMaulers.q*`, `MonsterMaulers.sdc`, `files.qip` | the MiSTer top level (`emu`), Quartus project, timing constraints |
| `rtl/` | the machine: `mm_core` (the board), `mm_main` (68000 map, K055550), `mm_video`, `mm_mixer`, `mm_sound`, renderers (`k056832_tilemap`, `k053936_roz`, `k053247_*`), `k054539`, `k054321`, `er5911` (`rtl/data/` generated tables, `rtl/pll*` the clock PLL) |
| `target/mister/` | the memory subsystem (`mm_mem`, `rom_cache`, `ddr_arb`), SDRAM controller, memory test, Flip Screen |
| `modules/` | vendored TG68K.C, tv80 and CRT Adjust (`modules/VENDOR.md`) |
| `sys/` | the MiSTer framework (identical to Template_MiSTer) |
| `mra/` | the three MRAs, generated by `tools/make_mra.py` |
| `sim/` | Verilator benches: frozen-state frames, whole machine, Flip Screen, the MiSTer top level end to end |
| `tools/` | MRA generator and ROM image builder, comparison tools, MAME Lua probes, the generators of `rtl/data` (`gen_*.py`), `release.py` / `package.py` |
| `releases/` | the released RBF with its fitter and timing summaries |
| `docs/` | `hardware.md`, `mister-memory.md` |

## Building

Quartus Prime Lite 17.0.2 (the version MiSTer's framework is built with):

```
quartus_sh --flow compile MonsterMaulers
```

`tools/make_mra.py mmaulers.zip` regenerates the MRAs. The simulation benches need Verilator 5 and a C++ compiler, and a
ROM image you build yourself from your own romset (it checks every part's CRC and the image's md5):

```
python tools/mra_build.py "mra/Monster Maulers (World ver EAA).mra" mmaulers.zip mmaulers.rom   # 23,330,816 bytes
```

Run the benches from a Linux filesystem (WSL's own, not `/mnt/c`); the whole-machine bench simulates at about a tenth
of a MHz, so a thousand frames takes hours.

## Credits

* **plasticbugs** -- the Gaiapolis core for the Analogue Pocket, the machine this one is built on (`rtl/`, the SDRAM
  controller `target/mister/sdram_ctrl.sv` and the memory test `mem_test.sv`, adapted; `tools/mra_build.py`), and through
  it the MAME team's work as the reference, **Tobias Gubener**'s TG68K.C (LGPL-3.0) and **Guy Hutchison**'s tv80 (MIT),
  vendored under `modules/`.
* **Claude** (Anthropic's AI model, used through Claude Code) -- the Monster Maulers machine changes and the MiSTer
  layer, written together with the repository owner: the 5-bit renderers, the 8bpp per-line rotating plane, the K055550,
  the mixer, the memory subsystem, the MRAs, the simulation benches and this documentation.
* **Sorgelig** and the MiSTer team -- the framework (`sys/`, GPL).
* **rmonic79** (Umberto Parisi), with help from **Andrea Bogazzi** (asturur) --
  [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust), the module behind the CRT Adjust options
  (`modules/crt-adjust/crt_adjust.sv`, with a one-line sign fix noted in `modules/VENDOR.md`; GPL-3.0 or later).
* **furrtek** -- [SiliconRE](https://github.com/furrtek/SiliconRE/tree/master/Konami)'s silicon-traced models and notes of
  the K053252 timing chip (the raster), the K054338 and K055555.
* **Jose Tejada (jotego)** -- JTFRAME's MiSTer SDRAM clock phase and read-capture timing, which this core's PLL and
  controller settings follow.

## Licence

Copyright (C) 2026 decoryah. GPL-3.0, as the Pocket core this is built on (see `LICENSE`). The vendored TG68K.C (LGPL-3.0), CRT Adjust (GPL-3.0 or
later) and tv80 (MIT) in `modules/` keep their own licences (`modules/VENDOR.md`), and the MiSTer framework in `sys/` is
GPL (see the headers of its files).
