-- Log CPU writes to chosen ranges with the frame number and the time since the frame's end (vblank start),
-- in 15.625 kHz scanlines: line 0..39 are inside the vertical blank, 40..263 the picture of the next frame.
--   WTAP_FRAMES=<n> to run, SKIPCHK=1 for the simulation's shortcut, WTAP_FROM=<frame> start logging
local mach = manager.machine
local cpu = mach.devices[":maincpu"]
local sp = cpu.spaces["program"]
local KEEP = {}
_G.KEEP = KEEP
local N = tonumber(os.getenv("WTAP_FRAMES") or "300")
local FROM = tonumber(os.getenv("WTAP_FROM") or "0")
if os.getenv("SKIPCHK") == "1" then
  local r = mach.memory.regions[":maincpu"]
  for i, b in ipairs({0x4e, 0xf9, 0x00, 0x00, 0x41, 0x14}) do r:write_u8(0x2eec + i - 1, b) end
end
local f = 0
local tframe = 0
local function now() return mach.time:as_double() end
local ranges = {
  {"rozct", 0x460000, 0x46001f}, {"rozli", 0x470000, 0x470fff}, {"k338", 0x48c000, 0x48c01f},
  {"k555", 0x488000, 0x4880ff}, {"k56", 0x480000, 0x48003f}, {"k46", 0x430000, 0x430007},
  {"rozen", 0x6c0000, 0x6c0001}, {"vram", 0x410000, 0x413fff}, {"pal", 0x420000, 0x421fff}, {"spr", 0x400000, 0x40ffff},
}
for i, r in ipairs(ranges) do
  KEEP["t" .. i] = sp:install_write_tap(r[2], r[3], "w" .. i, function(off, data, mask)
    if f >= FROM then
      print(string.format("WV %s frame %d line %.1f off %x data %04x", r[1], f, (now() - tframe) * 15625.0, off, data & 0xffff))
    end
  end)
end
KEEP.n = emu.add_machine_frame_notifier(function()
  f = f + 1
  tframe = now()
  if f >= N then manager.machine:exit() end
end)
