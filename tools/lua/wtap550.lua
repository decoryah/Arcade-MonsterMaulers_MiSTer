-- Log the CPU writes to 0x610000-0x6fffff (the K055550 at 0x680000, the EEPROM, ROZ enable, sound IRQ): frame, PC, register, data, mask.
--   WTAP_FRAMES=<n> frames to run (default 60); SKIPCHK=1 applies the simulation shortcut
local mach = manager.machine
local cpu = mach.devices[":maincpu"]
local sp = cpu.spaces["program"]
local KEEP = {}
_G.KEEP = KEEP
local N = tonumber(os.getenv("WTAP_FRAMES") or "60")
if os.getenv("SKIPCHK") == "1" then
  local bytes = {0x4e, 0xf9, 0x00, 0x00, 0x41, 0x14}
  local r = mach.memory.regions[":maincpu"]
  for i, b in ipairs(bytes) do r:write_u8(0x2eec + i - 1, b) end
end
local f = 0
KEEP.t = sp:install_write_tap(0x610000, 0x6fffff, "k550", function(off, data, mask)
  print(string.format("W550 frame %d off %x data %04x mask %04x pc %06x", f, off, data & 0xffff, mask & 0xffff, cpu.state["PC"].value))
end)
KEEP.n = emu.add_machine_frame_notifier(function()
  f = f + 1
  if f >= N then manager.machine:exit() end
end)
