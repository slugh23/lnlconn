
-- SPDX-License-Identifier: MIT

local w1_skt = require("w1_con_skt")
local w1_msg = require("w1_netlink_msg")
local w1_cmd = require("w1_netlink_cmd")

local device = {}

function device:new(id, w1)
  local o = {id=id, w1=w1}
  setmetatable(o, self)
  self.__index = self
  return o
end

function device:cmd(bytes)
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

-- Memory access for 1-Wire EEPROMs (family code is the first id byte).
-- Only the data memory is addressable: the DS2431's protection registers
-- (0x80 and up) and the DS2430A's application register are permanent once
-- written, so they are out of range here.  "writer" is set below.
local memory = {
  [0x23] = {size = 512, abytes = 2},                           -- DS2433, read only
  [0x2d] = {size = 128, abytes = 2, row = 8, writable = true, teds = true}, -- DS2431
  [0x14] = {size = 32, abytes = 1, writable = true, teds = true,
            has_app = true},                                   -- DS2430A
}

local TEDS_PAGE = 32 -- byte 0 of every page is a two's complement checksum

local TPROG_MS = 11 -- time to leave the bus idle after COPY SCRATCHPAD

local function msleep(ms)
  local t = os.clock() + ms / 1000
  while os.clock() < t do end
end

local function memory_info(dev)
  return memory[dev.id:byte(1)]
end

-- Returns pkts, or nil, err, status if the request failed or a reply
-- carries a non-zero status.
local function transact(dev, bytes)
  local pkts, err, errno = dev:cmd(bytes)
  if not pkts then
    return nil, err, errno
  end
  for _, m in ipairs(pkts) do
    if m.status ~= 0 then
      return nil, "w1 error", m.status
    end
  end
  return pkts
end

-- Data of the first READ reply holding n bytes.
local function read_data(pkts, n)
  for _, m in ipairs(pkts) do
    if m.len >= w1_cmd.size then
      local c = w1_cmd.from_pkt(m.data)
      if c.cmd == w1_cmd.W1_CMD_READ and c.len == n then
        return c.data
      end
    end
  end
  return nil, "no data in reply"
end

local function write_cmd(bytes)
  return w1_cmd:new{cmd=w1_cmd.W1_CMD_WRITE}:pack(bytes)
end

local function read_cmd(n)
  return w1_cmd:new{cmd=w1_cmd.W1_CMD_READ}:pack(string.rep("\xff", n))
end

-- Reads n bytes starting at addr with one READ MEMORY (0xF0) request.
-- The command has no CRC, so with proof=true the read is repeated until two
-- consecutive reads agree (what the kernel driver does), at twice the cost.
function device:read_memory(addr, n, proof)
  local info = memory_info(self)
  if not info then
    return nil, "unsupported device family"
  end
  if addr < 0 or n < 1 or addr + n > info.size then
    return nil, "address out of range"
  end
  local req = write_cmd(string.pack(info.abytes == 1 and "<BB" or "<BI2", 0xF0, addr))
           .. read_cmd(n)
  local function once()
    local pkts, err, status = transact(self, req)
    if not pkts then
      return nil, err, status
    end
    return read_data(pkts, n)
  end
  local data, err, status = once()
  if not data or not proof then
    return data, err, status
  end
  for _ = 1, 3 do
    local again
    again, err, status = once()
    if not again then
      return nil, err, status
    end
    if again == data then
      return data
    end
    data = again
  end
  return nil, "reads did not agree"
end

-- Writes one 8-byte row: WRITE SCRATCHPAD, read it back and compare, then
-- COPY SCRATCHPAD and leave the bus idle while the cell programs.
local function write_row(dev, addr, row)
  local ta = string.pack("<I2", addr)
  local es = "\x07"
  local load = write_cmd("\x0F" .. ta .. row)
  local check = write_cmd("\xAA") .. read_cmd(11)
  for _ = 1, 3 do
    local pkts, err, status = transact(dev, load)
    if not pkts then
      return nil, err, status
    end
    pkts, err, status = transact(dev, check)
    if not pkts then
      return nil, err, status
    end
    local got
    got, err = read_data(pkts, 11)
    if not got then
      return nil, err
    end
    if got == ta .. es .. row then
      pkts, err, status = transact(dev, write_cmd("\x55" .. ta .. es))
      if not pkts then
        return nil, err, status
      end
      msleep(TPROG_MS)
      return true
    end
  end
  return nil, "scratchpad verify failed"
end

