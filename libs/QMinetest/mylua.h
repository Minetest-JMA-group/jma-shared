#ifndef MYLUA_H
#define MYLUA_H
#include <luajit-2.1/lua.hpp>

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

void printLuaStack(lua_State* L);
void printLuaTable(lua_State* L, int index);
void printLuaType(lua_State *L, int index, QTextStream &where);
void copyLuaTable(lua_State *L, int srcIndex, int destIndex);
void pushQStringList(lua_State *L, const QStringList &privlist);

#endif // MYLUA_H
