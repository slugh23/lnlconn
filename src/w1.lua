
w1_skt = require("w1_con_skt")
w1_msg = require("w1_netlink_msg")
w1_cmd = require("w1_netlink_cmd")

local master = {}

function master:new(id, w1)
  o = {id=id, skt=w1.skt}
  setmetatable(o, self)
  self.__index = self
  return o
end

function master:search()
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
end
  self.id

local w1 = {}

function w1:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  o.skt = w1_skt:create(o.groups, o.pid)
end

function w1:masters()
  self.skt:send(w1_msg:new{type=w1_msg.W1_LIST_MASTERS}:pack())
  pkts = self.skt:recv()
  local d = pkts[1].data
  local p, m = 1, 0
  local masters = {}
  while p < #d do
    m, p = string.unpack("I4", d, p)
    table.insert(masters, master:new(m, self))
  end
end
  
return w1