w1 = require("w1_con_skt")
w1_msg = require("w1_netlink_msg")
w1_cmd = require("w1_netlink_cmd")

function format_device(...)
  local fmt = "%02x-%02x%02x%02x%02x%02x%02x [%02x]"
  t = table.pack(...)
  return string.format(fmt, t[1], t[7], t[6], t[5], t[4], t[3], t[2], t[8])
end

-- shamelessly stolen from Stack Overflow
local function crc8(t)
  local c = 0
  for _, b in ipairs(t) do
     for i = 0, 7 do
        c = c >> 1 ~ ((c ~ b >> i) & 1) * 0x8C
     end
  end
  return c
end

s = w1:create()
s:send(w1_msg:new{type=w1_msg.W1_LIST_MASTERS}:pack())
pkts = s:recv()

master = string.unpack("I4", pkts[1].data)
print("Master:", master)

s:send(
  w1_msg:new{
    type=w1_msg.W1_MASTER_CMD,
    union = string.pack("I4I4", master, 0)
  }:pack(
    w1_cmd:new({
      cmd=w1_cmd.W1_CMD_SEARCH
    }):pack()
  )
)

pkts = s:recv()
print(#pkts)
cmd = w1_cmd:new()
cmd:unpack(pkts[1].data)
print(cmd.len)
for i = 1, cmd.len / 8 do
  print(
    format_device(string.byte(cmd.data, (i-1)*8 + 1, i*8))
  )
  -- print(crc8({string.byte(cmd.data, (i-1)*8 + 1, i*8 - 1)}))
end

