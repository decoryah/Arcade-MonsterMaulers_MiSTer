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
Direct Video (59.18 Hz) and a 15 kHz analog output; CRT Adjust and Flip Screen; in build 20261014, fast loading and
the Scale options; in build 20261025, the Colours option's board DAC curve. (The first board test found two faults that no simulation could show -- see "Release history".)

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
  (20,587 of 41,910), 99 % of the block RAM (549 of 553 M10K, so there is almost none left), 69 DSPs, and timing closes
  at 96 MHz with every check positive (setup +0.63 ns, hold +0.25, recovery +1.89, removal +0.96 in the slow 100 C
  model; `releases/monstermaulers_20261025.sta.summary`). The first fit missed by 2 ns at the mixer's palette ->
  brightness -> divide-by-255 step, which is two stages now, and the diagnostic overlay's status word is registered; the
  frame corpus is unchanged by either.
* **K054539 against MAME, chip level** (`sim/run_k539.sh`): the Z80's register writes to both chips are logged from MAME
  (USA set, `tools/lua/k539_log.lua`), replayed through the RTL chips with the sample ROM from the image, and the output is
  compared with MAME's own wav of the same game: RTL / MAME energy 1.00 in every octave band over two separate stretches
  of the intro music (56-68 s and 80-95 s), low-passed correlation 0.94-0.98. The latch semantics replay bit-identical.

## Release history

**20261025** -- Colours in the OSD: **Board DAC** (the default) or **MAME**. The board turns each 8-bit colour into a
voltage with a Konami K054573 per channel, and that DAC is not linear: its output rises faster near the top, so mid tones
come out darker than MAME's straight palette (mid grey 128 comes out as about 60 of 255). Board DAC looks each channel up
in the DAC's curve (`rtl/data/k054573_dac.hex`, written by `tools/make_dac_table.py`: 0 stays 0 and 255 stays 255, this
game using the full range); MAME is the old output. The curve is the model of the Gaiapolis core (gaiapolis-mister),
traced from Ace's K054573 reproduction (Gerbers and BOM; Monster Maulers is among the games that use the chip) and fitted
to a Gaiapolis PCB recording. There is no recording of a Monster Maulers PCB, so it was checked against one of
Metamorphic Force, the same chip family: two scenes paired with MAME's identical frames (the heroes over the earth, the
mountain island), with the recording's own gain and offset per channel free, give an rms error of 17.2 and 14.0 levels
for a linear DAC, 3.7 for the best plain gamma (2.0-2.2) and 3.3 / 4.3 for the DAC model. A KLOV capture of this game's
title screen pairs exactly with MAME's but has only five flat colours and an unknown capture chain, and was not used.
The table sits after the mixer, before the diagnostic overlay, Flip Screen, CRT Adjust and the scaler, and takes no
block RAM. Unlike Gaiapolis's it is not registered: this mixer's colour is final only in the clock its pixel enable is
high, and the bench showed a registered table passing on the half-painted pixel of the clock before (a black picture).
On the board a fade's brightness scales the DAC's current rather than the code, so faded mid tones there are a little
brighter than here. In simulation (`sim/emu/run_emu.sh`, `COLOURS_MAME=1`; `sim/emu/dac_check.py`): with MAME the scaler
picture of a 110-frame run is byte-identical to 20261021's, and with Board DAC every channel value of it is the table of
the MAME run's at the same place. The fit is 20,587 ALMs and 549 of 553 M10K, timing positive everywhere. Tested on a
real MiSTer by the repository owner: the colours are right ("perfect"), and the build runs as before.

