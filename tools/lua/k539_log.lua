-- Log every Z80 write to the two K054539s with its time in 48 kHz samples, so a chip-level bench can replay the game's
-- sound programming and an analysis can list what a piece of music plays.
--   K539OUT=<file>   output (default k539_writes.txt)
--   K539SECS=<n>     stop after n emulated seconds (default 110)
-- line: <sample index> <chip 1|2> <register 0..0x22f> <value>
local mach = manager.machine
local sp   = mach.devices[":soundcpu"].spaces["program"]
local OUT  = os.getenv("K539OUT") or "k539_writes.txt"
local SECS = tonumber(os.getenv("K539SECS") or "110")
local f = io.open(OUT, "w")
local KEEP = {}
_G.K539KEEP = KEEP
local function sample() return math.floor(mach.time:as_double() * 48000 + 0.5) end
KEEP.t1 = sp:install_write_tap(0xe000, 0xe22f, "k539_1", function(off, data, mask)
  f:write(string.format("%d 1 %d %d\n", sample(), off - 0xe000, data & 0xff))
end)
KEEP.t2 = sp:install_write_tap(0xe400, 0xe62f, "k539_2", function(off, data, mask)
  f:write(string.format("%d 2 %d %d\n", sample(), off - 0xe400, data & 0xff))
end)
emu.register_frame_done(function()
  if mach.time:as_double() >= SECS then f:close(); mach:exit() end
end)
