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
`share/lua/<ver>/` under the install prefix.  Opening a `NETLINK_CONNECTOR`
socket and talking to `w1` generally requires root.

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
| `h:read()`        | Blocking receive of one datagram (max 4096 bytes); returns a string. |
| `h:fileno()`      | Returns the file descriptor (alias `h:getfd()`), e.g. for `select`-style loops. |
| `h:close()`       | Closes the socket.  Also done on garbage collection.      |

`read` and `write` return `nil, message, errno` on error.

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
| `w1_con_skt`      | Wraps an `lnlconn` socket: `create{groups=, pid=}`, `send(payload)` adds the `nlmsghdr` and `cn_msg` headers and a sequence number, `recv()` reads until the ack and returns a list of `w1_netlink_msg` objects. |
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

### Low-level usage

See `test/w1-test.lua` for building `W1_LIST_MASTERS` and `W1_CMD_SEARCH`
requests by hand with the message modules, and `test/hdr-test.lua` /
`test/skt-test.lua` for the header and socket helpers.

## License

MIT.  See `COPYRIGHT`.
