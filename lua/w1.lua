
local w1_skt = require("w1_con_skt")
local w1_msg = require("w1_netlink_msg")
local w1_cmd = require("w1_netlink_cmd")

local device = {}

function device:new(id, w1)
  o = {id=id, w1=w1}
  setmetatable(o, self)
  self.__index = self
  return o
end

function device:cmd(bytes)
  print(">bytes:", #bytes)
  self.w1:send(
    w1_msg:new{
      type=w1_msg.W1_SLAVE_CMD,
      union = self.id
    }:pack(bytes)
  )
  --return
  return self.w1:recv()
end

function device:read(bytes)
  self.w1:send(
    w1_msg:new{
      type=w1_msg.W1_SLAVE_CMD,
      union = self.id
    }:pack(
      w1_cmd:new{
        cmd=w1_cmd.W1_CMD_READ
      }:pack(string.rep(string.pack("B", 0xff), bytes))
    )
  )
  return self.w1:recv()
end

function device:__tostring()
  local fmt = "%02x-%02x%02x%02x%02x%02x%02x"
  local t = table.pack(string.byte(self.id, 1, #self.id))
  return string.format(fmt, t[1], t[7], t[6], t[5], t[4], t[3], t[2])
end

local master = {}

function master:new(id, w1)
  o = {id=id, w1=w1}
  setmetatable(o, self)
  self.__index = self
  return o
end

function master:search()
  self.w1:send(
    w1_msg:new{
      type=w1_msg.W1_MASTER_CMD,
      union = string.pack("I4I4", self.id, 0)
    }:pack(
      w1_cmd:new({
        cmd=w1_cmd.W1_CMD_SEARCH
      }):pack()
    )
  )
  local devs = {}
  local pkts = self.w1:recv()
  local cmd = w1_cmd:new()
  cmd:unpack(pkts[1].data)
  print(cmd.len)
  for i = 1, cmd.len / 8 do
    d = device:new(string.sub(cmd.data, (i-1)*8 + 1, i*8), self.w1)
    table.insert(devs, d)
  end
  return devs
end

local w1 = {}

function w1:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  o.skt = w1_skt:create(o.groups, o.pid)
  return o
end

function w1:send(data)
  print(">>>")
  return self.skt:send(data)
end

function w1:recv()
  print("<<<")
  return self.skt:recv()
end

function w1:master(id)
  return master:new(id, self)
end

function w1:masters()
  self.skt:send(w1_msg:new{type=w1_msg.W1_LIST_MASTERS}:pack())
  local pkts = self.skt:recv()
  local d = pkts[1].data
  local p, m = 1, 0
  local masters = {}
  while p < #d do
    m, p = string.unpack("I4", d, p)
    table.insert(masters, self:master(m))
  end
  return masters
end
  
return w1