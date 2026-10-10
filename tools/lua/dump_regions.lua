-- Slices of every ROM region as MAME loaded it, to check tools/mm_rom.py's reconstruction against.
--   REGOUT=<file>  (default regions.txt)
local regs = manager.machine.memory.regions
local plan = {
  {":maincpu",  0x400000}, {":soundcpu", 0x040000}, {":k056832", 0x500000}, {":k055673", 0xa00000},
  {":gfx3", 0x180000}, {":gfx4", 0x080000}, {":k054539", 0x400000}, {":eeprom", 0x80},
}
local SLICE = 0x2000
local out = os.getenv("REGOUT") or "regions.txt"
local f = assert(io.open(out, "w"))
for _, e in ipairs(plan) do
  local tag, size = e[1], e[2]
  local r = regs[tag]
  if r == nil then f:write(string.format("MISSING %s\n", tag))
  else
    f:write(string.format("REGION %s size=%d actual=%d\n", tag, size, r.size))
    local align = (tag == ":k056832") and 5 or 1
    local n = math.min(SLICE, size)
    local starts = { 0, math.floor(size/5), math.floor(2*size/5), math.floor(3*size/5), math.floor(4*size/5), size - n }
    if tag == ":k055673" then starts[#starts+1] = 0x800000 end
    for _, off in ipairs(starts) do
      off = off - (off % align)
      if off >= 0 and off + n <= r.size then
        local t = {}
        for i = 0, n-1 do t[i+1] = string.format("%02x", r:read_u8(off+i)) end
        f:write(string.format("SLICE %s %d\n%s\n", tag, off, table.concat(t)))
      end
    end
  end
end
f:close()
print("REGIONS_DUMPED")
manager.machine:exit()
