// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2023 Marko Petrović
#ifndef MINETEST_H
#define MINETEST_H
#include <luajit-2.1/lua.hpp>
#include <QString>
#include <QStringList>
#include <QTextStream>
#include <forward_list>
#define INT_ERROR std::numeric_limits<lua_Integer>::min()

#define SAVE_STACK	int __cur_top, __old_top = lua_gettop(L)

#define RESTORE_STACK	__cur_top = lua_gettop(L);		\
	                lua_pop(L, __cur_top-__old_top)

#define chatcommand_sig bool (*)(QString&, QString&, QString&)
#define chatmsg_sig bool (*)(QString&, QString&)
#define shutdown_sig void (*)()

void printLuaStack(lua_State* L);
void printLuaTable(lua_State* L, int index);
void printLuaType(lua_State *L, int index, QTextStream &where);
void copyLuaTable(lua_State *L, int srcIndex, int destIndex);
void pushQStringList(lua_State *L, const QStringList &privlist);
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

struct cmd_ret {
	bool success;
	const char *ret_msg;
};

struct cmd_def {
	const QStringList& privs;
	const char *description;
	const char *params;
	int (*func)(lua_State* L);
};

// Typically a global object
class minetest : public lua_state_class {
private:
	void *StorageRef = nullptr;
	static bool first_chatmsg_handler;
	static bool first_chatcomm_handler;
	static void create_command_deftable(lua_State *L, const struct cmd_def &def);
	static int lua_callback_wrapper_msg(lua_State *L);
	static int lua_callback_wrapper_comm(lua_State *L);
	bool is_top_modstorage();
	std::forward_list<shutdown_sig> registered_on_shutdown;
public:
	static std::forward_list<chatmsg_sig> registered_on_chatmsg;
	static std::forward_list<chatcommand_sig> registered_on_chatcommand;
	using lua_state_class::lua_state_class;
	minetest();
	~minetest();
	void log_message(const char *level, const char *msg) const;
	void log_message(const QString &level, const QString &msg) const { return log_message(level.toUtf8().data(), msg.toUtf8().data()); }
	void chat_send_all(const char *msg) const;
	void chat_send_all(const QString &msg) const { return chat_send_all(msg.toUtf8().data()); }
	void chat_send_player(const char *playername, const char *msg) const;
	void chat_send_player(const QString &playername, const QString &msg) const {return chat_send_player(playername.toUtf8().data(), msg.toUtf8().data()); }
	const char *get_current_modname() const;
	const char *get_modpath(const char *modname) const;
	const char *get_modpath(const QString &modname) const { return get_modpath(modname.toUtf8().data()); }
	const char *get_worldpath() const;
	void register_privilege(const char *name, const char *definition) const;
	void register_privilege(const QString &name, const QString &definition) const { return register_privilege(name.toUtf8().data(), definition.toUtf8().data()); }
	void get_mod_storage(); // Leaves StorageRef on the stack top
	void pop_modstorage();   // Pops StorageRef from the stack top

	void register_on_chat_message(chatmsg_sig);
	void register_on_chatcommand(chatcommand_sig);
	void register_on_shutdown(shutdown_sig);
	void dont_call_this_use_macro_reg_chatcommand(const char *comm, const struct cmd_def &def) const;
	void dont_call_this_use_macro_reg_chatcommand(const QString &comm, const struct cmd_def &def) const { dont_call_this_use_macro_reg_chatcommand(comm.toUtf8().data(), def); }
};

#define register_chatcommand(comm, privs, description, params, func)							\
	dont_call_this_use_macro_reg_chatcommand(comm, cmd_def{privs, description, params, [](lua_State *L) -> int {	\
	struct cmd_ret ret = func(lua_tostring(L, 1), lua_tostring(L, 2));						\
	lua_pushboolean(L, ret.success);										\
	lua_pushstring(L, ret.ret_msg);											\
	return 2;													\
	}})

/* Usually one would do something like
 * #define qLog QLog(&m)
 * where m is of type minetest and then use qLog << "Text" for logging.
*/
class QLog : public QTextStream {
private:
	QString assembledString;
	minetest *functions;
public:
	QLog(minetest *functions);
	~QLog();
};

#endif // MINETEST_H
