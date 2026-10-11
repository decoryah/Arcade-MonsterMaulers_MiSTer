-- Freeze frames of Monster Maulers and write everything the frame bench needs,
-- alongside MAME's own snapshot of that same frame. After the Gaiapolis core's
-- (the Pocket repository's) tools/dump_state.lua (the two games share the board's register map).
--
--   DUMPFRAMES=<f,f,f...>  frames to capture
--   DUMPDIR=<dir>          output directory (state_<frame>.txt and snap_<frame>.png go there)
--   FORCE_ENABLE=<hex>     override the K055555 layer-enable register, so a single
--                          layer can be isolated for diffing
--   PICK=l|r               with SCHEDULE=play|playleft: choose the other fighter at the player select
--   SCHEDULE=survey|play|playleft|none   the scripted inputs (default: the survey's, which reaches
--                          the title, a game and the continue screen by ~frame 2500; play: an autoplayer that
--                          continues and reaches the later stages' bosses, the Red Dragon's at ~frame 47000)
--
-- Write-only chip registers are shadowed through write taps. VRAM is 16 pages of
-- 4 KB behind a bank register: after the snapshot is taken (and only then, because
-- it perturbs the chip) the bank is cycled and all of it read, then the registers
-- the cycling touched are put back.

local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local KEEP = {}
_G.DUMPKEEP = KEEP

local function newregs(n) local t = {} for i = 0, n-1 do t[i] = 0 end return t end

local k56_regs  = newregs(32)    -- VACSET   0x480000, word
local k56_regsb = newregs(4)     -- VSCCS    0x482000, word
local k46_regs  = newregs(8)     -- K053246  0x430000, byte pairs
local k47_regs  = newregs(8)     -- K055673  0x450010, word
local k55_regs  = newregs(48)    -- K055555  0x488000, byte in low or high half
local k38_regs  = newregs(16)    -- K054338  0x48C000, word
local roz_ctrl  = newregs(2)     -- 0x6C0000 enable/bank
local roz_clip  = newregs(2)     -- 0x484000

local FORCE_ENABLE = os.getenv("FORCE_ENABLE")
if FORCE_ENABLE then FORCE_ENABLE = tonumber(FORCE_ENABLE, 16) end

KEEP.t1 = sp:install_write_tap(0x480000, 0x48003f, "k56", function(off, data, mask)
  local r = (off - 0x480000) // 2
  local old = k56_regs[r]
  if mask == 0xffff then k56_regs[r] = data & 0xffff
  elseif mask == 0xff00 then k56_regs[r] = (old & 0x00ff) | (data & 0xff00)
  else k56_regs[r] = (old & 0xff00) | (data & 0x00ff) end end)
KEEP.t2 = sp:install_write_tap(0x482000, 0x482007, "k56b", function(off, data, mask)
  local r = (off - 0x482000) // 2
  local old = k56_regsb[r]
  if mask == 0xffff then k56_regsb[r] = data & 0xffff
  elseif mask == 0xff00 then k56_regsb[r] = (old & 0x00ff) | (data & 0xff00)
  else k56_regsb[r] = (old & 0xff00) | (data & 0x00ff) end end)
KEEP.t3 = sp:install_write_tap(0x430000, 0x430007, "k46", function(off, data, mask)
  local w = (off - 0x430000) // 2
  if (mask & 0xff00) ~= 0 then k46_regs[w*2] = (data >> 8) & 0xff end
  if (mask & 0x00ff) ~= 0 then k46_regs[w*2+1] = data & 0xff end end)
KEEP.t4 = sp:install_write_tap(0x450010, 0x45001f, "k47", function(off, data, mask)
  local r = (off - 0x450010) // 2
  local old = k47_regs[r]
  if mask == 0xffff then k47_regs[r] = data & 0xffff
  elseif mask == 0xff00 then k47_regs[r] = (old & 0x00ff) | (data & 0xff00)
  else k47_regs[r] = (old & 0xff00) | (data & 0x00ff) end end)
KEEP.t5 = sp:install_write_tap(0x488000, 0x4880ff, "k55", function(off, data, mask)
  -- K055555_word_w: mem_mask 0x00ff -> low byte, else high byte
  local r = (off - 0x488000) // 2
  local v
  if mask == 0x00ff then v = data & 0xff else v = (data >> 8) & 0xff end
  if r < 48 then k55_regs[r] = v end
  -- layer isolation: rewrite the ENABLE register (45) on its way to the chip
  if FORCE_ENABLE and r == 45 then
    if mask == 0x00ff then return (data & 0xff00) | FORCE_ENABLE
    else return (data & 0x00ff) | (FORCE_ENABLE << 8) end
  end
end)
KEEP.t6 = sp:install_write_tap(0x48c000, 0x48c01f, "k38", function(off, data, mask)
  local r = (off - 0x48c000) // 2
  local old = k38_regs[r]
  if mask == 0xffff then k38_regs[r] = data & 0xffff
  elseif mask == 0xff00 then k38_regs[r] = (old & 0x00ff) | (data & 0xff00)
  else k38_regs[r] = (old & 0xff00) | (data & 0x00ff) end end)
