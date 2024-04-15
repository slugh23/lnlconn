local w1_netlink_cmd = {
	W1_CMD_READ = 0,
	W1_CMD_WRITE = 1,
	W1_CMD_SEARCH = 2,
	W1_CMD_ALARM_SEARCH = 3,
	W1_CMD_TOUCH = 4,
	W1_CMD_RESET = 5,
	W1_CMD_SLAVE_ADD = 6,
	W1_CMD_SLAVE_REMOVE = 7,
	W1_CMD_LIST_SLAVES = 8
}

local fields = {
  "cmd", "res", "len"
}

local pack_spec = "BBI2"

function w1_netlink_cmd:new(t)
  t = t or {}
  setmetatable(t, self)
  self.__index = self
  return t
end

function w1_netlink_cmd.from_pkt(pkt)
  o = w1_netlink_cmd:new()
  rem = o:unpack(pkt)
  return o, rem
end

function w1_netlink_cmd:pack(payload)
  payload = payload or ""
  self["len"] = #payload
  va = {}
  for i,v in ipairs(fields) do
    table.insert(va, self[v] or 0)
  end
  return string.pack(pack_spec, table.unpack(va)) .. payload
end

function w1_netlink_cmd:unpack(bytes, pos)
  pos = pos or 1
  local t = {string.unpack(pack_spec, bytes, pos)}
  pos = table.remove(t)
  for i,v in ipairs(fields) do
    self[v] = t[i]
  end
  self.data = bytes:sub(pos, -1)
  return pos
end

return w1_netlink_cmd