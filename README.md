# Lua Netlink Connector

A small `Netlink` connector socket module for Lua (Linux only), plus pure-Lua
helpers for the `nlmsghdr` and `cn_msg` headers and for talking to the Linux
`w1` (1-Wire) subsystem.

## Build and install

Requires Lua 5.3+ (the Lua helpers use `string.pack`), CMake and a C compiler.

```sh
cmake -S . -B build
cmake --build build
sudo cmake --install build
```

The C module is installed to `lib/lua/<ver>/lnlconn.so` and the Lua modules to
`share/lua/<ver>/` under the install prefix.  The udev and modprobe files are
not installed by CMake; see [System setup](#system-setup-for-w1).

## C module: `lnlconn`

```lua
local lnlconn = require("lnlconn")
```

Creates and manages a `NETLINK_CONNECTOR` socket for exchanging messages with
any kernel driver that supports the netlink connector.  The module handles only
raw bytes; framing is left to the Lua helpers below.

### `lnlconn.create([opts])`

Creates and binds a socket.  `opts` is an optional table:

| Field    | Meaning                                    |
|----------|--------------------------------------------|
| `groups` | Netlink multicast group mask to subscribe to |
| `pid`    | Local netlink port id                      |

Both fields must be integers; anything else raises an argument error.

Returns a handle, or `nil, message, errno` on failure.

### Handle methods

| Method            | Description                                               |
|-------------------|-----------------------------------------------------------|
| `h:write(bytes)`  | Sends a string; returns bytes sent.                       |
| `h:settimeout(s)` | Limits how long each `read` may wait, in seconds (fractions allowed, `0` polls). `nil` or a negative value waits forever, which is the default. |
| `h:read()`        | Blocking receive of one datagram (max 4096 bytes); returns a string. |
| `h:fileno()`      | Returns the file descriptor (alias `h:getfd()`), e.g. for `select`-style loops. |
| `h:close()`       | Closes the socket.  Also done on garbage collection.      |

`read` and `write` return `nil, message, errno` on error.  A `read` that times
out returns `nil, "Connection timed out", 110` (`ETIMEDOUT`).  The timeout
applies to each `read` call, not to a series of them.

### Constants

Connector ids (`CN_IDX_PROC`, `CN_W1_IDX`, `CN_W1_VAL`, `CN_KVP_IDX`, ...,
all the `CN_*` idx/val pairs from `linux/connector.h`), `W1_CN_BUNDLE`, and the
netlink message types `NLMSG_NOOP`, `NLMSG_ERROR`, `NLMSG_DONE`,
`NLMSG_OVERRUN`.

## Generic Lua helpers

Each header module is a small class with `new{...}`, `pack(payload)` and
`unpack(bytes, pos)`.  `pack` fills in the length field and returns the header
followed by the payload; `..` is overloaded to do the same, and a table
payload is packed first, so headers nest naturally.  Missing fields pack as 0.

| Module     | Fields                                  |
|------------|-----------------------------------------|
| `nlmsghdr` | `len`, `type`, `flags`, `seq`, `pid`    |
| `cn_msg`   | `idx`, `val`, `seq`, `ack`, `len`, `flags` |

```lua
local nlmsghdr = require("nlmsghdr")
local cn_msg   = require("cn_msg")

local pkt = nlmsghdr:new{type = lnlconn.NLMSG_DONE}:pack(
  cn_msg:new{idx = lnlconn.CN_W1_IDX, val = lnlconn.CN_W1_VAL}:pack(payload))
```

`unpack` fills the object's fields and returns the position of the next unread
byte.

## w1 helpers

Modules for the Linux `w1` netlink protocol (see
`Documentation/w1/w1-netlink.rst` in the kernel tree).

| Module            | Purpose                                                    |
|-------------------|------------------------------------------------------------|
| `w1_netlink_msg`  | `w1_netlink_msg` header (`type`, `status`, `len`, `union`) and `W1_*` message types (`W1_LIST_MASTERS`, `W1_MASTER_CMD`, `W1_SLAVE_CMD`, ...). |
| `w1_netlink_cmd`  | `w1_netlink_cmd` header (`cmd`, `res`, `len`) and `W1_CMD_*` commands (`W1_CMD_READ`, `W1_CMD_WRITE`, `W1_CMD_SEARCH`, `W1_CMD_RESET`, ...). |
| `w1_con_skt`      | Wraps an `lnlconn` socket: `create{groups=, pid=, timeout=}` (`timeout` as for `settimeout`), `send(payload)` adds the `nlmsghdr` and `cn_msg` headers and a sequence number, `recv()` reads until the last reply to the request and returns a list of `w1_netlink_msg` objects, or `nil, message, errno` (including a timeout). Replies to earlier requests are skipped. |
| `w1`              | High-level API: bridges (bus masters) and devices. |

### High-level usage

```lua
local w1 = require("w1")

local bus = w1:new()
for _, bridge in ipairs(bus:bridges()) do   -- list bus masters
  print(bridge)                             -- w1_bus_master1
  for _, dev in ipairs(bridge:search()) do  -- search the bus
    print(dev)                              -- e.g. 28-0000051234ab
    local pkts = dev:read(9)                -- read 9 bytes from the device
  end
end
```

`device:cmd(bytes)` sends a pre-packed command to a device, and `device:read(n)`
issues a `W1_CMD_READ` of `n` bytes.  Both return the list of reply messages.

### Reading and writing EEPROM memory

Devices found by `bridge:search()` have memory helpers for the DS2431 (family
`0x2d`, 128 bytes), the DS2430A (family `0x14`, 32 bytes) and the DS2433
(family `0x23`, 512 bytes).  They go straight to the device over netlink, so
there is no sysfs path to look up.  Other families return
`nil, "unsupported device family"`.

```lua
local data = dev:read_memory(0, 56)           -- addr, number of bytes
local ok, err = dev:write_memory(0x10, "abc") -- any address and alignment
```

- `dev:read_memory(addr, n [, proof])` returns a string.  The DS2431's read
  command has no CRC, so `proof=true` reads again until two reads agree, at
  twice the cost.
- `dev:write_memory(addr, data [, opts])` returns `true`.  Writing the same
  data does nothing, and the result is read back and verified.  Each family
  programs differently:
  - The DS2431 is programmed one 8-byte row at a time, and only rows that
    change (scratchpad write, read-back, copy, then an 11 ms wait).
  - The DS2430A copies its whole 32-byte scratchpad in one step, so the merged
    contents are loaded and copied once.  Its datasheet asks for a pull-up of
    2.2 k&Omega; at 4 V or more when writing.
  - The DS2433 has 32-byte pages and copies only the bytes loaded, so there is
    no read-modify-write.  A write is split at page boundaries and trimmed to
    the bytes that change, then waits 6 ms per page.  That covers the
    DS24B33A's 6 ms programming time (5 ms for the DS2433 and DS24B33); they
    share family code `0x23`, so the code can't tell them apart.  Programming
    draws about 2 mA from the bus, which must stay above 2.8 V while it runs.
- `opts.verify = false` skips the final read-back (the scratchpad is still
  checked before it is copied), and `opts.compare = false` skips the DS2433's
  pre-read so the data is always programmed.  Both trade safety for speed.
  Without the read-back nothing confirms that the copy completed; the
  DS24B33 datasheet recommends reading the page back after every copy.
- Addresses outside the data memory are refused before anything is sent, so
  the permanent registers can't be reached: the DS2431's protection bytes
  (`0x80` and up) and the DS2430A's one-time application register.  The
  DS2433's write-protect and EPROM-mode registers are not addressable either.
- On failure they return `nil, message [, status]`, where `status` is the
  kernel's errno for the request.

Approximate times on a DS9490R at standard speed: a 128-byte DS2431 read is
about 72 ms (144 ms with `proof`), a 56-byte read about 35 ms, and a write
takes roughly 37 ms per changed row plus the verifying reads.  A 32-byte
DS2430A read is about 22 ms (44 ms with `proof`), about twice as fast as the
kernel's sysfs read.  A DS2430A write takes about 150 ms, of which roughly
60 ms is programming and the rest the double reads before and after.  A
512-byte DS2433 read is about 275 ms (550 ms with `proof`).

`test/w1-memory-sim-test.lua` exercises all of this against simulated devices
and needs no hardware.

### TEDS images

TEDS memories keep a two's complement checksum in byte 0 of every 32-byte page.
For the DS2431, DS2430A and DS2433 the device adds and removes these for you,
so a decoder or encoder only sees the TEDS bytes:

```lua
local teds, info = dev:read_teds()      -- checksums verified and removed
-- ... decode, change, encode ...
assert(dev:write_teds(new_teds))        -- checksums added again
```

- `dev:read_teds([opts])` returns the payload and `{pages=, application=}`.
  A DS2431 gives 124 bytes (4 pages of 31).  A DS2430A whose application
  register is locked gives that register's 8 bytes first, then 31 (39 in
  total), and the register is included in the page's checksum.  An unlocked
  DS2430A gives 31 bytes.  A bad checksum returns `nil, "checksum mismatch in
  page N"` (pages count from 0); `opts.verify = false` returns the bytes
  anyway, and `opts.proof = true` reads twice.  A DS2433 gives 496 bytes
  (16 pages of 31).