-- DS2431: only the 8-byte rows that actually change are programmed.
local function write_ds2431(self, info, addr, data)
  local first, last = addr // info.row, (addr + #data - 1) // info.row
  local base = first * info.row
  local span = (last - first + 1) * info.row
  local cur, err, status = self:read_memory(base, span, true)
  if not cur then
    return nil, err, status
  end
  local skip = addr - base
  local new = cur:sub(1, skip) .. data .. cur:sub(skip + #data + 1)
  for r = 0, last - first do
    local o = r * info.row + 1
    local row = new:sub(o, o + info.row - 1)
    if row ~= cur:sub(o, o + info.row - 1) then
      local ok
      ok, err, status = write_row(self, base + r * info.row, row)
      if not ok then
        return nil, err, status
      end
    end
  end
  local back
  back, err, status = self:read_memory(base, span, true)
  if not back then
    return nil, err, status
  end
  if back ~= new then
    return nil, "verify failed"
  end
  return true
end

-- DS2430A: COPY SCRATCHPAD always copies the whole 32-byte scratchpad, so the
-- merged image is loaded in full and copied once, and only if it changed.
local function write_ds2430a(self, info, addr, data)
  local cur, err, status = self:read_memory(0, info.size, true)
  if not cur then
    return nil, err, status
  end
  local new = cur:sub(1, addr) .. data .. cur:sub(addr + #data + 1)
  if new == cur then
    return true
  end
  local load = write_cmd("\x0F\x00" .. new)
  local check = write_cmd("\xAA\x00") .. read_cmd(info.size)
  local copy = write_cmd("\x55\xA5")
  local copied = false
  for _ = 1, 3 do
    local pkts
    pkts, err, status = transact(self, load)
    if not pkts then
      return nil, err, status
    end
    pkts, err, status = transact(self, check)
    if not pkts then
      return nil, err, status
    end
    local got
    got, err = read_data(pkts, info.size)
    if not got then
      return nil, err
    end
    if got == new then
      pkts, err, status = transact(self, copy)
      if not pkts then
        return nil, err, status
      end
      msleep(TPROG_MS)
      copied = true
      break
    end
  end
  if not copied then
    return nil, "scratchpad verify failed"
  end
  local back
  back, err, status = self:read_memory(0, info.size, true)
  if not back then
    return nil, err, status
  end
  if back ~= new then
    return nil, "verify failed"
  end
  return true
end

memory[0x2d].writer = write_ds2431
memory[0x14].writer = write_ds2430a

-- Writes data at addr (any alignment) and verifies the result by reading it
-- back.  Only data that actually changes is programmed.
function device:write_memory(addr, data)
  local info = memory_info(self)
  if not info or not info.writable then
    return nil, "writing not supported for this device"
  end
  if addr < 0 or #data < 1 or addr + #data > info.size then
    return nil, "address out of range"
  end
  return info.writer(self, info, addr, data)
end

-- DS2430A application register: 64 bits, one-time programmable.  Only
-- reading is supported; locking it is permanent.
function device:app_register_locked()
  local info = memory_info(self)
  if not info or not info.has_app then
    return nil, "no application register"
  end
  local pkts, err, status = transact(self, write_cmd("\x66\x00") .. read_cmd(1))
  if not pkts then
    return nil, err, status
  end
  local st
  st, err = read_data(pkts, 1)
  if not st then
    return nil, err
  end
  return (st:byte() & 3) == 0 -- the two low bits clear once it is locked
end

-- Returns the 8 bytes, or nil, "application register not locked": until it
-- is locked the device answers with the register scratchpad instead.
function device:read_app_register()
  local locked, err, status = self:app_register_locked()
  if locked == nil then
    return nil, err, status
  end
  if not locked then
    return nil, "application register not locked"
  end
  local pkts
  pkts, err, status = transact(self, write_cmd("\xC3\x00") .. read_cmd(8))
  if not pkts then
    return nil, err, status
  end
  return read_data(pkts, 8)
end

local function checksum(bytes)
  local sum = 0
  for i = 1, #bytes do
    sum = sum + bytes:byte(i)
  end
  return (-sum) & 0xff
end

-- The TEDS bytes without the per-page checksums, ready for a decoder.  The
-- DS2430A's locked application register comes first and is covered by the
-- checksum of its only page.  Returns payload, {pages=, application=}.
-- Bad checksums return nil, "checksum mismatch in page N" (pages count from
-- 0) unless opts.verify == false.  opts.proof reads the memory twice.
function device:read_teds(opts)
  opts = opts or {}
  local info = memory_info(self)
  if not info or not info.teds then
    return nil, "unsupported device family"
  end
  local app, err, status = "", nil, nil
  if info.has_app then
    local locked
    locked, err, status = self:app_register_locked()
    if locked == nil then
      return nil, err, status
    end
    if locked then
      app, err, status = self:read_app_register()
      if not app then
        return nil, err, status
      end
    end
  end
  local data
  data, err, status = self:read_memory(0, info.size, opts.proof)
  if not data then
    return nil, err, status
  end
  local pages, parts = info.size // TEDS_PAGE, {app}
  for p = 0, pages - 1 do
    local page = data:sub(p * TEDS_PAGE + 1, (p + 1) * TEDS_PAGE)
    local body = page:sub(2)
    if opts.verify ~= false and
       checksum((p == 0 and app or "") .. body) ~= page:byte(1) then
      return nil, "checksum mismatch in page " .. p
    end
    parts[#parts + 1] = body
  end
  return table.concat(parts), {pages = pages, application = #app > 0}
end

-- Writes TEDS bytes as returned by read_teds, adding the checksums.  Shorter
-- payloads are padded with zeros.  On a DS2430A with a locked application
-- register the payload must start with the register's 8 bytes, which are
-- never written.
function device:write_teds(payload)
  local info = memory_info(self)
  if not info or not info.teds then
    return nil, "unsupported device family"
  end
  local app, err, status = "", nil, nil
  if info.has_app then
    local locked
    locked, err, status = self:app_register_locked()
    if locked == nil then
      return nil, err, status
    end
    if locked then
      app, err, status = self:read_app_register()
      if not app then
        return nil, err, status
      end
    end
  end
  local pages = info.size // TEDS_PAGE
  local capacity = #app + pages * (TEDS_PAGE - 1)
  if #payload > capacity then
    return nil, "payload too long (" .. capacity .. " bytes at most)"
  end
  payload = payload .. string.rep("\0", capacity - #payload)
  if payload:sub(1, #app) ~= app then
    return nil, "payload differs from the locked application register"
  end
  local body, parts = payload:sub(#app + 1), {}
  for p = 0, pages - 1 do
    local chunk = body:sub(p * (TEDS_PAGE - 1) + 1, (p + 1) * (TEDS_PAGE - 1))
    parts[#parts + 1] = string.char(checksum((p == 0 and app or "") .. chunk)) .. chunk
  end
  return self:write_memory(0, table.concat(parts))
end

function device:__tostring()
  local fmt = "%02x-%02x%02x%02x%02x%02x%02x"
  local t = table.pack(string.byte(self.id, 1, #self.id))
  return string.format(fmt, t[1], t[7], t[6], t[5], t[4], t[3], t[2])
end

local bridge = {}

function bridge:new(id, w1)
  local o = {id=id, w1=w1}
  setmetatable(o, self)
  self.__index = self
  return o
end

function bridge:search()
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
  local pkts, err, errno = self.w1:recv()
  if not pkts or not pkts[1] then
    return nil, err or "no reply", errno
  end
  if pkts[1].status ~= 0 then
    return nil, "w1 error", pkts[1].status
  end
  local cmd = w1_cmd:new()
  cmd:unpack(pkts[1].data)
  --print(cmd.len)
  for i = 1, cmd.len / 8 do
    local d = device:new(string.sub(cmd.data, (i-1)*8 + 1, i*8), self.w1)
    table.insert(devs, d)
  end
  return devs
end

function bridge:__tostring()
  return string.format("w1_bus_master%d", self.id)
end

local w1 = {}

function w1:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  o.skt = w1_skt:create{groups=o.groups, pid=o.pid, timeout=o.timeout}
  return o
end

function w1:send(data)
  --print(">>>")
  return self.skt:send(data)
end

function w1:recv()
  --print("<<<")
  return self.skt:recv()
end

function w1:bridge(id)
  return bridge:new(id, self)
end

function w1:bridges()
  self.skt:send(w1_msg:new{type=w1_msg.W1_LIST_MASTERS}:pack())
  local pkts, err, errno = self.skt:recv()
  if not pkts or not pkts[1] then
    return nil, err or "no reply", errno
  end
  if pkts[1].status ~= 0 then
    return nil, "w1 error", pkts[1].status
  end
  local d = pkts[1].data
  local p, m = 1, 0
  local bridges = {}
  while p < #d do
    m, p = string.unpack("I4", d, p)
    table.insert(bridges, self:bridge(m))
  end
  return bridges
end
  
return w1