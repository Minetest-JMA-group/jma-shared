// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2023 Marko Petrović
#ifndef STORAGE_H
#define STORAGE_H
#include <player.h>
#include <luajit-2.1/lua.hpp>
#include <QByteArray>
#include <QString>
#include <type_traits>

#define INT_ERROR std::numeric_limits<lua_Integer>::min()

// Assume that Lua StorageRef object is on the top of the stack
class storage : public lua_state_class {
public:
	using lua_state_class::lua_state_class;
	lua_Integer get_int(const char *key) const;
	lua_Integer get_int(const QString &key) const
	{
		return get_int(key.toUtf8().constData());
	}
	QByteArray get_string(const char *key) const;
	QByteArray get_string(const QString &key) const
	{
		return get_string(key.toUtf8().constData());
	}
	bool set_int(const char *key, const lua_Integer a);
	bool set_int(const QString &key, const lua_Integer a)
	{
		return set_int(key.toUtf8().constData(), a);
	}
	bool set_string(const char *key, const char *str);
	bool set_string(const QString &key, const QByteArray &str)
	{
		return set_string(key.toUtf8().constData(), str.constData());
	}
	bool contains(const char *key) const;
	bool contains(const QString &key) const
	{
		return contains(key.toUtf8().constData());
	}
};

#endif // STORAGE_H
