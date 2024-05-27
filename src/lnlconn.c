/*
* SPDX-License-Identifier: MIT
*
* Copyright (c) 2024 John Mark <john@whamotron.com>
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
* THE SOFTWARE.
*/

#include <lua.h>
#include <lauxlib.h>

#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#include <sys/socket.h>
#include <linux/rtnetlink.h>
#include <linux/connector.h>
#include <linux/netlink.h>


#define MT_NAME "NLCONN_HANDLE"
#define READ_BUFFER_SIZE 4096
#define INVALID_FD (-1)

enum w1_cn_msg_flags {
	W1_CN_BUNDLE = 1,
};



struct nlconn_context {
    int fd;
    uint32_t seq;
};

void push_nlconn_handle(lua_State *L, int fd)
{
    struct nlconn_context* ctx = NULL;

    ctx = (struct nlconn_context*) lua_newuserdata(L, sizeof(struct nlconn_context));
    ctx->fd = fd;
    ctx->seq = 0;
    luaL_getmetatable(L, MT_NAME);
    lua_setmetatable(L, -2);
}

int get_nlconn_handle(lua_State *L, int index)
{
    struct nlconn_context* ctx = NULL;

    ctx = (struct nlconn_context*) luaL_checkudata(L, index, MT_NAME);
    if (ctx) {
        return ctx->fd;
    }
    return -1;
}

static int handle_error(lua_State *L)
{
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    lua_pushinteger(L, errno);
    return 3;
}

static int init(lua_State *L)
{
    int isnum = 0;
	struct sockaddr_nl l_local = {AF_NETLINK, 0, -1, 0};


    if(lua_type(L, 1) == LUA_TTABLE)
    {
        lua_getfield(L, 1, "groups");

        if(lua_type(L, -1) != LUA_TNIL) {
            l_local.nl_groups = lua_tointegerx(L, -1, &isnum);
            if (!isnum) {
                l_local.nl_groups = -1;
            }
        }
        lua_pop(L, 1);

        lua_getfield(L, 1, "pid");

        if(lua_type(L, -1) != LUA_TNIL) {
            l_local.nl_pid = lua_tointegerx(L, -1, &isnum);
            if (!isnum) {
                l_local.nl_groups = 0;
            }
        }
        lua_pop(L, 1);
    }

	int s = socket(AF_NETLINK, SOCK_DGRAM, NETLINK_CONNECTOR);
	if (s == -1) {
		return handle_error(L);
	}

	if (bind(s, (struct sockaddr *)&l_local, sizeof(struct sockaddr_nl)) == -1) {
		close(s);
		return handle_error(L);
	}

    push_nlconn_handle(L, s);
    return 1;
}

static int handle_fileno(lua_State *L)
{
    lua_pushinteger(L, get_nlconn_handle(L, 1));
    return 1;
}

static int handle_read(lua_State *L)
{
    struct nlconn_context* ctx = NULL;
    uint8_t buffer[READ_BUFFER_SIZE];
    int len = 0;

    ctx = (struct nlconn_context*) luaL_checkudata(L, 1, MT_NAME);
    if (ctx && ctx->fd != INVALID_FD) {
        len = recv(ctx->fd, buffer, READ_BUFFER_SIZE, 0);
        if (len < 0) {
            return handle_error(L);
        }
        lua_pushlstring(L, (const char*)buffer, (size_t)len);
        return 1;
    }
    return 0;
}

static int handle_write(lua_State *L)
{
    size_t len = 0;
    const char* buffer;
    struct nlconn_context* ctx = NULL;
    int sent = 0;

    ctx = (struct nlconn_context*) luaL_checkudata(L, 1, MT_NAME);
    if (ctx && ctx->fd != INVALID_FD) {
        buffer = luaL_checklstring(L, 2, &len);
        sent = send(ctx->fd, buffer, len, 0);
        if (sent == -1) {
            return handle_error(L);
        }
        lua_pushinteger(L, sent);
        return 1;
    }
    return 0;
}

static int handle_close(lua_State *L)
{
    struct nlconn_context* ctx = NULL;

    ctx = (struct nlconn_context*) luaL_checkudata(L, 1, MT_NAME);
    if (ctx && ctx->fd != INVALID_FD) {
        close(ctx->fd);
        ctx->fd = INVALID_FD;
    }

    return 0;
}

static int handle__gc(lua_State *L)
{
    return handle_close(L);
}

static luaL_Reg nlconn_funcs[] = {
    {"create", init},
    {NULL, NULL}
};

static luaL_Reg handle_funcs[] = {
    {"read", handle_read},
    {"write", handle_write},
    {"close", handle_close},
    {"fileno", handle_fileno},
    {"getfd", handle_fileno},
    {NULL, NULL}
};

#define register_constant(s)\
    lua_pushinteger(L, s);\
    lua_setfield(L, -2, #s);

int luaopen_lnlconn(lua_State *L)
{
    luaL_newmetatable(L, MT_NAME);
    lua_createtable(L, 0, sizeof(handle_funcs) / sizeof(luaL_Reg) - 1);
#if LUA_VERSION_NUM > 501
    luaL_setfuncs(L, handle_funcs, 0);
#else
    luaL_register(L, NULL, handle_funcs);
#endif
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, handle__gc);
    lua_setfield(L, -2, "__gc");
    lua_pushliteral(L, "nlconn_handle");
    lua_setfield(L, -2, "__type");
    lua_pop(L, 1);

    lua_newtable(L);
#if LUA_VERSION_NUM > 501
    luaL_setfuncs(L, nlconn_funcs,0);
#else
    luaL_register(L, NULL, nlconn_funcs);
#endif

    register_constant(CN_IDX_PROC);
    register_constant(CN_VAL_PROC);
    register_constant(CN_IDX_CIFS);
    register_constant(CN_VAL_CIFS);
    register_constant(CN_W1_IDX);
    register_constant(CN_W1_VAL);
    register_constant(CN_IDX_V86D);
    register_constant(CN_VAL_V86D_UVESAFB);
    register_constant(CN_IDX_BB);
    register_constant(CN_DST_IDX);
    register_constant(CN_DST_VAL);
    register_constant(CN_IDX_DM);
    register_constant(CN_VAL_DM_USERSPACE_LOG);
    register_constant(CN_IDX_DRBD);
    register_constant(CN_VAL_DRBD);
    register_constant(CN_KVP_IDX);
    register_constant(CN_KVP_VAL);
    register_constant(CN_VSS_IDX);
    register_constant(CN_VSS_VAL);
    register_constant(W1_CN_BUNDLE);
    register_constant(NLMSG_NOOP);
    register_constant(NLMSG_ERROR);
    register_constant(NLMSG_DONE);
    register_constant(NLMSG_OVERRUN);
    return 1;
}

