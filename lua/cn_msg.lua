-- SPDX-License-Identifier: MIT

local cn_msg = {}

local fields = {
  "idx", "val", "seq", "ack", "len", "flags"
}

local pack_spec = "I4I4I4I4I2I2"

function cn_msg:new(t)
  t = t or {}
  setmetatable(t, self)
  self.__index = self
  return t
end

function cn_msg:pack(payload)
  payload = payload or ""
  self["len"] = #payload
  va = {}
  for i,v in ipairs(fields) do
    table.insert(va, self[v] or 0)
  end
  return string.pack(pack_spec, table.unpack(va)) .. payload
end

function cn_msg:__concat(payload)
  if type(payload) == "table" then
    payload = payload:pack()
  end
  return self.pack(payload)
end

function cn_msg:unpack(bytes, pos)
  pos = pos or 1
  local t = {string.unpack(pack_spec, bytes, pos)}
  local remaining = table.remove(t)
  for i,v in ipairs(fields) do
    self[v] = t[i]
  end
  return remaining
end

return cn_msg