# Lua Netlink Connector
This is a simple `Netlink` socket module for Lua with support for
the `nlmsghdr` and `cn_msg` headers.  There is also some
support for accessing the `w1` subsystem in Linux.

## Modules

This project includes a C module and several lua modules.

### C

The `lnlconn` module is used to create and manage a simple
`netlink connector` socket for sending messages to and
receiving messages from any kernel driver that supports
a `netlink connector`.

### Lua

