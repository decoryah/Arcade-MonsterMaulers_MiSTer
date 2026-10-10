-- Print the frame each time the main CPU reaches one of the BPADDRS (hex, comma separated).
--   BPFRAMES=<n> frames to run, SKIPCHK=1 for the simulation's shortcut. Needs the debugger interface (-debug).
local mach = manager.machine
local cpu = mach.devices[":maincpu"]
local KEEP = {}
_G.KEEP = KEEP
local N = tonumber(os.getenv("BPFRAMES") or "260")
if os.getenv("SKIPCHK") == "1" then
  local r = mach.memory.regions[":maincpu"]
  for i, b in ipairs({0x4e, 0xf9, 0x00, 0x00, 0x41, 0x14}) do r:write_u8(0x2eec + i - 1, b) end
end
local f = 0
local hits = {}
local dbg = cpu.debug
if not dbg then print("NO DEBUG INTERFACE") end
for a in string.gmatch(os.getenv("BPADDRS") or "", "%x+") do
  hits[tonumber(a, 16)] = 0
  if dbg then dbg:bpset(tonumber(a, 16), "1", string.format("printf \"BP %%06x frame\n\",%d; g", tonumber(a, 16))) end
end
KEEP.n = emu.add_machine_frame_notifier(function()
  f = f + 1
  if f >= N then manager.machine:exit() end
end)
