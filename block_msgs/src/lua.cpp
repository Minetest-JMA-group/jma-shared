// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Marko Petrović
#include <luajit-2.1/lua.hpp>
#include <minetest.h>
#include <player.h>
#include <QDir>
#include <QStringBuilder>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <QHash>
#include <QSet>
#include <sys/xattr.h>
#define qLog QLog(&m)

static minetest m;
static QString dirpath, modname;
static QHash<QByteArray, QHash<QByteArray, int>> db;
#define UNFETCHED 0
#define BLOCKED 1
#define UNBLOCKED 2

static struct cmd_ret block(QByteArray name, QByteArray param)
{
	if (!m.player_exists(param))
		return {false, "Player " + param + " doesn't exist"};
	if (db[name][param] == BLOCKED)
		return {false, "Player " + param + " was already blocked"};

	QString player_file = dirpath % "/" % name;
	QByteArray attr_name = "user."+param;
	int ret = setxattr(player_file.toUtf8().constData(), attr_name.constData(), NULL, 0, 0);
	if (ret < 0) {
		int saved_errno = errno;
		qLog << modname << ": Failed to save xattr " << attr_name << " to file " << player_file << " Error: " << strerror(saved_errno);
		return {false, QStringLiteral("Failed to save the change. Error: ") + strerror(saved_errno)};
	}
	db[name][param] = BLOCKED;
	return {true, "Player " + param + " blocked. You won't see their messages anymore."};
}

static struct cmd_ret unblock(QByteArray name, QByteArray param)
{
	if (!m.player_exists(param))
		return {false, "Player " + param + " doesn't exist"};
	if (db[name][param] == UNBLOCKED)
		return {false, "Player " + param + " was already unblocked"};

	QString player_file = dirpath % "/" % name;
	QByteArray attr_name = "user."+param;
	int ret = removexattr(player_file.toUtf8().constData(), attr_name.constData());
	if (ret < 0) {
		int saved_errno = errno;
		qLog << modname << ": Failed to remove xattr " << attr_name << " from file " << player_file << " Error: " << strerror(saved_errno);
		return {false, QStringLiteral("Failed to save the change. Error: ") + strerror(saved_errno)};
	}
	db[name][param] = UNBLOCKED;
	return {true, "Player " + param + " unblocked. You can chat with them again."};
}

/* Args: sender_name: string, receiver_name: string
 * Return: is_chat_blocked: bool
 */
static int is_chat_blocked(lua_State *L)
{
	if (lua_gettop(L) < 2 || !lua_isstring(L, 1) || !lua_isstring(L, 2)) {
		m.log_message("error", modname + ": send_message called with wrong arguments!");
		return 0;
	}
	const char *sname = lua_tostring(L, 1);
	QByteArray sender_name = QByteArray::fromRawData(sname, strlen(sname));
	const char *rname = lua_tostring(L, 2);
	QByteArray receiver_name = QByteArray::fromRawData(rname, strlen(rname));

	if (db[receiver_name][sender_name] == UNFETCHED) {
		QString player_file = dirpath % "/" % receiver_name;
		QByteArray attr_name = "user."+sender_name;
		int ret = getxattr(player_file.toUtf8().constData(), attr_name.constData(), NULL, 0);
		if (ret == 0)
			db[receiver_name][sender_name] = BLOCKED;
		else if (ret < 0 && errno == ENODATA)
			db[receiver_name][sender_name] = UNBLOCKED;
		else {
			int saved_errno = errno;
			qLog << modname << ": Failed to retrieve xattr " << attr_name << " from " << player_file << " Error: " << strerror(saved_errno);
			db[receiver_name][sender_name] = UNBLOCKED;
		}
	}
	lua_pushboolean(L, db[receiver_name][sender_name] == BLOCKED);
	return 1;
}

static void register_functions(lua_State *L)
{
	lua_getglobal(L, modname.toUtf8().constData());
	if (!lua_istable(L, -1)) {
		lua_pushstring(L, (modname + " not a table?").toUtf8().constData());
		lua_error(L);
	}

	lua_pushcfunction(L, is_chat_blocked);
	lua_setfield(L, -2, "is_chat_blocked");

	lua_setglobal(L, modname.toUtf8().constData());
}

extern "C" int luaopen_mylibrary(lua_State *L)
{
	m.set_state(L);
	QString worldpath = m.get_worldpath();
	modname = m.get_current_modname();
	QDir worlddir(worldpath);
	if (!worlddir.exists(modname))
		if (!worlddir.mkdir(modname)) {
			qLog << modname << ": failed to create directory for storing data. Mod will be disabled.";
			lua_pushboolean(L, false);
			return 1;
		}
	dirpath = worldpath % "/" % modname;
	static int dirfd = open(dirpath.toUtf8().constData(), O_PATH);
	if (dirfd < 0) {
		qLog << modname << ": failed to open directory for storing data. Mod will be disabled. Error: " << strerror(errno);
		lua_pushboolean(L, false);
		return 1;
	}
	m.register_on_joinplayer([](player &p, time_t last_login){
		Q_UNUSED(last_login);
		int fd = openat(dirfd, p.get_player_name().constData(), O_CREAT | O_RDWR, 0600);
		if (fd < 0) {
			int saved_errno = errno;
			qLog << modname << ": failed to create file for storing data for player " << p.get_player_name() << " Error: " << strerror(saved_errno);
		}
		close(fd);
	});
	m.register_on_leaveplayer([](player &p, bool timed_out){
		Q_UNUSED(timed_out);
		db.remove(p.get_player_name());
	});
	m.register_chatcommand("block", QStringList(), "Block the player so that they can't message you", "<playername>", block);
	m.register_chatcommand("unblock", QStringList(), "Unblock a previously blocked player", "<playername>", unblock);
	register_functions(L);

	return 0;
}
