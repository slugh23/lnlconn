
local nl_conn = require("lnlconn")
local nlmsghdr = require("nlmsghdr")
local cn_msg = require("cn_msg")
local w1_msg = require("w1_netlink_msg")

local _M = {}

function _M:create(t)
  -- create socket and store idx/val.
  t = t or {}
  o = {
    seq=0,
    idx=nl_conn.CN_W1_IDX,
    val=nl_conn.CN_W1_VAL,
    hdr=nlmsghdr:new{
      type=nl_conn.NLMSG_DONE
    },
    msg=cn_msg:new{
      idx=nl_conn.CN_W1_IDX,
      val=nl_conn.CN_W1_VAL
    },
    skt = nl_conn.create{groups=t.groups, pid=t.pid}
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

function _M:send(payload)
  self.hdr.seq = self.seq + 1
  self.msg.seq = self.hdr.seq
  self.seq = self.msg.seq
  return self.skt:write(self.hdr:pack(self.msg:pack(payload)))
end

function _M:recv()
  local ack = false
  local pkts = {}
  local t, p
  while not ack do
    local hdr = nlmsghdr:new()
    local msg = cn_msg:new()
    local w1m = w1_msg:new()
    local pkt = self.skt:read()
    -- don't care much about the nlmsghdr.
    p = hdr:unpack(pkt, 0)
    p = msg:unpack(pkt, p)
    print("seq, ack:", msg.seq, msg.ack)
    p = w1m:unpack(pkt, p)
    table.insert(pkts, w1m)
    if msg.seq > 0 and msg.ack == msg.seq + 1 then
      ack = true
    end
  end
  return pkts
end

return _M