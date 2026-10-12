
-- SPDX-License-Identifier: MIT

local nl_conn = require("lnlconn")
local nlmsghdr = require("nlmsghdr")
local cn_msg = require("cn_msg")
local w1_msg = require("w1_netlink_msg")
local w1_cmd = require("w1_netlink_cmd")

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

-- Number of commands carried by each w1_netlink_msg in a request payload
-- (0 for messages that carry none, such as W1_LIST_MASTERS).
local function count_cmds(payload)
  local counts, pos = {}, 1
  while pos + w1_msg.size - 1 <= #payload do
    local mtype, _, mlen = string.unpack("BBI2", payload, pos)
    pos = pos + w1_msg.size
    local n = 0
    if mtype == w1_msg.W1_MASTER_CMD or mtype == w1_msg.W1_SLAVE_CMD then
      local cpos, cend = pos, pos + mlen
      while cpos + w1_cmd.size <= cend do
        local _, _, clen = string.unpack("BBI2", payload, cpos)
        n = n + 1
        cpos = cpos + w1_cmd.size + clen
      end
    end
    counts[#counts + 1] = n
    pos = pos + mlen
  end
  return counts
end

function _M:send(payload)
  self.hdr.seq = self.seq + 1
  self.msg.seq = self.hdr.seq
  self.seq = self.msg.seq
  self.pending = count_cmds(payload)
  return self.skt:write(self.hdr:pack(self.msg:pack(payload)))
end

-- Reads replies to the last request and returns them as a list of
-- w1_netlink_msg objects, in the order the kernel sent them.
--
-- The kernel answers each command with an optional data reply (cn ack =
-- seq + 1) followed by a zero-length status reply, so the ack is not an
-- end marker.  Instead, stop on the status of the last command of the last
-- message, or on a message-level status (len < one cmd header, e.g. an
-- error), or, for messages without commands, on their first reply.  This
-- ends exactly on the final reply and leaves nothing queued for the next
-- request.
function _M:recv()
  local pending = self.pending
  if not pending or #pending == 0 then
    return nil, "no request pending"
  end
  local seq = self.seq
  local pkts = {}
  local hdr, msg = nlmsghdr:new(), cn_msg:new()
  local idx, left = 1, pending[1]
  while true do
    local pkt, err, errno = self.skt:read()
    if not pkt then
      return nil, err or "socket closed", errno
    end
    local off = 1
    -- a datagram may hold several nlmsghdr messages
    while off + nlmsghdr.size - 1 <= #pkt do
      local p = hdr:unpack(pkt, off)
      if hdr.len < nlmsghdr.size then
        break
      end
      if hdr.type == nl_conn.NLMSG_ERROR then
        return nil, "netlink error"
      end
      local stop = math.min(off + hdr.len, #pkt + 1)
      if p + cn_msg.size <= stop then
        p = msg:unpack(pkt, p)
        -- ignore anything that isn't a reply to the current request
        if msg.seq == seq then
          -- the cn_msg payload may hold several w1 messages (bundle)
          local mstop = math.min(p + msg.len, stop)
          while p + w1_msg.size <= mstop do
            local m = w1_msg:new()
            p = m:unpack(pkt, p)
            pkts[#pkts + 1] = m
            local done
            if m.type == w1_msg.W1_MASTER_CMD or m.type == w1_msg.W1_SLAVE_CMD then
              if m.len < w1_cmd.size then
                done = true -- message-level status, remaining commands skipped
              elseif string.unpack("I2", m.data, 3) == 0 then
                left = left - 1 -- per-command status
                done = left <= 0
              end
            else
              done = true
            end
            if done then
              idx = idx + 1
              if idx > #pending then
                return pkts
              end
              left = pending[idx]
            end
          end
        end
      end
      off = off + ((hdr.len + 3) & ~3) -- NLMSG_ALIGN
    end
  end
end

return _M
