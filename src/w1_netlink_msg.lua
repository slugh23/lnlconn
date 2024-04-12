local w1_netlink_msg = {
	W1_SLAVE_ADD = 0,
	W1_SLAVE_REMOVE = 1,
	W1_MASTER_ADD = 2,
	W1_MASTER_REMOVE = 3,
	W1_MASTER_CMD = 4,
	W1_SLAVE_CMD = 5,
	W1_LIST_MASTERS = 6,
}

local fields = {
  "type", "status", "len", "union"
}

local pack_spec = "BBI2c8"

function w1_netlink_msg:new(t)
  t = t or {}
  setmetatable(t, self)
  self.__index = self
  return t
end

function w1_netlink_msg.from_pkt(pkt)
  o = w1_netlink_msg:new()
  rem = o:unpack(pkt)
  return o, rem
end

function w1_netlink_msg:pack(payload)
  payload = payload or ""
  self["len"] = #payload
  va = {}
  for i,v in ipairs(fields) do
    table.insert(va, self[v] or 0)
  end
  return string.pack(pack_spec, table.unpack(va)) .. payload
end

function w1_netlink_msg:unpack(bytes, pos)
  pos = pos or 1
  local t = {string.unpack(pack_spec, bytes, pos)}
  pos = table.remove(t)
  for i,v in ipairs(fields) do
    self[v] = t[i]
  end
  self.data = bytes:sub(pos, -1)
  return pos
end

return w1_netlink_msg