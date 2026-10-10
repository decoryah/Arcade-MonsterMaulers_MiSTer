# Monster Maulers -- Konami "pre-GX" hardware (GX170)

Source of truth: MAME 0.289 `src/mame/konami/mystwarr.cpp` (machine `dadandrn`, games `mmaulers`,
`mmaulersu`, `dadandrn`), `mystwarr_v.cpp`, `konamigx_v.cpp`, `konamigx_m.cpp` and the device files named below;
SiliconRE (furrtek) for the K053252's timing and the K054338 / K055555 notes. Everything else was measured with the
Lua probes in `tools/lua/`. MAME's status for these sets is `MACHINE_IMPERFECT_GRAPHICS`, sound `imperfect`.

## 1. Board

| | |
|---|---|
| Game | Monster Maulers (EAA / UAA), Kyukyoku Sentai Dadandarn (JAA), Konami 1993 |
| Board | GX170, the "pre-GX" family it shares with Mystic Warriors, Metamorphic Force, Violent Storm, Martial Champion, Gaiapolis |
| Main CPU | MC68000 @ 16.000 MHz (32 MHz / 2) |
| Sound CPU | Z80 @ 8.000 MHz (32 MHz / 4) |
| Sound | 2 x K054539 @ 18.432 MHz, stereo (+ K054321 latch / master volume) |
| EEPROM | ER5911, 128 x 8 |
| Display | 288 x 224 visible, ROT0, 6.000 MHz pixel clock (K053252 fed 24 MHz, /4), 384 x 264 -> 15.625 kHz, 59.1856 Hz |
| Palette | 2048 entries, xRGB_888, shadows + highlights |
| ROM | 1.5 MB program, 256 KB sound program, 2.5 MB tiles, 10 MB sprites, 1.5 MB + 0.5 MB ROZ, 4 MB PCM |