- `dev:write_teds(payload [, opts])` pads a short payload with zeros, rejects
  one that is too long, and writes through `write_memory` (`opts` is passed
  on), so unchanged pages are not reprogrammed.  When the application register is locked, the payload must
  start with its 8 bytes, which are never written.
- On a DS2430A with a locked application register, the register is part of
  the page checksum.  This was checked against a DS2430A holding valid TEDS:
  byte 0 matched only when the register was included.

`dev:app_register_locked()` and `dev:read_app_register()` read the DS2430A's
status and one-time programmable register.  Reading returns an error while
the register is unlocked, because the device then answers with its scratchpad.
There is deliberately no function that writes or locks the register.

### Low-level usage

See `test/w1-test.lua` for building `W1_LIST_MASTERS` and `W1_CMD_SEARCH`
requests by hand with the message modules, and `test/hdr-test.lua` /
`test/skt-test.lua` for the header and socket helpers.

## System setup for w1

Two optional files in this repository configure the kernel side.  Neither is
installed by CMake.

**`udev/99-w1.rules`** lets members of a `w1` group use the 1-Wire sysfs
attributes (bus master settings, device `eeprom` files) without root:

```sh
sudo groupadd --system w1
sudo usermod -aG w1 $USER          # log out and back in afterwards
sudo cp udev/99-w1.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=w1
```

The rule runs when a device is added, so unplug and replug an adapter to
apply it to an existing master.  It does not affect the netlink connector.
In testing on Ubuntu (kernel 7.0), searching, reading and writing over the
connector worked without root, but your kernel may differ.

**`modprobe.d/w1.conf`** turns off the kernel's periodic slave search
(`search_count=0`), so devices are found by searching over the netlink
connector instead, and drops a slave after one missed search (`slave_ttl=1`)
if searching is ever re-enabled.  These are `wire` module parameters, read
only when the module loads:

```sh
sudo cp modprobe.d/w1.conf /etc/modprobe.d/
sudo modprobe -r w1_ds2431 ds2490 wire   # or reboot; then re-plug the adapter
```

With the search off, sysfs no longer lists devices on its own, and a device
that has been removed stays listed until it expires.  Use the netlink search
(`bridge:search()`) as the source of truth.  `w1_master_search` can still be
changed per master at runtime (`-1` searches forever, `0` never).

## License

MIT.  See `COPYRIGHT`.
