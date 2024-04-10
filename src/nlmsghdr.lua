
local nlmsghdr = {}

local fields = {
  "len", "type", "flags", "seq", "pid"
}

local pack_spec = "I4I2I2I4I4"

function nlmsghdr:new(t)
  t = t or {}
  setmetatable(t, self)
  self.__index = self
  return t
end

function nlmsghdr:pack(payload)
  payload = payload or ""
  self["len"] = string.packsize(pack_spec) + #payload
  local va = {}
  for i,v in ipairs(fields) do
    table.insert(va, self[v] or 0)
  end
  return string.pack(pack_spec, table.unpack(va)) .. payload
end

function nlmsghdr:unpack(bytes)
  local t = {string.unpack(pack_spec, bytes)}
  local remaining = table.remove(t)
  for i,v in ipairs(fields) do
    self[v] = t[i]
  end
  return remaining
end

return nlmsghdr