**20261021** -- The buttons have their real names. The three MRAs (the `<buttons>` line, which MiSTer's "Define joystick
buttons" menu shows in place of the core's own) and the OSD string in `MonsterMaulers.sv` (`J1`) called the game's buttons
"Button 1 / Button 2 / Button 3"; they now say **Weak Attack, Medium Attack, Strong Attack** (the names the arcade
database gives the board's three buttons), with Start and Coin as before. Every entry is a wired input: the three buttons
and Start reach the game for both players, Coin is each player's coin input, and the board reads no third or fourth player
(MAME defines their ports but maps them nowhere), so no mapping entry goes unused. The default gamepad mapping (A / B / R /
Start / Select) is unchanged, and so is everything else: the RTL is that of 20261014 except for the OSD string, and the
fit is 20,312 ALMs and 549 of 553 M10K with timing positive everywhere (fitter seed 2 again, first try). Not yet tested on a
real MiSTer. The attack order (button 1 weak, 3 strong) is the one the arcade database lists.

**20261014** -- Fast loading. The MRAs now carry `address="0x32000000"` on the ROM image's `<rom>` (the attribute the
Namco NB-2 core uses): a recent Main_MiSTer then does not stream the 22 MB image through the HPS port a byte at a time
(about 23-25 s on the board that was timed), but copies the assembled image into the DDR3 in one go and ends a download
that has no data, only a start address: the image's length. The core stays in reset, reads the image back from the DDR3
in 256-byte blocks (`mm_mem.sv`, `FL_BASE` = byte 0x32000000, outside the ROZ data and the Flip Screen buffers) and
pushes the words into the same loader FIFO the streamed bytes go through, so the memory layout, the cache sweep, the
memory test and the diagnostic overlay's download square all behave as before; the core's loader takes the whole image
in 0.95 s (90.7 million clocks at 96 MHz), against the streaming's 23-25 s. A Main_MiSTer that does not know the attribute
streams the bytes as before (`ioctl_addr` is 0 at the start of such a download, which is how the two are told apart), so
the same RBF and MRAs work with both. The fit is 20,384 ALMs and 549 of 553 M10K, with timing positive everywhere on
fitter seed 2 (the project's seed is 2 from this build: the first fit, with seed 1, missed by 0.41 ns inside the
framework's scaler, `ascal`'s `o_hcpt` -> `o_vcpt`, on a path this repository's code is not on). The first version of the
replay deadlocked at the ROZ characters (image offset
0x640000): the loader's DDR3 writes need the state machine that the replay held while the FIFO was full. The replay
now gives the state machine up when the FIFO has no room (the bench found it, `FLTRACE=1`), and the whole image goes
through. Checked in simulation: `sim/run_memrd.sh` with `FAST=1` (the memory subsystem alone, random DDR3 `BUSY`, every
region read back through the machine's ports, 0 errors) and `sim/emu/run_emu.sh` with `FAST=1` (the whole top level:
the HPS side of the attribute modelled, then the image compared word for word with the chips, then frames). Tested on a
real MiSTer by the repository owner: fast loading and the Scale options work.

**20261013** (built and packaged, not released on its own: it is in 20261014) -- Scale in the OSD: Normal, V-Integer, HV-Integer, Narrower HV-Integer and HV-Integer+, the integer scaling
of the framework's `video_freak` (the same menu as rmonic79's Arcade-Raiden core), for the HDMI scaler. The module sits after
`arcade_video` and measures the finished picture's rows and width, so it follows the scandoubler and CRT Adjust, and works out
the size from the scaler's own output size (`HDMI_WIDTH` / `HDMI_HEIGHT`); `VIDEO_ARX` / `VIDEO_ARY` come from it instead
of from the Aspect ratio setting directly, and with Scale on Normal they are the same values as before. The analog output is
not affected. Full Screen has no proportions for the integer rule to size the width from (ARX = ARY = 0), and the module
then sizes the *height* from the width and asks for more rows than the screen has (1344 on a 1080p display); with an
integer Scale the core gives Full Screen the scaler's own proportions instead, so it comes out as a whole-number size in the
screen's aspect ratio. In simulation (`sim/emu/run_emu.sh` with `SCALE=`, `AR=`, `HW=`, `HH=`; the whole top level) the size
the core asks the scaler for was compared with the integer rule worked out in the bench from the picture's rows and width,
in 72 runs over the five Scale modes, the aspect settings (Original, Full Screen, ARC1), scaler sizes from 640 x 480 to
3840 x 2160 and the scandoubler modes (HQ2x, CRT 50 %, forced): all equal, with a scaler too small for a whole multiple
(200 x 150) and an unknown one (0 x 0, Direct Video) passing the aspect ratio through unchanged, and no frame or timing
difference with Scale on Normal. The picture is nearly square-pixelled, so HV-Integer and Narrower HV-Integer give the same
size at every common screen size (they differ only where the aspect width falls nearer the upper multiple, as in Full
Screen at 1080p: 1728 against 1440 pixels wide). The scaler picture of a 110-frame whole-top-level run is byte-identical
to 20261012's. The fit is 20,279 ALMs (the module's multiplier and divider) and 549 of 553 M10K, with timing positive
everywhere. Tested on a real MiSTer in 20261014, which carries it: the Scale options work.

