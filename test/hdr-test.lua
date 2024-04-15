
nlcs = require("lnlconn")
nlmh = require("nlmsghdr") --16
cnm = require("cn_msg") --20
w1nlm = require("w1_netlink_msg")
w1cmd = require("w1_netlink_cmd")

--[[
hdr = string.pack("I4I2I2I4I4", 48, 3, 0, 12, 0)
conn = string.pack("I4I4I4I4I2I2", 3, 1, 12, 0, 12, 0)
cmd = string.pack("BBI2I4I4", 6, 0, 0, 0, 0) --12 =48
]]

hn = nlmh:new{seq=12, type=nlcs.NLMSG_DONE}

hc = cnm:new{
  idx=nlcs.CN_W1_IDX,
  val=nlcs.CN_W1_VAL,
  seq=12,
}
hw = w1nlm:new{type=w1nlm.W1_LIST_MASTERS}

s = nlcs.create()

msg = hn:pack(hc:pack(hw:pack()))

--[[
msg2 = hdr .. conn .. cmd

for i = 1,#msg do
  print(string.byte(msg, i), string.byte(msg2, i))
end
--]]

s:write(msg)
buf = s:read()

pos = 1
h1 = {string.unpack("I4I2I2I4I4", buf, pos)}
pos = table.remove(h1)
h2 = {string.unpack("I4I4I4I4I2I2", buf, pos)}
pos = table.remove(h2)
h3 = {string.unpack("BBI2I4I4", buf, pos)}
pos = table.remove(h3)
print("---")
p = hn:unpack(buf, 0)
print("---")
p = hc:unpack(buf, p)
print("---")
--[[
ttt = {string.unpack("BBI2I4I4", buf, p)}
p = table.remove(h3)
]]
ttt, p = hw:unpack(buf, p)
for k,v in pairs(ttt) do print(k, v) end
print("---")
if p < #buf then
  print(string.unpack("I4", buf, p))
end

hn.seq = hn.seq + 1
hc.seq = hn.seq

hw = w1nlm:new{
  type = w1nlm.W1_MASTER_CMD,
  union = string.pack("I4I4", 1, 0)
}

hd = w1cmd:new{
  cmd = w1cmd.W1_CMD_SEARCH
}

msg = hn:pack(hc:pack(hw:pack(hd:pack())))

s:write(msg)
buf = s:read()
for i = 1, #buf do print(string.byte(buf, i)) end
buf = s:read()
for i = 1, #buf do print(string.byte(buf, i)) end
