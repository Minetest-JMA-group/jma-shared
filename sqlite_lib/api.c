#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

#ifndef LUA_VERSION_NUM
#error "Unknown Lua version"
#endif

#if LUA_VERSION_NUM < 502
static void luaL_newlib(lua_State *L, const luaL_Reg *reg) {
    lua_newtable(L);
    luaL_register(L, NULL, reg);
}
#endif

static int l_execute(lua_State *L) {
    const char *filename = luaL_checkstring(L, 1);
    const char *query = luaL_checkstring(L, 2);
    sqlite3 *db;
    char *err = NULL;
    int rc = sqlite3_open(filename, &db);
    if (rc != SQLITE_OK) {
        const char *errmsg = db ? sqlite3_errmsg(db) : "cannot open database";
        if (db) sqlite3_close(db);
        lua_pushboolean(L, 0);
        lua_pushstring(L, errmsg);
        return 2;
    }
    rc = sqlite3_exec(db, query, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, err ? err : "execution failed");
        sqlite3_free(err);
        sqlite3_close(db);
        return 2;
    }
    sqlite3_close(db);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_select(lua_State *L) {
    const char *filename = luaL_checkstring(L, 1);
    const char *query = luaL_checkstring(L, 2);
    sqlite3 *db;
    sqlite3_stmt *stmt;
    int rc = sqlite3_open(filename, &db);
    if (rc != SQLITE_OK) {
        const char *errmsg = db ? sqlite3_errmsg(db) : "cannot open database";
        if (db) sqlite3_close(db);
        lua_pushnil(L);
        lua_pushstring(L, errmsg);
        return 2;
    }
    rc = sqlite3_prepare_v2(db, query, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        const char *errmsg = sqlite3_errmsg(db);
        sqlite3_close(db);
        lua_pushnil(L);
        lua_pushstring(L, errmsg);
        return 2;
    }
    lua_newtable(L);
    int row_index = 1;
    int ncols = sqlite3_column_count(stmt);
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        lua_newtable(L);
        for (int i = 0; i < ncols; ++i) {
            const char *colname = sqlite3_column_name(stmt, i);
            int coltype = sqlite3_column_type(stmt, i);
            switch (coltype) {
                case SQLITE_INTEGER:
                    lua_pushinteger(L, sqlite3_column_int64(stmt, i));
                    break;
                case SQLITE_FLOAT:
                    lua_pushnumber(L, sqlite3_column_double(stmt, i));
                    break;
                case SQLITE_TEXT: {
                    const unsigned char *txt = sqlite3_column_text(stmt, i);
                    lua_pushstring(L, (const char *)txt);
                    break;
                }
                case SQLITE_BLOB: {
                    const void *blob = sqlite3_column_blob(stmt, i);
                    int sz = sqlite3_column_bytes(stmt, i);
                    lua_pushlstring(L, (const char *)blob, sz);
                    break;
                }
                case SQLITE_NULL:
                default:
                    lua_pushnil(L);
                    break;
            }
            lua_setfield(L, -2, colname);
        }
        lua_rawseti(L, -2, row_index++);
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    if (rc != SQLITE_DONE) {
        lua_pushnil(L);
        lua_pushstring(L, "error iterating rows");
        return 2;
    }
    return 1;
}

static int l_escape(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    const char *etype = luaL_optstring(L, 2, "value");
    if (strcmp(etype, "identifier") == 0) {
        size_t len = strlen(text);
        size_t maxlen = len * 2 + 3;
        char *out = (char *)malloc(maxlen);
        if (!out) {
            lua_pushnil(L);
            lua_pushstring(L, "memory allocation failed");
            return 2;
        }
        char *p = out;
        *p++ = '"';
        for (size_t i = 0; i < len; ++i) {
            if (text[i] == '"') {
                *p++ = '"';
                *p++ = '"';
            } else {
                *p++ = text[i];
            }
        }
        *p++ = '"';
        *p = '\0';
        lua_pushstring(L, out);
        free(out);
        return 1;
    } else {
        char *escaped = sqlite3_mprintf("%q", text);
        if (!escaped) {
            lua_pushnil(L);
            lua_pushstring(L, "escape failed");
            return 2;
        }
        lua_pushstring(L, escaped);
        sqlite3_free(escaped);
        return 1;
    }
}

static const luaL_Reg sqlite_funcs[] = {
    {"execute", l_execute},
    {"select", l_select},
    {"escape", l_escape},
    {NULL, NULL}
};

int luaopen_sqlite(lua_State *L) {
    luaL_newlib(L, sqlite_funcs);
    return 1;
}

//gcc -O2 -fPIC -I/usr/include/lua5.4 -shared -o api.so api.c -lsqlite3 -llua5.4 -ldl -lm
