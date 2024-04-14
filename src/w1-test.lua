
w1 = require("w1"):new()
w1_cmd = require("w1_netlink_cmd")

m = w1:master(1)

ds = m:search()

for _,d in ipairs(ds) do
  print("found:", ds[1])
  print(ds[1].id:byte(1,-1))
end

d = ds[1]

w = w1_cmd:new()

ps = d:cmd(
  w1_cmd:new{
    cmd=w1_cmd.W1_CMD_WRITE
  }:pack(
    string.pack("BB", 0xF0, 0x0) ..
    w1_cmd:new{
      cmd=w1_cmd.W1_CMD_READ
    }:pack(string.rep(string.char(0),8))
  )
)
--ps = d:read(8)
print("packets:", #ps)
for _,p in ipairs(ps) do
  if p.data then
    print(p.data:byte(1,-1))
    local c = w1_cmd:new()
    c:unpack(p.data)
    print("cmd, len:", c.cmd, c.len)
    print(c.data:byte(1,-1))
  end
end
c = w1_cmd:new()
c:unpack(ps[#ps].data)
print(c.data:byte(1,-1))

--[[
d:write(string.pack("B", 0xc3))
ps = d:read(8)
print("packets:", #ps)
c:unpack(ps[#ps].data)
print(c.data:byte(1,-1))
--]]