**20261012** -- Scandoubler Fx and MiSTer.ini's `forced_scandoubler` no longer freeze the picture. With the scandoubler
on (HQ2x, the CRT filters, or `forced_scandoubler=1`) the core's output had no vertical sync at all: the monitor, or the
HDMI scaler, saw a stream without frames, the sound played and the picture stood still (31.5 kHz in MiSTer's video
info). The framework's scandoubler takes its line timing from the falling edges of `HBlank` and needs them on every
line of the frame, the vertical blank's lines included, and this core's `HBlank` was the picture window (`~de`), high
through the whole vertical blank. `mm_video.sv` now also outputs the horizontal window alone (`hde`) and
`MonsterMaulers.sv` gives `arcade_video` that as `HBlank`, with `VBlank` separate; CRT Adjust and Flip Screen keep the
combined blank they want. The fault was found in the Gaiapolis core (fixed in `gaiapolis_20261011`) and is the same
wiring here. The 15 kHz outputs were never affected, which is why the board tests on 15 kHz analog and Direct Video did
not show it.

In simulation: `sim/emu/run_sd.sh` (the raster into `arcade_video` alone) gives no `VGA_VS` at all with the old
wiring and, with the new one, in every mode (forced, HQ2x, CRT 25 / 50 / 75 %) 528 lines a frame, 448 picture rows of
288 pixels (576 with HQ2x), a line every 3,072 clocks and a frame period of exactly 1,622,016 clocks, each source
line twice in order; the whole top level (`sim/emu/run_emu.sh` with `FSD=1`) never sees a frame with the old wiring
and gives the same 448 rows in 528 lines with the new. The 15 kHz picture of a 110-frame whole-top-level run is
byte-identical to 20261011's, with the same geometry and the exact frame period. The Red Dragon fix of 20261011 is
unchanged. The fit is 19,942 ALMs and 549 of 553 M10K, with timing positive everywhere. Tested on a real MiSTer by the
repository owner: the build runs correctly, the scandoubler modes and the 15 kHz output included.

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
(4 to 41 of them); with the row cache and the ring of eight line buffers that is built in none of the 127 has a late line,
and every one equals the ideal-memory render (a ring of four left two frames with 3 and 5 late lines; the eight clear the
heaviest, the dragon's fire, even at 72 clocks). The fit is 549 of 553 M10K.

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

The 20261025 RBF is the one that was played on the board for the Colours option, and 20261014's for fast loading and the
Scale options (20261012, before it,
differs from 20261011, which carried the Red Dragon fix, only in the blank wiring above; 20261013 was the Scale option
alone and was not released separately); 20261021 differs from it only in the button names and 20261025 in the Colours
option. The fitter and timing summaries of the release are `releases/monstermaulers_20261025.fit.summary`, `.sta.summary` and `.ram_depths.txt` (those
of the earlier builds are in the repository's history).

## Install

1. Unzip the release's `MonsterMaulers_MiSTer_20261025.zip` over the root of the SD card, or copy by hand the RBF
   (`releases/monstermaulers_20261025.rbf`) to `/media/fat/_Arcade/cores/` and the three `.mra` files from `mra/` to
   `/media/fat/_Arcade/`. Keep the RBF's `monstermaulers_` name and date: MiSTer finds the core by the MRA's `<rbf>` name
   plus the date, and takes the newest if there are several, so delete older `monstermaulers_*.rbf` files.
2. Put your MAME 0.289 `mmaulers.zip` in `/media/fat/games/mame/` (the parent set; the USA and Japan versions'
   ROMs are in the merged set, or in `mmaulersu.zip` / `dadandrn.zip` next to it). No ROMs are distributed here.
3. Start `Monster Maulers (World ver EAA)` from the Arcade menu. The ROM image is 22 MB. With a recent Main_MiSTer (one
   that knows the MRA's `address=` attribute) it is copied to the DDR3 in one go and loaded in about a second; an older
   one streams it through the HPS port, which takes 20-25 s.

### Fast loading

The three MRAs carry `address="0x32000000"` on the ROM image. A Main_MiSTer that supports that attribute copies the
assembled 22 MB image into the DDR3 in one go instead of streaming it through the HPS port a byte at a time, and the core
reads it back from there into its loader: the load takes about a second, against the 23-25 s of the board that was timed.
There is nothing to set. A Main_MiSTer that ignores the attribute streams the image as before, with the same RBF and MRAs.
To see which of the two you got, switch on the Diagnostic overlay (see below): the *download* square (row 0, 11th from
the left) is lit for about a second with fast loading and for 20 seconds or more without. The game's own power-on memory
check (about 22 s, as in MAME) comes after the load either way. How it works: `docs/mister-memory.md`, "Fast load".

## OSD options

| Option | Values | |
|---|---|---|
| Aspect ratio | Original, Full Screen, [ARC1], [ARC2] | Original is 4:3 |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ | Integer scaling for the HDMI scaler (the framework's `video_freak`; the 15 kHz analog output is not touched). Normal leaves the picture's size to the scaler and the Aspect ratio. The others ask for a whole-number size: the largest whole multiple of the picture's height that fits the screen, and then a width of the aspect ratio's (V-Integer) or a whole multiple of the picture's width (the HV modes: Narrower takes the multiple below the aspect ratio's width, HV-Integer+ the one above it while it fits, HV-Integer the nearer of the two). Examples at 1080p: V-Integer 1194 x 896, HV-Integer and Narrower 1152 x 896 (every pixel 4 x 4), HV-Integer+ 1440 x 896. With Full Screen the screen's own proportions are used for the width |
| Colours | Board DAC, MAME | Board DAC (the default) gives the board's video DAC curve: mid tones darker than MAME's linear palette, as on the PCB. MAME is the palette as it is. See "Release history", 20261025 |
| Flip Screen | Off, On | The picture turned 180 degrees on every output. Done on the finished picture through a frame buffer in the DDR3, so it adds one frame (17 ms) of delay while it is on and nothing when it is off. See below |
| Scandoubler Fx | None, HQ2x, CRT 25%, CRT 50%, CRT 75% | |
| CRT Adjust | submenu: CRT Adjust Off, On; then CRT H-Size 0..+4 / -16..-1, CRT H-Position -48..+20, CRT V-Shift -16..+15 | Fits the picture to a 15 kHz analog (CRT) output: its width, its place in the line and its place in the frame, without the monitor losing sync. Does nothing while the scandoubler is in use. Off by default. See below |
| Test Mode | Off, On | The board's test switch: the game's service menu |
| Audio | Stereo, Mono | The board's mono/stereo input; Mono puts the left mix on both channels |
| Diagnostic overlay | Off, On | Three rows of 32 squares along the bottom of the picture, and the built-in memory test (a few seconds, black screen) after each ROM load |
| SDRAM read capture | Normal, Late | Late samples SDRAM reads one clock later, for a module that answers slowly; try it if the picture is garbage and the overlay shows the SDRAM regions red. At this core's clock phase it is expected to make no difference |
| Reset | | Restarts the machine (the ROM stays loaded) |

**Reading the diagnostic overlay.** Turn it on *before* the ROM loads, or the memory test is skipped and its squares stay
dark. MiSTer starts a game with the settings that were *saved*, so set Diagnostic overlay to On, choose **Save settings** at
the bottom of the OSD, and then load the game again (set it Off and save again afterwards); an option that is only switched
on in the OSD is gone when the game is loaded again. Row 0: frame counter, PLL locked, memory ready, download, test hold, core reset, IRQ5,
68000 stepped, core resets seen, test done / running, tile RAM ok, Z80 stepped. Row 1: the 68000's address, then the seven
regions read back equal to what was loaded (prog, snd, tile, chr, map, pcm, spr) and sound heard. Row 2: the same regions
read stably twice, DDR3 FIFO overflow, the number of lines last frame that a renderer had not finished when the line's
picture began (binary, left square highest; the sprite drawer, the tilemap and the rotating plane are told apart by
the flags' last three squares), sprites in the list / 4, then flags. Row 1's first 24 squares are the live 68000 bus
address and flicker. In normal play the line count is 0.

Scandoubler Fx and MiSTer.ini's `forced_scandoubler` make the core's 15 kHz picture a 31 kHz one (every line twice; HQ2x
and the CRT filters on top). In `monstermaulers_20261010` and `_20261011` they gave no vertical sync at all: the monitor, or
the HDMI scaler, saw a stream without frames and showed a frozen picture (sound playing, 31.5 kHz in MiSTer's video info).
The 15 kHz outputs, which are the ones those builds were tested on, are not affected. Fixed in `monstermaulers_20261012`:
the framework's scandoubler takes its line timing from the horizontal blank's edges and needs them on
every line, vertical blanking included, and this core's blank was the picture window, high through the whole vertical
blank. The core now gives it the horizontal blank alone (`hde` from `mm_video.sv`) with the vertical blank separate; the
15 kHz picture and its timing are as they were (see `docs/mister-memory.md`).

The game is horizontal (ROT0), so there is no rotation option. On a gamepad the default mapping is A / B / R for
Weak / Medium / Strong Attack (the three buttons of the board, named so in MiSTer's button-mapping menu), Start for Start
and Select for Coin (remap it in MiSTer's usual way). Two players; the board has no
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
* The Colours option: **Ace**'s Gerbers and BOM of the
  [K054573 / K054574 reproductions](https://www.ukvac.com/forum/threads/konami-054573-and-054574-reproductions.84054/)
  (the DAC circuit the model is traced from, and the list of games that use it), SiliconRE's
  [K054338 trace](https://github.com/furrtek/SiliconRE/tree/master/Konami/054338) (plain integer maths: the curve is
  the DAC's), and **Franck78**'s [Konami Gaiapolis schematic](https://github.com/Franck78/The-Konami-Gaiapolis-schematic)
  (the video DAC chain of the board family). The model and its fit to PCB footage come from the repository owner's
  Gaiapolis core ([Arcade-Gaiapolis_MiSTer](https://github.com/decoryah/Arcade-Gaiapolis_MiSTer)); the check for this
  game used the "ARCADE PCB - METAMORPHIC FORCE - Ver AAA - 1CC" recording of a real board.
* **Jose Tejada (jotego)** -- JTFRAME's MiSTer SDRAM clock phase and read-capture timing, which this core's PLL and
  controller settings follow.

## Licence

Copyright (C) 2026 decoryah. GPL-3.0, as the Pocket core this is built on (see `LICENSE`). The vendored TG68K.C (LGPL-3.0), CRT Adjust (GPL-3.0 or
later) and tv80 (MIT) in `modules/` keep their own licences (`modules/VENDOR.md`), and the MiSTer framework in `sys/` is
GPL (see the headers of its files).
