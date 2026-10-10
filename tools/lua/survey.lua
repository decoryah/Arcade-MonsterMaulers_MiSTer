-- Survey of what Monster Maulers (mmaulers) exercises, over a run with scripted inputs.
--   SURVEYF=<frames>   number of frames to run (default 3000)
--   SURVEYOUT=<file>   report file
--   SNAPFRAMES=a,b,c   frames to save a MAME snapshot of
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local KEEP = {}
_G.KEEP = KEEP
local NF   = tonumber(os.getenv("SURVEYF") or "3000")
local OUT  = os.getenv("SURVEYOUT") or "survey.txt"
local want = {}
for n in string.gmatch(os.getenv("SNAPFRAMES") or "", "%d+") do want[tonumber(n)] = true end

local f = 0
local log = {}
local function L(s) log[#log+1] = s end

-- distinct values seen per register
local function distinct() return setmetatable({}, {__index=function(t,k) local v={n=0,seen={}} rawset(t,k,v) return v end}) end
local k252 = distinct(); local k338 = distinct(); local k555 = distinct(); local k56 = distinct(); local k56b = distinct()
local k46  = distinct(); local k47 = distinct(); local k550 = distinct()
local function note(tab, r, v, fr)
  local e = tab[r]
  if not e.seen[v] then e.seen[v] = fr; e.n = e.n + 1 end
end
local k550cmds = {}
local k555seq = {}

KEEP.t252 = sp:install_write_tap(0x486000, 0x48601f, "k252", function(off, data, mask)
  note(k252, (off-0x486000)//2, data & 0xff, f) end)
KEEP.t338 = sp:install_write_tap(0x48c000, 0x48c01f, "k338", function(off, data, mask)
  note(k338, (off-0x48c000)//2, data & 0xffff, f) end)
KEEP.t555 = sp:install_write_tap(0x488000, 0x4880ff, "k555", function(off, data, mask)
  local r = (off - 0x488000)//2
  local v = (mask == 0x00ff) and (data & 0xff) or ((data >> 8) & 0xff)
  note(k555, r, v, f)
end)
KEEP.t56 = sp:install_write_tap(0x480000, 0x48003f, "k56", function(off, data, mask)
  note(k56, (off-0x480000)//2, data & 0xffff, f) end)
KEEP.t56b = sp:install_write_tap(0x482000, 0x482007, "k56b", function(off, data, mask)
  note(k56b, (off-0x482000)//2, data & 0xffff, f) end)
KEEP.t46 = sp:install_write_tap(0x430000, 0x430007, "k46", function(off, data, mask)
  note(k46, (off-0x430000)//2, data & 0xffff, f) end)
KEEP.t47 = sp:install_write_tap(0x450010, 0x45001f, "k47", function(off, data, mask)
  note(k47, (off-0x450010)//2, data & 0xffff, f) end)
local roz = {en = {}, clip = {}}
KEEP.trozen = sp:install_write_tap(0x6c0000, 0x6c0001, "rozen", function(off, data, mask)
  roz.en[data & 0xffff] = (roz.en[data & 0xffff] or f) end)
KEEP.trozclip = sp:install_write_tap(0x484000, 0x484003, "rozclip", function(off, data, mask)
  local k = string.format("%d:%04x", (off-0x484000)//2, data & 0xffff)
  roz.clip[k] = (roz.clip[k] or f) end)
local k550w = {}
KEEP.t550 = sp:install_write_tap(0x680000, 0x68003f, "k550", function(off, data, mask)
  local r = (off - 0x680000)//2
  k550w[#k550w+1] = string.format("f%d r%d=%04x/%04x", f, r, data & 0xffff, mask & 0xffff)
  if #k550w > 400 then table.remove(k550w, 1) end
  if r == 0 and (mask & 0xff00) ~= 0 then
    local c = (data >> 8) & 0xff
    k550cmds[c] = (k550cmds[c] or 0) + 1
  end
end)

-- sprite statistics, taken from the live sprite RAM each frame
local spr = {maxactive=0, eff=0, shd=0, both=0, fr_eff=0, zs=0, maxsz=0, effvals={}, shdvals={}, zcodes={}}
local function sprword(w) return sp:read_u16(0x400000 + ((w & 0x7f8) << 5) + (w & 7) * 2) end

local p1 = mach.ioport.ports[":IN0_P1"]
local coin, start = p1.fields["Coin 1"], p1.fields["1 Player Start"]
local b1, b2, rt, up, dn, lf = p1.fields["P1 Button 1"], p1.fields["P1 Button 2"], p1.fields["P1 Right"], p1.fields["P1 Up"], p1.fields["P1 Down"], p1.fields["P1 Left"]

KEEP.notif = emu.add_machine_frame_notifier(function()
  f = f + 1
  local n = f
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
  if want[f] then mach.video:snapshot() end
  if f % 4 == 0 then
    local act, e, s, fe = 0, 0, 0, false
    for i = 0, 255 do
      local w0 = sprword(i*8)
      if (w0 & 0x8000) ~= 0 then
        act = act + 1
        local c = sprword(i*8 + 6)
        local ef, sh = (c >> 8) & 3, (c >> 10) & 3
        if ef ~= 0 then e = e + 1; spr.effvals[ef] = (spr.effvals[ef] or 0) + 1; fe = true end
        if sh ~= 0 then s = s + 1; spr.shdvals[sh] = (spr.shdvals[sh] or 0) + 1 end
        local z = w0 & 0xff
        spr.zcodes[z] = (spr.zcodes[z] or 0) + 1
      end
    end
    if act > spr.maxactive then spr.maxactive = act end
    spr.eff = spr.eff + e; spr.shd = spr.shd + s
    if fe then spr.fr_eff = spr.fr_eff + 1 end
  end
  if f >= NF then
    local function dump(name, tab, fmt)
      L("== " .. name)
      local keys = {}
      for k in pairs(tab) do keys[#keys+1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local vs = {}
        for v, fr in pairs(tab[k].seen) do vs[#vs+1] = {v, fr} end
        table.sort(vs, function(a, b) return a[2] < b[2] end)
        local s = {}
        for i, e in ipairs(vs) do if i <= 12 then s[#s+1] = string.format(fmt .. "@%d", e[1], e[2]) end end
        L(string.format("  r%-2d n=%-3d %s%s", k, tab[k].n, table.concat(s, " "), tab[k].n > 12 and " ..." or ""))
      end
    end
    dump("K053252 (byte)", k252, "%02x"); dump("K054338", k338, "%04x"); dump("K055555", k555, "%02x")
    dump("K056832 VACSET", k56, "%04x"); dump("K056832 VSCCS", k56b, "%04x")
    dump("K053246", k46, "%04x"); dump("K055673 regs", k47, "%04x")
    L("== K055550 commands (byte -> count)")
    for c, n in pairs(k550cmds) do L(string.format("  %02x x%d", c, n)) end
    L("== K055550 last writes"); for _, s in ipairs(k550w) do L("  " .. s) end
    L("== ROZ enable writes"); for v, fr in pairs(roz.en) do L(string.format("  %04x @%d", v, fr)) end
    L("== ROZ clip writes (first few)"); local c = 0
    for k, fr in pairs(roz.clip) do c = c + 1; if c <= 16 then L(string.format("  %s @%d", k, fr)) end end
    L(string.format("== sprites: max active %d, effect-bit sprites (sampled) %d, frames with effect %d, shadow-bit sprites %d",
      spr.maxactive, spr.eff, spr.fr_eff, spr.shd))
    for k, v in pairs(spr.effvals) do L(string.format("  effect %d x%d", k, v)) end
    for k, v in pairs(spr.shdvals) do L(string.format("  shadow %d x%d", k, v)) end
    local zc = 0; for _ in pairs(spr.zcodes) do zc = zc + 1 end
    L(string.format("  distinct zcodes: %d", zc))
    local fh = assert(io.open(OUT, "w")); fh:write(table.concat(log, "\n"), "\n"); fh:close()
    print("SURVEY DONE frame " .. f); io.stdout:flush()
    mach:exit()
  end
end)
