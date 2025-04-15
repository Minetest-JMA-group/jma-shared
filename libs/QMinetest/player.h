// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2023 Marko Petrović
#ifndef PLAYER_H
#define PLAYER_H
#include <luajit-2.1/lua.hpp>
#include <QByteArray>

#define SAVE_STACK	int __cur_top, __old_top = lua_gettop(L)

#define RESTORE_STACK	__cur_top = lua_gettop(L);		\
	                lua_pop(L, __cur_top-__old_top)

inline bool lua_isinteger(lua_State *L, int index)
{
	return lua_type(L, index) == LUA_TNUMBER;
}

class lua_state_class {
public:
	lua_State *L = nullptr;
	lua_state_class(lua_State *L);
	lua_state_class();
	void set_state(lua_State *L);
};

// Assume that Player object is on the top of the stack
class player : public lua_state_class {
public:
	using lua_state_class::lua_state_class;
	bool get_meta() const; // Leaves PlayerMetaRef on the stack top, can be used with storage class
	QByteArray get_player_name() const;
};

#endif // PLAYER_H