Raster (K053252 registers the game writes at boot: 0/1 = 0x017F, 2/3 = 0x0019, 4/5 = 0x0027, 8/9 = 0x0107, 10 = 0x10, 11 = 0x0F,
12 = 0x73; SiliconRE's model of the chip, run with them):

```
htotal 384 px   hblank 96 (from the end of the picture)   hsync 32 px, 24 after hblank starts
vtotal 264      vblank 40 lines (17 before the picture, 23 after), vsync 8 lines, 16 after vblank starts (wraps)
picture 288 x 224 at (24, 17)      MAME: set_raw(6 MHz, 384, 0, 287, 264, 0, 223) + visarea(24, 311, 17, 240)
```

The chip is never read by the game (2,500 frames). The vertical interrupt is MAME's `ddd_interrupt`: IRQ5 `HOLD_LINE` at the first line
after the picture (line 241).

## 2. Custom chips

| Chip | Function | Here |
|---|---|---|
| K056832 | tilemap generator, 4 layers over a 4 x 4 grid of 64 x 32 tile pages | `K056832_BPP_5`; `game5bpp_tile_callback`; layers cover all 16 pages |
| K055673 | sprite generator (K053246/7 family) | `K055673_LAYOUT_GX` (5bpp), offsets (-42, -22) |
| K055555 | priority encoder / layer mixer | 4 tile layers + OBJ + SUB1 (the ROZ plane) |
| K054338 | alpha / shadow / brightness colour stage | backdrop, 3 shadow tables, 3 brightness codes, 3 mix levels |
| K053936 ("PSAC2") | rotating / zooming plane | 8bpp tiles, "super" (per-line) mode used; driven through MAME's `K053936GP_*` helpers |
| K053252 | CRTC / interrupt controller | timing above |
| K054321 | main <-> sound latches, master volume | as Gaiapolis |
| K055550 | memset engine on the 68000 bus | command 0x97 only (section 5) |
| ER5911 | serial EEPROM | as Gaiapolis |

## 3. Main CPU memory map (`dadandrn_map`)

| Range | | Function |
|---|---|---|
| `000000-1FFFFF` | R | program ROM (1.5 MB fitted: 0-0FFFFF the 07/09 pair, 100000-17FFFF the 08/10 pair) |
| `400000-40FFFF` | RW | sprite RAM through the K053247's scattered window (as Gaiapolis) |
| `410000-411FFF`, `412000-413FFF` | RW | K056832 tile RAM window (mirrored; 16 pages behind regs[0x19]) |
| `420000-421FFF` | RW | palette, 2048 x 32 bit (00RR GGBB) |
| `430000-430007` | W | K053246 registers |
| `440000-443FFF` | R | K056832 tile ROM read-back (`mw_rom_word_r`, 16 KB: spans two 2048-group banks; 5bpp group = 5 bytes) |
| `450000-45000F` | R | K055673 ROM read-back (`k055673_5bpp_rom_word_r`) |
| `450010-45001F` | W | K055673 registers |
| `460000-46001F` | W | ROZ control block (`k053936_0_ct16`) |
| `470000-470FFF` | RW | ROZ line RAM (`k053936_0_li16`, 2048 words = 4 per raster line) |
| `480000-48003F`, `482000-482007` | W | K056832 VACSET, VSCCS |
| `484000-484003` | W | ROZ clip window (`ddd_053936_clip_w`) |
| `486000-48601F` | RW | K053252 |
| `488000-4880FF` | W | K055555 |
| `48A000-48A01F` | RW | K054321 (high byte) |
| `48C000-48C01F` | W | K054338 |
| `48E000` | R | `IN0_P1` |
| `48E020` | R | `IN1` (high byte) / `P2` (low byte) |
| `600000-60FFFF` | RW | work RAM |
| `680000-68003F` | RW | K055550 |
| `6A0000` | W | EEPROM (DI / CS / CLK on bits 0/1/2 of the low byte) |
| `6C0000` | W | ROZ enable (bit 8) + the ROZ ROM bank of the read-back window (bits 15:14) |
| `6E0000` | W | sound IRQ (Z80 IRQ0) |
| `800000-87FFFF` | R | ROZ map read-back: `gfx4[off] << 8 | gfx4[0x40000 + off]` |
| `A00000-A7FFFF` | R | `gfx4[off / 2]` |
| `C00000-DFFFFF` | R | `gfx3[bank * 0x100000 + off] << 8` |
| `E00000` | W | watchdog |

Unlike Gaiapolis the map is 2 MB of program, the tile ROM window is twice as large, and there is a K055550 where Gaiapolis has a
K054000.

## 4. Video

### Tiles (K056832, 5bpp)
Pages are 64 x 32 tiles of 8 x 8, a layer takes a rectangle of pages from the 4 x 4 grid (regs 8-15: start page and span-1, in pages). Source
position `(vx, vy)` -> page `(rowstart + vy[9:8], colstart + vx[10:9])`. **A layer that spans the whole grid** (this game's layers B-D)
makes MAME turn the K056832's layer-to-page association off; the pages are then drawn by each layer with its own palette and flip bits,
which is also what the renderer does.

ROM: `ROM_LOADTILE_WORD x2` + `ROM_LOADTILE_BYTE` give 5-byte groups per 8-pixel row: bytes 0-3 are packed chunky (byte k = pixels 2k, 2k+1,
high nibble first) and byte 4 is bit 4 of each of the 8 pixels (pixel 0 in bit 7). Pixel value = `{plane5, nibble}`.
`game5bpp_tile_callback`: `color = layer_colorbase | (color >> 1 & 0x1e)`; the gfx granularity is overridden to 16, so the palette
entry is `(color * 16 + pixel) mod 2048` = `{color[6:1], pixel[4:0]}`. Per-layer x offsets (VIDEO_START dadandrn): 2, 4, 6, 7.

### Sprites (K055673 GX layout, 5bpp)
Entry format as Gaiapolis (8 words, 256 entries). `mystwarr_sprite_callback`: `priority_mask = color & 0xe0`,
`color = ((K055555 palette index(4) << 3) & 0x7f) | (color & 0x1f)`, mix code = attribute bits 9:8. 5bpp layout: planes
`{32,24,16,8,0}` bits of a 5-byte group, x offsets `{0-7, 40-47}`, 10 bytes a row: the four low planes are the first 8 MB of the ROM
(one 64-bit word a 16-pixel row, left 8 pixels in bytes 0-3, right 8 in bytes 4-7) and the fifth plane is the 2 MB after it (a 16-bit
word a row: high byte left 8 pixels, low byte right 8). Colour unit 32 entries, so the entry is `{color[5:0], pen[4:0]}`; the shadow
pen is `granularity - 1` = 31 (1 for a "full shadow" object). `konamigx_mixer_primode(1)` takes every z code to 0, so sprites order by
priority, then entry index.

### ROZ plane (K053936)
512 x 512 tiles of 16 x 16 (8192 x 8192 pixels, wraparound). Tile map from `gfx4`: `tile = gfx4[0x40000 + i] | (gfx4[i] & 0x1f) << 8`,
flip x = `gfx4[i] & 0x40`. Characters from `gfx3`: 8bpp, a byte a pixel, 256 bytes a tile (6144 tiles). The plane has one palette group:
`entry = {K055555 SUB1 palette index[2:0], pixel[7:0]}`; pixel 0 is transparent. `K053936GP_set_offset(0, -8, 0)`. Clip window from
`484000` as Gaiapolis (source-space rectangle, 1/2/4 x 128).
*Simple mode* (ctrl[7] bit 6 clear): one affine transform from ctrl. *Super mode* (bit 6 set): per raster line `y`, the line RAM entry
`(y - offs_y) & 0x1ff` gives `startx = (int16)(w0 + ctrl[0]) << 8`, `starty = (int16)(w1 + ctrl[1]) << 8`, `incxx = (int16)w2` (<< 8 if
ctrl[6] bit 15), `incxy = (int16)w3` (<< 8 if bit 7), then `start -= offs_x * inc`. **MAME draws the transform of row N-1 at row N** and
nothing at the first visible row (`dst_ptr += dst_pitch` before its loop); the core does the same (`MAME_SHIFT`), so frames compare
pixel for pixel.

### Mixer (`konamigx_mixer`, K055555 + K054338)
Objects in descending priority, each painted over what the ones behind left, from the K054338 backdrop colour `{reg0[7:0], reg1}`:
tile layers A-D (priority regs 7, 10, 13, 14), SUB1 (16), OBJ (the sprite's `color & 0xe0`), shadow objects (regs 37-39 or the sprite's own).
Ties: sprite first, then its shadow, then SUB1, D, C, B, A (A on top). A mix code picks a level from K054338 regs 13/14 (`mixset`: code 1 =
reg13 low byte, 2 = reg14 high, 3 = reg14 low; level = `(0x1f - v) * 8 | (0x1f - v) >> 2`; bit 5 additive): tile layers take it from
K055555 V_INMIX & V_INMIX_ON, SUB1 from OSBLEND_ENABLES bits 3:2 (ignored when the register is 0xff), a sprite from its attribute.
Blend `d' = (s * a + d * (256 - a)) >> 8` per component; level 255 draws solid, level 0 draws nothing. Brightness (palette contrast
`c * bri / 255`, truncated) is set as each enabled tile layer is drawn, from its V_BRI field and K054338 regs 11/12, and the plane and the
sprites use whatever the last layer left. Shadow: RGB15 expansion + the signed delta of the table (-80 for table 3), clamped unless
K054338 CLIPSL.

## 5. K055550

Word registers at `680000` (32 of them, read back as written). A write of `0x97` (or `0x9f`) to the high byte of register 0 fills, with
register 13's word, `(reg10:reg11) * ((reg0 & 0xff) + 1)` bytes from `(reg7:reg8)` over the 68000's bus; MAME does it in zero time. In
this game it is used for clearing: sixteen commands in a row of 32 x 256 bytes at `410000` (the K056832's tile RAM window, with a
different page selected between the commands: all sixteen pages) at frames 5, 225 and 228 of a boot, and 512 bytes at a time at
`4xxxxx` (sprite RAM) in the attract mode. Violent Storm's other commands (0x87, 0x98, 0xa0, 0xc0) are not used here and are not
modelled. The core holds the 68000 while it runs (a word every few clocks through the same decode a CPU write goes through, so the
sprite window, tile RAM and palette all work): a batch of sixteen is 65,536 words, about 0.24 frames, and the game's timeline is a
frame behind MAME's afterwards (`tools/cmp_lag.py`).

The 68000's IRQ5 handler (`$008188`) is worth knowing when comparing frames: it writes the K053246's register 5 twice a frame
(`$0020` at its start, `$0030` at its end, bit 4 = the sprite DMA / IRQ enable), updates the video registers in its first lines
and runs the game's logic with interrupts enabled; MAME takes its frame snapshot a few lines after the interrupt, so a dump taken
at the start of the vertical blank (as `sim/tb_mm.cpp` does) sees register 5 at `$30` where MAME's has `$20`.

## 6. Sound

As Gaiapolis (`docs/hardware.md` of that core): Z80 with ROM banks at `8000-BFFF` (regs `F800` bits 3:0), the K054539s at `E000-E22F`
and `E400-E62F`, K054321 at `F000-F003`, timer NMI gated by `F800` bit 4. MAME's `MACHINE_RESET dadandrn` raises the voice channels of
chip 1 (channels 4-7) by 2.0, which the core applies.

## 7. Inputs

`IN0_P1`: bits 0-7 P1 (left, right, up, down, buttons 1-3, start), bit 8 coin 1, bit 9 coin 2, bit 11 test, 12/13 service 1/2.
`IN1` (high byte of `48E020`): bit 0 EEPROM DO, bit 1 ready, bit 2 unassigned (0), bit 3 test (low), bit 4 mono/stereo, bit 5 flip screen.
`P2` (low byte of `48E020`): player 2, same layout. MAME declares ports for players 3 and 4 but the map reads only P1 and P2.
