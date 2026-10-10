-- The 68000's PC at the end of each frame, for lining a simulation up with MAME.
--   PCFRAMES=<n> frames to run (default 60), PCOUT=<file>, SKIPCHK=1 patches the program as the
--   simulation's SKIPCHK does (JMP $004114 at $002eec)
local mach = manager.machine
local cpu = mach.devices[":maincpu"]
local KEEP = {}
_G.KEEP = KEEP
local N = tonumber(os.getenv("PCFRAMES") or "60")
local out = assert(io.open(os.getenv("PCOUT") or "pctrace.txt", "w"))
if os.getenv("SKIPCHK") == "1" then
  local r = mach.memory.regions[":maincpu"]
  for i, b in ipairs({0x4e, 0xf9, 0x00, 0x00, 0x41, 0x14}) do r:write_u8(0x2eec + i - 1, b) end
end
local f = 0
KEEP.n = emu.add_machine_frame_notifier(function()
  f = f + 1
  out:write(string.format("frame %d pc=%06x\n", f, cpu.state["PC"].value))
  if f >= N then out:close(); mach:exit() end
end)
