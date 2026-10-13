-- SPDX-License-Identifier: MIT
--
-- Tests device:read_memory and device:write_memory against simulated DS2431,
-- DS2433 and DS2430A devices.  No hardware or kernel w1 support is needed.
--
-- Run from the repository root:  lua5.4 test/w1-memory-sim-test.lua

package.path = "./lua/?.lua;" .. package.path
package.loaded["lnlconn"] = {
  CN_W1_IDX = 3, CN_W1_VAL = 1, NLMSG_DONE = 3, NLMSG_ERROR = 2,
  create = function() return {} end,
}

-- A simulated EEPROM behind a fake w1_con_skt.  It answers the way the kernel
-- does: a data reply followed by a zero-length status reply for each command.
local function make_sim(family, size, opts)
  opts = opts or {}
  local sim = {mem = {}, requests = 0, programmed = 0,
               corrupt_reads = 0, corrupt_scratch = 0,
               protected_touched = false}
  for i = 0, size - 1 do sim.mem[i] = (i * 7 + 3) % 256 end
  sim.id = string.char(family) .. "\1\2\3\4\5\6\7"
  sim.locked = opts.locked or false           -- DS2430A application register
  sim.app = opts.app or string.rep("\0", 8)
  local replies = {}
  local scratch_ta, scratch_data, es -- DS2431
  local pg_ta, pg_data               -- DS2433
  sim.copied_bytes = 0
  local pad = {}                     -- DS2430A
  for i = 0, 31 do pad[i] = 0 end

  local function cmdmsg(mtype, cmd, data)
    data = data or ""
    return {type = mtype, status = 0, len = 4 + #data,
            data = string.pack("BBI2", cmd, 0, #data) .. data}
  end
  local function status(mtype, cmd) return cmdmsg(mtype, cmd, "") end
  local function mem_str(a, n)
    local t = {}
    for i = a, a + n - 1 do t[#t + 1] = string.char(sim.mem[i]) end
    return table.concat(t)
  end

  local function do_write(tx)
    local op = tx:byte(1)
    if family == 0x14 then
      if op == 0x0F and #tx >= 2 then
        local a = tx:byte(2)
        for i = 3, #tx do pad[(a + i - 3) % 32] = tx:byte(i) end
        if sim.corrupt_scratch > 0 then
          sim.corrupt_scratch = sim.corrupt_scratch - 1
          pad[a] = (pad[a] + 1) % 256
        end
      elseif op == 0x55 and #tx == 2 then
        assert(tx:byte(2) == 0xA5, "bad validation key")
        for i = 0, 31 do sim.mem[i] = pad[i] end
        sim.programmed = sim.programmed + 1
      elseif op == 0x99 or op == 0x5A then
        sim.protected_touched = true -- would write or lock the register
      end
    elseif family == 0x23 then
      if op == 0x0F and #tx >= 4 then
        pg_ta, pg_data = tx:sub(2, 3), tx:sub(4)
        assert(#pg_data <= 32 - string.unpack("<I2", pg_ta) % 32, "scratchpad write crosses a page")
        if sim.corrupt_scratch > 0 then
          sim.corrupt_scratch = sim.corrupt_scratch - 1
          pg_data = string.char((pg_data:byte(1) + 1) % 256) .. pg_data:sub(2)
        end
      elseif op == 0x55 and #tx == 4 then
        local a = string.unpack("<I2", pg_ta)
        assert(tx:sub(2, 3) == pg_ta and tx:byte(4) == (a + #pg_data - 1) & 0x1f, "bad copy")
        for i = 1, #pg_data do sim.mem[a + i - 1] = pg_data:byte(i) end
        sim.programmed = sim.programmed + 1
        sim.copied_bytes = sim.copied_bytes + #pg_data
      end
    elseif family == 0x2d then
      if op == 0x0F and #tx == 11 then
        scratch_ta, scratch_data, es = tx:sub(2, 3), tx:sub(4, 11), "\7"
        if sim.corrupt_scratch > 0 then
          sim.corrupt_scratch = sim.corrupt_scratch - 1
          scratch_data = "\0" .. scratch_data:sub(2)
        end
      elseif op == 0x55 and #tx == 4 then
        assert(tx:sub(2, 3) == scratch_ta and tx:sub(4, 4) == es, "bad copy")
        local a = string.unpack("<I2", scratch_ta)
        assert(a < 0x80, "write outside data memory")
        for i = 1, 8 do sim.mem[a + i - 1] = scratch_data:byte(i) end
        sim.programmed = sim.programmed + 1
      end
    end
  end

  local function do_read(tx, n)
    local op, out = tx:byte(1), ""
    if family == 0x14 then
      local a = tx:byte(2) or 0
      if op == 0xF0 then
        for i = 0, 31 do pad[i] = sim.mem[i] end -- memory -> scratchpad
        local t = {}
        for i = 0, n - 1 do t[#t + 1] = string.char(sim.mem[(a + i) % 32]) end
        out = table.concat(t)
      elseif op == 0xAA then
        local t = {}
        for i = 0, n - 1 do t[#t + 1] = string.char(pad[(a + i) % 32]) end
        out = table.concat(t)
      elseif op == 0x66 then
        out = string.char(sim.locked and 0xFC or 0xFF)
      elseif op == 0xC3 then
        out = sim.locked and sim.app or string.rep("\0", n) -- else the scratchpad
      end
    elseif op == 0xF0 then
      out = mem_str(string.unpack("<I2", tx, 2), n)
    elseif op == 0xAA and family == 0x2d then
      out = scratch_ta .. es .. scratch_data
    elseif op == 0xAA and family == 0x23 then
      local a = string.unpack("<I2", pg_ta)
      out = pg_ta .. string.char((a + #pg_data - 1) & 0x1f) .. pg_data
    end
    if op == 0xF0 and sim.corrupt_reads > 0 then
      sim.corrupt_reads = sim.corrupt_reads - 1
      out = "\255" .. out:sub(2)
    end
    return out
  end

  function sim:send(payload)
    sim.requests = sim.requests + 1
    replies = {}
    local pos = 1
    while pos + 11 <= #payload do
      local mtype, _, mlen = string.unpack("BBI2", payload, pos)
      local body = payload:sub(pos + 12, pos + 11 + mlen)
      pos = pos + 12 + mlen
      if mtype == 6 then
        replies[#replies + 1] = {type = 6, status = 0, len = 4, data = "\1\0\0\0"}
      elseif mtype == 4 then
        replies[#replies + 1] = cmdmsg(4, 2, sim.id)
        replies[#replies + 1] = status(4, 2)
      elseif mtype == 5 then
        local tx, cp = "", 1
        while cp + 3 <= #body do
          local cmd, _, clen = string.unpack("BBI2", body, cp)
          local cdata = body:sub(cp + 4, cp + 3 + clen)
          cp = cp + 4 + clen
          if cmd == 1 then -- WRITE
            tx = tx .. cdata
            do_write(tx)
            replies[#replies + 1] = status(5, 1)
          elseif cmd == 0 then -- READ
            replies[#replies + 1] = cmdmsg(5, 0, do_read(tx, clen))
            replies[#replies + 1] = status(5, 0)
          end
        end
      end
    end
  end
  function sim:recv() return replies end

  function sim:memstr()
    return mem_str(0, size)
  end
  return sim
end

local function make_device(family, size, opts)
  local sim = make_sim(family, size, opts)
  package.loaded["w1_con_skt"] = {create = function() return sim end}
  package.loaded["w1"] = nil
  local bus = require("w1"):new()
  local dev = bus:bridges()[1]:search()[1]
  return dev, sim
end

local function eq(a, b, msg)
  if a ~= b then
    error(msg .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

local function expect_error(ok, err, want, msg)
  if ok or err ~= want then
    error(msg .. ": expected error '" .. want .. "', got " .. tostring(err), 2)
  end
end

-- Original bytes a..b (0-based, inclusive) captured before any writes.
local function snapshot(sim, size)
  local t = {}
  for i = 0, size - 1 do t[i] = sim.mem[i] end
  return function(a, b)
    local s = {}
    for i = a, b do s[#s + 1] = string.char(t[i]) end
    return table.concat(s)
  end
end

-- ---- DS2431: 128 bytes, 8-byte rows ----
do
  local dev, sim = make_device(0x2d, 128)
  local orig = snapshot(sim, 128)

  eq(#dev:read_memory(0, 128), 128, "ds2431 full read")
  eq(dev:read_memory(5, 10), sim:memstr():sub(6, 15), "ds2431 partial read")

  assert(dev:write_memory(0x40, "ABCDEFGH"))
  eq(sim.programmed, 1, "aligned write programs 1 row")
  eq(sim:memstr():sub(0x41, 0x48), "ABCDEFGH", "aligned data")

  sim.programmed = 0
  assert(dev:write_memory(0x3c, "12345678"))
  eq(sim.programmed, 2, "unaligned write programs 2 rows")
  eq(sim:memstr():sub(0x3d, 0x44), "12345678", "unaligned data")
  eq(sim:memstr():sub(1, 0x3c), orig(0, 0x3b), "bytes before untouched")
  eq(sim:memstr():sub(0x49), orig(0x48, 127), "bytes after untouched")

  sim.programmed = 0
  assert(dev:write_memory(0x3c, "12345678"))
  eq(sim.programmed, 0, "identical data programs nothing")

  assert(dev:write_memory(0x41, "Z"))
  eq(sim.programmed, 1, "one changed byte programs 1 row")
  eq(sim:memstr():sub(0x42, 0x42), "Z", "single byte")

  local before = sim.requests
  for _, c in ipairs{{0x7f, "xy"}, {0x80, "x"}, {-1, "x"}, {0, ""}} do
    local ok, err = dev:write_memory(c[1], c[2])
    expect_error(ok, err, "address out of range", "range")
  end
  assert(not dev:read_memory(120, 16))
  assert(not dev:read_memory(128, 1))
  eq(sim.requests, before, "range errors send nothing")

  sim.corrupt_reads = 1
  eq(dev:read_memory(0, 16, true), sim:memstr():sub(1, 16), "proof read recovers")
  sim.corrupt_reads = 1
  assert(dev:read_memory(0, 16) ~= sim:memstr():sub(1, 16), "plain read is unchecked")

  sim.programmed, sim.corrupt_scratch = 0, 1
  assert(dev:write_memory(0x10, "retry!!!"))
  eq(sim.programmed, 1, "retry still programs once")
  eq(sim:memstr():sub(0x11, 0x18), "retry!!!", "retry data")

  sim.programmed, sim.corrupt_scratch = 0, 99
  local ok, err = dev:write_memory(0x20, "fail----")
  expect_error(ok, err, "scratchpad verify failed", "persistent failure")
  eq(sim.programmed, 0, "failed write programs nothing")
end

-- ---- DS2433: 512 bytes, 32-byte pages, partial-page writes ----
do
  local dev, sim = make_device(0x23, 512)
  local orig = snapshot(sim, 512)

  eq(#dev:read_memory(0, 512), 512, "ds2433 full read")
  eq(dev:read_memory(30, 6), sim:memstr():sub(31, 36), "read across a page")

  assert(dev:write_memory(5, "abcd"))
  eq(sim.programmed, 1, "partial page is one copy")
  eq(sim.copied_bytes, 4, "only the four bytes are copied")
  eq(sim:memstr():sub(6, 9), "abcd", "data")
  eq(sim:memstr():sub(1, 5), orig(0, 4), "bytes before untouched")
  eq(sim:memstr():sub(10, 32), orig(9, 31), "rest of the page untouched")

  sim.programmed, sim.copied_bytes = 0, 0
  assert(dev:write_memory(30, "123456"))
  eq(sim.programmed, 2, "a write across a page boundary is two copies")
  eq(sim.copied_bytes, 6, "six bytes copied")
  eq(sim:memstr():sub(31, 36), "123456", "data across the boundary")

  sim.programmed = 0
  assert(dev:write_memory(30, "123456"))
  eq(sim.programmed, 0, "identical data programs nothing")

  sim.programmed, sim.copied_bytes = 0, 0
  assert(dev:write_memory(30, "12X456"))
  eq(sim.programmed, 1, "one changed byte is one copy")
  eq(sim.copied_bytes, 1, "only that byte is copied")
  eq(sim:memstr():sub(31, 36), "12X456", "single byte change")

  local big = string.rep("0123456789abcdef", 32)
  sim.programmed = 0
  assert(dev:write_memory(0, big))
  eq(sim:memstr(), big, "whole memory"); eq(sim.programmed, 16, "16 pages")

  -- options: skipping the pre-read and the final read-back
  local r0 = sim.requests
  assert(dev:write_memory(100, "zz", {compare = false, verify = false}))
  eq(sim.requests - r0, 3, "load, check and copy only")
  eq(sim:memstr():sub(101, 102), "zz", "data")
  sim.programmed = 0
  assert(dev:write_memory(100, "zz", {compare = false, verify = false}))
  eq(sim.programmed, 1, "compare=false programs unchanged data")
  r0 = sim.requests
  assert(dev:write_memory(100, "yy", {verify = false}))
  eq(sim.requests - r0, 5, "pre-read (2) + load, check, copy")
  r0 = sim.requests
  assert(dev:write_memory(100, "xx"))
  eq(sim.requests - r0, 7, "pre-read (2) + load, check, copy + verify (2)")

  sim.programmed, sim.corrupt_scratch = 0, 1
  assert(dev:write_memory(200, "retry"))
  eq(sim.programmed, 1, "retry copies once"); eq(sim:memstr():sub(201, 205), "retry", "retry data")

  sim.programmed, sim.corrupt_scratch = 0, 99
  local ok, err = dev:write_memory(300, "fail")
  expect_error(ok, err, "scratchpad verify failed", "persistent failure")
  eq(sim.programmed, 0, "failed write copies nothing")
  sim.corrupt_scratch = 0

  local before = sim.requests
  for _, c in ipairs{{511, "xy"}, {512, "x"}, {-1, "x"}, {0, ""}} do
    local ok2, err2 = dev:write_memory(c[1], c[2])
    expect_error(ok2, err2, "address out of range", "range")
  end
  eq(sim.requests, before, "range errors send nothing")
end

-- ---- DS2430A: 32 bytes, 1-byte addresses, whole-scratchpad copy ----
do
  local dev, sim = make_device(0x14, 32)
  local orig = snapshot(sim, 32)

  eq(dev:read_memory(0, 32), sim:memstr(), "ds2430a full read")
  eq(dev:read_memory(4, 6), sim:memstr():sub(5, 10), "ds2430a partial read")

  assert(dev:write_memory(5, "hello"))
  eq(sim.programmed, 1, "write copies once")
  eq(sim:memstr():sub(6, 10), "hello", "data")
  eq(sim:memstr():sub(1, 5), orig(0, 4), "bytes before untouched")
  eq(sim:memstr():sub(11), orig(10, 31), "bytes after untouched")

  sim.programmed = 0
  assert(dev:write_memory(5, "hello"))
  eq(sim.programmed, 0, "identical data programs nothing")

  assert(dev:write_memory(0, string.rep("\xAA", 32)))
  eq(sim:memstr(), string.rep("\xAA", 32), "full write")
  assert(dev:write_memory(31, "Z"))
  eq(sim:memstr():sub(32), "Z", "last byte")

  local before = sim.requests
  for _, c in ipairs{{31, "xy"}, {32, "x"}, {-1, "x"}, {0, ""}} do
    local ok, err = dev:write_memory(c[1], c[2])
    expect_error(ok, err, "address out of range", "range")
  end
  assert(not dev:read_memory(30, 4))
  eq(sim.requests, before, "range errors send nothing")

  sim.programmed, sim.corrupt_scratch = 0, 1
  assert(dev:write_memory(2, "retry"))
  eq(sim.programmed, 1, "retry copies once")
  eq(sim:memstr():sub(3, 7), "retry", "retry data")

  sim.programmed, sim.corrupt_scratch = 0, 99
  local ok, err = dev:write_memory(9, "nope")
  expect_error(ok, err, "scratchpad verify failed", "persistent failure")
  eq(sim.programmed, 0, "failed write copies nothing")
  sim.corrupt_scratch = 0

  sim.corrupt_reads = 1
  eq(dev:read_memory(0, 32, true), sim:memstr(), "proof read recovers")
  eq(sim.protected_touched, false, "application register never touched")
end

-- ---- verify=false skips the final read-back on every family ----
for _, c in ipairs{{0x2d, 128, 0x40}, {0x14, 32, 4}, {0x23, 512, 0x40}} do
  local dev, sim = make_device(c[1], c[2])
  local r0 = sim.requests
  assert(dev:write_memory(c[3], "A"))
  local with = sim.requests - r0
  r0 = sim.requests
  assert(dev:write_memory(c[3], "B", {verify = false}))
  eq(with - (sim.requests - r0), 2, string.format("family %02x: the read-back is two requests", c[1]))
  eq(sim:memstr():sub(c[3] + 1, c[3] + 1), "B", "verify=false still writes")
end

-- ---- TEDS: checksums added and removed by the device ----
local function checksum(s)
  local sum = 0
  for i = 1, #s do sum = sum + s:byte(i) end
  return (-sum) & 0xff
end

do -- DS2431: four pages, 31 payload bytes each
  local dev, sim = make_device(0x2d, 128)
  local payload = string.rep("TEDS", 31) -- 124 bytes
  assert(dev:write_teds(payload))
  local mem = sim:memstr()
  for p = 0, 3 do
    local page = mem:sub(p * 32 + 1, p * 32 + 32)
    eq(page:byte(1), checksum(page:sub(2)), "ds2431 page " .. p .. " checksum")
  end
  local got, info = dev:read_teds()
  eq(got, payload, "ds2431 round trip"); eq(info.pages, 4, "pages"); eq(info.application, false, "no application")
  eq(#got, 124, "payload excludes the checksums")

  sim.programmed = 0
  assert(dev:write_teds(payload)); eq(sim.programmed, 0, "unchanged TEDS programs nothing")

  assert(dev:write_teds("short"))
  eq(dev:read_teds(), "short" .. string.rep("\0", 124 - 5), "short payload is zero padded")

  local ok0, err0 = dev:write_teds(string.rep("x", 125))
  expect_error(ok0, err0, "payload too long (124 bytes at most)", "too long")

  -- corrupt one byte of page 2 behind the device's back
  sim.mem[2 * 32 + 5] = (sim.mem[2 * 32 + 5] + 1) % 256
  local ok, err = dev:read_teds()
  expect_error(ok, err, "checksum mismatch in page 2", "corruption detected")
  local raw = dev:read_teds{verify = false}
  eq(#raw, 124, "verify=false still returns the bytes")
end

do -- DS2430A with a locked application register: it is part of page 0's checksum
  local app = "\19\0\226\164\253\58\48\0"
  local dev, sim = make_device(0x14, 32, {locked = true, app = app})
  eq(dev:app_register_locked(), true, "locked")
  eq(dev:read_app_register(), app, "application register")
  local body = string.rep("\xA5", 31)
  assert(dev:write_teds(app .. body))
  eq(sim:memstr():byte(1), checksum(app .. body), "checksum covers the application register")
  eq(sim:memstr():sub(2), body, "data bytes")
  local got, info = dev:read_teds()
  eq(got, app .. body, "locked round trip"); eq(#got, 39, "8 + 31 bytes"); eq(info.application, true, "application flag")
  local ok, err = dev:write_teds(string.rep("\0", 8) .. body)
  expect_error(ok, err, "payload differs from the locked application register", "register is never overwritten")
  local ok2, err2 = dev:write_teds(app .. string.rep("x", 32))
  expect_error(ok2, err2, "payload too long (39 bytes at most)", "too long")
  sim.mem[7] = (sim.mem[7] + 1) % 256
  local ok3, err3 = dev:read_teds()
  expect_error(ok3, err3, "checksum mismatch in page 0", "corruption detected")
  eq(sim.protected_touched, false, "register never written or locked")
end

do -- DS2430A with the register not locked: just the 32-byte page
  local dev, sim = make_device(0x14, 32, {locked = false})
  eq(dev:app_register_locked(), false, "not locked")
  local ok, err = dev:read_app_register()
  expect_error(ok, err, "application register not locked", "no register to read")
  assert(dev:write_teds("abc"))
  local got, info = dev:read_teds()
  eq(#got, 31, "31 payload bytes"); eq(got:sub(1, 3), "abc", "data"); eq(info.application, false, "no application")
  eq(sim:memstr():byte(1), checksum(sim:memstr():sub(2)), "page checksum")
  eq(sim.protected_touched, false, "register untouched")
end

do -- a real DS2430A holding valid TEDS: the register is part of the checksum
  local app = "\x13\x00\xe2\xa4\xfd\x39\x30\x00"
  local eeprom = "\x64\x64\x90\x0f\xb8\x05\x04\x29\x24\xe6\x10\xa1\xb5\xc5\x05\x7e"
              .. "\x2c\xd3\x41\xf3\x31\xfa\x9e\x36\xd3\xf3\x00\x00\x00\x00\x00\x00"
  local dev, sim = make_device(0x14, 32, {locked = true, app = app})
  for i = 1, #eeprom do sim.mem[i - 1] = eeprom:byte(i) end
  assert(checksum(eeprom:sub(2)) ~= eeprom:byte(1), "the register alone is not enough")
  eq(checksum(app .. eeprom:sub(2)), eeprom:byte(1), "register plus eeprom matches byte 0")
  local got, info = dev:read_teds()
  eq(got, app .. eeprom:sub(2), "real part reads back"); eq(#got, 39, "39 bytes"); eq(info.application, true, "application")
  sim.programmed = 0
  assert(dev:write_teds(got)); eq(sim.programmed, 0, "rewriting valid TEDS programs nothing")
end

do -- DS2433: sixteen pages, 31 payload bytes each
  local dev, sim = make_device(0x23, 512)
  local payload = string.rep("0123456789", 49) .. "ABCDEF" -- 496 bytes
  eq(#payload, 496, "payload size")
  assert(dev:write_teds(payload, {verify = false}))
  local mem = sim:memstr()
  for p = 0, 15 do
    local page = mem:sub(p * 32 + 1, p * 32 + 32)
    eq(page:byte(1), checksum(page:sub(2)), "ds2433 page " .. p .. " checksum")
  end
  local got, info = dev:read_teds()
  eq(got, payload, "ds2433 round trip"); eq(info.pages, 16, "pages"); eq(info.application, false, "no application")
  sim.programmed = 0
  assert(dev:write_teds(payload)); eq(sim.programmed, 0, "unchanged TEDS programs nothing")
  assert(dev:write_teds("short"))
  eq(dev:read_teds(), "short" .. string.rep("\0", 496 - 5), "short payload zero padded")
  local ok0, err0 = dev:write_teds(string.rep("x", 497))
  expect_error(ok0, err0, "payload too long (496 bytes at most)", "too long")
  sim.mem[7 * 32 + 9] = (sim.mem[7 * 32 + 9] + 1) % 256
  local ok1, err1 = dev:read_teds()
  expect_error(ok1, err1, "checksum mismatch in page 7", "corruption detected")
end

do -- families without TEDS support
  local dev = make_device(0x28, 8)
  local ok, err = dev:read_teds()
  expect_error(ok, err, "unsupported device family", "unknown family teds")
  local ok2, err2 = dev:write_teds("x")
  expect_error(ok2, err2, "unsupported device family", "unknown family write teds")
end

-- ---- unknown family ----
do
  local dev = make_device(0x28, 8)
  local ok, err = dev:read_memory(0, 1)
  expect_error(ok, err, "unsupported device family", "unknown family")
end

print("all simulated tests passed")
