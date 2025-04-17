// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2023 Marko Petrović
#ifndef MINETEST_H
#define MINETEST_H
#include <QString>
#include <mylua.h>
#include <player.h>
#include <ctime>
#include <QTextStream>
#include <QStringList>
#include <QByteArray>
#include <type_traits>
#include <forward_list>

#define chatcommand_sig bool (*)(QString&, QString&, QString&)
#define chatmsg_sig bool (*)(QString&, QString&)
#define joinplayer_sig void (*)(player&, time_t)
#define prejoinplayer_sig const char* (*)(QString&, QString&)
#define shutdown_sig void (*)()
#define after_sig void (*)()
#define leaveplayer_sig void (*)(player&, bool)

class QMyByteArray : public QByteArray {
public:
	QMyByteArray(const QByteArray &other) : QByteArray(other) {}
	QMyByteArray(QByteArray &&other) : QByteArray(std::move(other)) {}
	QMyByteArray(const QString &other) : QMyByteArray(other.toUtf8()) {}

	QMyByteArray& operator=(QByteArray &&other) {
		QByteArray::operator=(std::move(other));
		return *this;
	}

	QMyByteArray& operator=(const QByteArray &other) {
		QByteArray::operator=(other);
		return *this;
	}

	template <size_t N>
	QMyByteArray(const char (&str)[N]) : QByteArray(QByteArray::fromRawData(str, N - 1)) {}

	template <typename T>
	requires std::is_convertible_v<T, QString>
	QMyByteArray(const T &other) : QMyByteArray(QString(other)) {}

	template <size_t N>
	QMyByteArray& operator=(const char (&str)[N]) {
		QByteArray::operator=(QByteArray::fromRawData(str, N - 1));
		return *this;
	}
};

struct cmd_ret {
	bool success;
	QMyByteArray ret_msg;
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
	static void create_command_deftable(lua_State *L, const struct cmd_def &def);
	static int lua_callback_wrapper_msg(lua_State *L);
	static int lua_callback_wrapper_comm(lua_State *L);
	static int lua_callback_wrapper_joinplayer(lua_State *L);
	static int lua_callback_wrapper_prejoinplayer(lua_State *L);
	static int lua_callback_wrapper_leaveplayer(lua_State *L);
	bool is_top_modstorage();
	std::forward_list<shutdown_sig> registered_on_shutdown;
public:
	static std::forward_list<chatmsg_sig> registered_on_chatmsg;
	static std::forward_list<chatcommand_sig> registered_on_chatcommand;
	static std::forward_list<joinplayer_sig> registered_on_joinplayer;
	static std::forward_list<prejoinplayer_sig> registered_on_prejoinplayer;
	static std::forward_list<leaveplayer_sig> registered_on_leaveplayer;
	using lua_state_class::lua_state_class;
	minetest();
	~minetest();
	void log_message(const char *level, const char *msg) const;
	void log_message(const QString &level, const QString &msg) const { return log_message(level.toUtf8().constData(), msg.toUtf8().constData()); }
	void log_message(const char *level, const QString &msg) const { return log_message(level, msg.toUtf8().constData()); }
	void chat_send_all(const char *msg) const;
	void chat_send_all(const QString &msg) const { return chat_send_all(msg.toUtf8().constData()); }
	void chat_send_player(const char *playername, const char *msg) const;
	void chat_send_player(const QString &playername, const QString &msg) const {return chat_send_player(playername.toUtf8().constData(), msg.toUtf8().constData()); }
	QByteArray get_current_modname() const;
	QString get_modpath(const char *modname) const;
	QString get_modpath(const QString &modname) const { return get_modpath(modname.toUtf8().constData()); }
	QString get_modpath(const QByteArray &modname) const { return get_modpath(modname.constData()); }
	QString get_worldpath() const;
	void register_privilege(const char *name, const char *definition) const;
	void register_privilege(const QString &name, const QString &definition) const { return register_privilege(name.toUtf8().constData(), definition.toUtf8().constData()); }
	void get_mod_storage();		// Leaves StorageRef on the stack top
	void pop_modstorage();		// Pops StorageRef from the stack top
	bool player_exists(const char *playername) const;
	bool player_exists(const QString &playername) const { return player_exists(playername.toUtf8().constData()); }
	bool player_exists(const QByteArray &playername) const { return player_exists(playername.constData()); }
	bool get_player_by_name(const char *playername);	// Leaves player ObjectRef on the stack top. Should be popped manually, e.g. with lua_pop(L, 1)
	bool get_player_by_name(const QString &playername) { return get_player_by_name(playername.toUtf8().constData()); }
	bool get_player_by_name(const QByteArray &playername) { return get_player_by_name(playername.constData()); }

	void register_on_chat_message(chatmsg_sig);
	void register_on_chatcommand(chatcommand_sig);
	void register_on_shutdown(shutdown_sig);
	void register_on_joinplayer(joinplayer_sig);
	void register_on_prejoinplayer(prejoinplayer_sig);
	void register_on_leaveplayer(leaveplayer_sig);
	void after(after_sig);	// Both x86-64 and aarch64 use calling conventions that pass arguments in registers. lua_State pointer fits in register, so we can ignore it.

	void dont_call_this_use_macro_reg_chatcommand(const char *comm, const struct cmd_def &def) const;
	void dont_call_this_use_macro_reg_chatcommand(const QString &comm, const struct cmd_def &def) const { dont_call_this_use_macro_reg_chatcommand(comm.toUtf8().constData(), def); }
};

#define register_chatcommand(comm, privs, description, params, func)							\
	dont_call_this_use_macro_reg_chatcommand(comm, cmd_def{privs, description, params, [](lua_State *L) -> int {	\
	struct cmd_ret ret = func(lua_tostring(L, 1), lua_tostring(L, 2));						\
	lua_pushboolean(L, ret.success);										\
	lua_pushstring(L, ret.ret_msg.constData());									\
	return 2;													\
	}})

/* Usually one would do something like
 * #define qLog QLog(&m)
 * or
 * const char *caller = nullptr;
 * #define qLog QLog(&m, caller)
 * where m is of type minetest, caller is set appropriately, and QLog used like qLog << "Text" for logging.
*/
class QLog : public QTextStream {
private:
	QString assembledString;
	minetest *functions;
	const char *caller = nullptr;
public:
	QLog(minetest *functions);
	QLog(minetest *functions, const char *caller);
	~QLog();
};

#endif // MINETEST_H
