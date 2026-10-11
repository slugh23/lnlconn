
-- SPDX-License-Identifier: MIT

local nl_conn = require("lnlconn")
local nlmsghdr = require("nlmsghdr")
local cn_msg = require("cn_msg")
local w1_msg = require("w1_netlink_msg")

local _M = {}

function _M:create(t)
  -- create socket and store idx/val.
  t = t or {}
  local o = {
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
  local pkts = {}
  while true do
    local pkt, err, errno = self.skt:read()
    if not pkt then
      return nil, err or "socket closed", errno
    end
    local off = 1
    -- a datagram may hold several nlmsghdr messages
    while off + nlmsghdr.size - 1 <= #pkt do
      local hdr = nlmsghdr:new()
      local p = hdr:unpack(pkt, off)
      if hdr.len < nlmsghdr.size then
        break
      end
      if hdr.type == nl_conn.NLMSG_ERROR then
        return nil, "netlink error"
      end
      local stop = math.min(off + hdr.len, #pkt + 1)
      if p + cn_msg.size <= stop then
        local msg = cn_msg:new()
        p = msg:unpack(pkt, p)
        -- the cn_msg payload may hold several w1 messages (bundle)
        local mstop = math.min(p + msg.len, stop)
        while p + w1_msg.size <= mstop do
          local w1m = w1_msg:new()
          p = w1m:unpack(pkt, p)
          table.insert(pkts, w1m)
        end
        if msg.seq > 0 and msg.ack == msg.seq + 1 then
          return pkts
        end
      end
      off = off + ((hdr.len + 3) & ~3) -- NLMSG_ALIGN
    end
  end
end

return _M
