-- Which of the main CPU's read-side effects does the game depend on? Counts reads of chosen ranges.
--   READFRAMES=<n> frames to run (default 2500)
local mach = manager.machine
local sp = mach.devices[":maincpu"].spaces["program"]
local KEEP = {}
_G.KEEP = KEEP
local N = tonumber(os.getenv("READFRAMES") or "2500")
local ranges = {
  {"k252  486000", 0x486000, 0x48601f}, {"k321  48a000", 0x48a000, 0x48a01f}, {"k550  680000", 0x680000, 0x68003f},
  {"in0   48e000", 0x48e000, 0x48e001}, {"in1   48e020", 0x48e020, 0x48e021}, {"k56 rom 440000", 0x440000, 0x443fff},
  {"k55673rb 450000", 0x450000, 0x45000f}, {"rb0 800000", 0x800000, 0x87ffff}, {"rb1 a00000", 0xa00000, 0xa7ffff},
  {"rb2 c00000", 0xc00000, 0xdfffff}, {"palette 420000", 0x420000, 0x421fff}, {"sprwin 400000", 0x400000, 0x40ffff},
  {"vram 410000", 0x410000, 0x413fff}, {"rozli 470000", 0x470000, 0x470fff}, {"k338 48c000", 0x48c000, 0x48c01f},
  {"unmapped 600000-60ffff is work ram", 0, 0},
}
local counts, pcs = {}, {}
for i, r in ipairs(ranges) do
  counts[i] = 0; pcs[i] = {}
  if r[2] ~= 0 then
    KEEP["t" .. i] = sp:install_read_tap(r[2], r[3], "rd" .. i, function(off, data, mask)
      counts[i] = counts[i] + 1
      local pc = mach.devices[":maincpu"].state["PC"].value
      pcs[i][pc] = (pcs[i][pc] or 0) + 1
    end)
  end
end
local f = 0
KEEP.n = emu.add_machine_frame_notifier(function()
  f = f + 1
  if f >= N then
    for i, r in ipairs(ranges) do
      if r[2] ~= 0 then
        local top = {}
        for pc, n in pairs(pcs[i]) do top[#top+1] = {pc, n} end
        table.sort(top, function(a, b) return a[2] > b[2] end)
        local s = {}
        for k = 1, math.min(4, #top) do s[#s+1] = string.format("%06x(%d)", top[k][1], top[k][2]) end
        print(string.format("READS %-18s %8d  pcs: %s", r[1], counts[i], table.concat(s, " ")))
      end
    end
    mach:exit()
  end
end)
-- the same scripted inputs
local p1 = mach.ioport.ports[":IN0_P1"]
local coin, start = p1.fields["Coin 1"], p1.fields["1 Player Start"]
local b1, b2, rt, up, dn, lf = p1.fields["P1 Button 1"], p1.fields["P1 Button 2"], p1.fields["P1 Right"], p1.fields["P1 Up"], p1.fields["P1 Down"], p1.fields["P1 Left"]
KEEP.in_ = emu.add_machine_frame_notifier(function()
  local n = f
  coin:set_value((n > 200 and (n % 120) < 8) and 1 or 0)
  start:set_value((n > 260 and (n % 90) < 8 and (n % 120) >= 8) and 1 or 0)
  if n > 500 then
    b1:set_value((n % 11 < 4) and 1 or 0); b2:set_value((n % 29 < 3) and 1 or 0)
    rt:set_value((n % 97 < 40) and 1 or 0); lf:set_value((n % 131 > 100) and 1 or 0)
    up:set_value((n % 53 < 20) and 1 or 0); dn:set_value((n % 71 > 60) and 1 or 0)
  end
end)