KEEP.t7 = sp:install_write_tap(0x6c0000, 0x6c0001, "rozen", function(off, data, mask)
  roz_ctrl[0] = data & 0xffff end)
KEEP.t8 = sp:install_write_tap(0x484000, 0x484003, "rozclip", function(off, data, mask)
  roz_clip[(off - 0x484000) // 2] = data & 0xffff end)

-- The patch points are found by their code, so every set (EAA, UAA, JAA) is handled alike.
local function find_bytes(r, pat, lo, hi)
  for a = lo, hi - #pat do
    local ok = true
    for i, b in ipairs(pat) do if r:read_u8(a + i - 1) ~= b then ok = false break end end
    if ok then return a end
  end
  return nil
end

-- SKIPCHK=1: the simulation's shortcut over the power-on memory check (the routine's call site
-- becomes a JMP to where the check's success path continues: $002eec -> $004114 in the EAA set), so
-- a MAME run and an RTL run with it can be compared frame for frame
if os.getenv("SKIPCHK") == "1" then
  local r = mach.memory.regions[":maincpu"]
  -- tst.l d0 / bne.s back / jmp <continue>
  local h = find_bytes(r, {0x4a, 0x80, 0x66, 0xee, 0x4e, 0xf9, 0x00, 0x00}, 0x1000, 0x8000)
  if h then
    for i = 0, 5 do r:write_u8(h - 0x16 + i, r:read_u8(h + 4 + i)) end
    print(string.format("SKIPCHK: JMP at $%06x", h - 0x16))
  else print("SKIPCHK: pattern not found") end
end

-- SKIPDLY=1: the boot's software delay (512 x 8,192 iterations, 217 frames; $00422a in the EAA set) cut
-- to 512 x 17 (move.w #$2000,d6 becomes #$0010); as the simulation's SKIPDLY does
if os.getenv("SKIPDLY") == "1" then
  local r = mach.memory.regions[":maincpu"]
  local h = find_bytes(r, {0x3c, 0x3c, 0x20, 0x00, 0x4e, 0x71, 0x51, 0xce, 0xff, 0xfc}, 0x1000, 0x8000)
  if h then
    r:write_u8(h + 2, 0x00); r:write_u8(h + 3, 0x10)
    print(string.format("SKIPDLY: count at $%06x", h + 2))
  else print("SKIPDLY: pattern not found") end
end

local FRAMES = {}
for n in string.gmatch(os.getenv("DUMPFRAMES") or "1800", "%d+") do FRAMES[tonumber(n)] = true end
local LAST = 0; for n in pairs(FRAMES) do if n > LAST then LAST = n end end
local DIR  = os.getenv("DUMPDIR") or "."
local f = 0

local function hexrun(read, n)
  local t = {}
  for i = 1, n do t[i] = string.format("%04x", read(i-1)) end
  return table.concat(t, " ")
end

local function dump()
  mach.video:snapshot()

  local out = assert(io.open(DIR .. "/state_" .. tostring(f) .. ".txt", "w"))
  out:write("# monster maulers frozen state, frame ", tostring(f), "\n")
  out:write("FRAME ", tostring(f), "\n")

  local function regline(name, t, n)
    local a = {}
    for i = 0, n-1 do a[i+1] = string.format("%04x", t[i]) end
    out:write(name, " ", table.concat(a, " "), "\n")
  end
  regline("K56REGS",  k56_regs, 32)
  regline("K56REGSB", k56_regsb, 4)
  regline("K46REGS",  k46_regs, 8)
  regline("K47REGS",  k47_regs, 8)
  regline("K55REGS",  k55_regs, 48)
  regline("K38REGS",  k38_regs, 16)
  regline("ROZCTRL",  roz_ctrl, 1)
  regline("ROZCLIP",  roz_clip, 2)

  -- palette: 2048 entries, two 16-bit words each
  out:write("PALETTE ", hexrun(function(i) return sp:read_u16(0x420000 + i*2) end, 4096), "\n")

  -- ROZ control block and line RAM. 0x460000 is mapped .writeonly(), so a CPU
  -- read returns open bus -- these have to come from the memory shares.
  local shares = mach.memory.shares
  local ct = shares[":k053936_0_ct16"]
  local li = shares[":k053936_0_li16"]
  out:write("ROZCT16 ", hexrun(function(i) return ct:read_u16(i*2) end, 16), "\n")
  out:write("ROZLI16 ", hexrun(function(i) return li:read_u16(i*2) end, 2048), "\n")

  -- sprite RAM: k053247 word w lives at 0x400000 + ((w & 0x7f8) << 5) + (w & 7)*2
  out:write("SPRITERAM ", hexrun(function(w)
      return sp:read_u16(0x400000 + ((w & 0x7f8) << 5) + (w & 7) * 2)
    end, 2048), "\n")

  -- VRAM: 16 pages of 0x1000 words behind the bank register at 0x480032. Done last:
  -- it perturbs the chip; the registers it touches are put back.
  local saved_r0  = k56_regs[0]
  local saved_r19 = k56_regs[0x19]
  out:write("CURPAGE ", hexrun(function(i) return sp:read_u16(0x410000 + i*2) end, 4096), "\n")
  for page = 0, 15 do
    local col, row = page & 3, (page >> 2) & 3
    sp:write_u16(0x480000, saved_r0 & ~0x0002)      -- internal linescroll
    sp:write_u16(0x480032, (row << 3) | col)
    out:write(string.format("VRAM %d ", page),
              hexrun(function(i) return sp:read_u16(0x410000 + i*2) end, 4096), "\n")
  end
  sp:write_u16(0x480000, saved_r0)
  sp:write_u16(0x480032, saved_r19)
  out:close()
  print("DUMPED frame " .. tostring(f))
  io.stdout:flush()
end

-- scripted inputs
local p1 = mach.ioport.ports[":IN0_P1"]
local coin, start = p1.fields["Coin 1"], p1.fields["1 Player Start"]
local b1, b2, rt, up, dn, lf = p1.fields["P1 Button 1"], p1.fields["P1 Button 2"], p1.fields["P1 Right"], p1.fields["P1 Up"], p1.fields["P1 Down"], p1.fields["P1 Left"]
local SCHED = os.getenv("SCHEDULE") or "survey"

KEEP.notif = emu.add_machine_frame_notifier(function()
  f = f + 1
  local n = f
  if SCHED == "play" or SCHED == "playleft" then
    -- a fighter that walks right and mashes attack, continuing when it dies; it plays through the stages in order
    -- (the first stage is the default map choice). Same inputs as the autoplayer used to find the later bosses.
    if n >= 1595 and n < 1700 and (os.getenv("PICK") or "") ~= "" then
      -- the player select: PICK=l or r presses the stick once (either gives the woman fighter), start confirms
      local pick = os.getenv("PICK")
      coin:set_value(0); b1:set_value(0); b2:set_value(0); up:set_value(0); dn:set_value(0)
      rt:set_value((pick == "r" and n >= 1640 and n < 1648) and 1 or 0)
      lf:set_value((pick == "l" and n >= 1640 and n < 1648) and 1 or 0)
      start:set_value((n >= 1670 and n < 1678) and 1 or 0)
    elseif n >= 1790 and n < 1900 then
      -- the map select: the stick up and start once, then the autoplayer takes over
      coin:set_value(0); b1:set_value(0); b2:set_value(0); rt:set_value(0); lf:set_value(0); dn:set_value(0)
      up:set_value((n >= 1830 and n < 1842) and 1 or 0)
      start:set_value((n >= 1880 and n < 1890) and 1 or 0)
    else
      coin:set_value((n > 200 and (n % 240) < 8) and 1 or 0)
      start:set_value((n > 260 and (n % 90) < 8 and (n % 240) >= 8) and 1 or 0)
      if n > 500 then
        b1:set_value((n % 7 < 3) and 1 or 0)
        b2:set_value((n % 61 < 2) and 1 or 0)
        if SCHED == "playleft" and n >= 46000 then
          -- the Red Dragon fight with the fighter kept at the left edge
          rt:set_value(0)
          lf:set_value(1)
        else
          rt:set_value((n % 160 < 130) and 1 or 0)
          lf:set_value(((n + 40) % 400 < 12) and 1 or 0)
        end
        up:set_value((n % 97 < 18) and 1 or 0)
        dn:set_value((n % 131 > 112) and 1 or 0)
      end
    end
  end
  if SCHED == "survey" then
    coin:set_value((n > 200 and (n % 120) < 8) and 1 or 0)
    start:set_value((n > 260 and (n % 90) < 8 and (n % 120) >= 8) and 1 or 0)
    if n > 500 then
      b1:set_value((n % 11 < 4) and 1 or 0)
      b2:set_value((n % 29 < 3) and 1 or 0)
      rt:set_value((n % 97 < 40) and 1 or 0)
      lf:set_value((n % 131 > 100) and 1 or 0)
      up:set_value((n % 53 < 20) and 1 or 0)
      dn:set_value((n % 71 > 60) and 1 or 0)
    end
  end
  if FRAMES[f] then dump() end
  if f >= LAST then mach:exit() end
end)
