// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2023 Marko Petrović
#include <storage.h>
#include <QTextStream>
#include <QByteArray>
#define qLog QTextStream(stderr)

lua_Integer storage::get_int(const char *key) const
{
	SAVE_STACK;
	lua_Integer res = INT_ERROR;

	if (!lua_isuserdata(L, -1)) {
		qLog << "Called get_int on an invalid storage object.\n";
		printLuaStack(L);
		goto out;
	}
	lua_getfield(L, -1, "get_int"); // Assuming the StorageRef object is at the top of the stack
	if (!lua_isfunction(L, -1))
		goto out;

	lua_pushvalue(L, __old_top);
	lua_pushstring(L, key);
	if (lua_pcall(L, 2, 1, 0)) {
		qLog << "Error calling storage function\n" << lua_tostring(L, -1) << "\n";
		goto out;
	}
	if (!lua_isinteger(L, -1))
		goto out;

	res = lua_tointeger(L, -1);
out:
	RESTORE_STACK;
	return res;
}


QByteArray storage::get_string(const char *key) const
{
	SAVE_STACK;
	QByteArray res;

	if (!lua_isuserdata(L, -1)) {
		qLog << "Called get_string on an invalid storage object.\n";
		printLuaStack(L);
		goto out;
	}

	lua_getfield(L, -1, "get_string"); // Assuming the StorageRef object is at the top of the stack
	if (!lua_isfunction(L, -1))
		goto out;

	lua_pushvalue(L, __old_top);
	lua_pushstring(L, key);
	if (lua_pcall(L, 2, 1, 0)) {
		qLog << "Error calling storage function\n" << lua_tostring(L, -1) << "\n";
		goto out;
	}

	if (!lua_isstring(L, -1))
		goto out;

	res = lua_tostring(L, -1);
out:
	RESTORE_STACK;
	return "";
}

bool storage::set_int(const char *key, const lua_Integer a)
{
	SAVE_STACK;

	if (!lua_isuserdata(L, -1)) {
		qLog << "Called set_int on an invalid storage object.\n";
		printLuaStack(L);
		goto err;
	}

	lua_getfield(L, -1, "set_int"); // Assuming the StorageRef object is at the top of the stack

	if (!lua_isfunction(L, -1))
		goto err;

	lua_pushvalue(L, __old_top);
	lua_pushstring(L, key);
	lua_pushinteger(L, a);

	if (lua_pcall(L, 3, 0, 0)) {
		qLog << "Error calling storage function\n" << lua_tostring(L, -1) << "\n";
		goto err;
	}

	RESTORE_STACK;
	return true;
err:
	RESTORE_STACK;
	return false;
}

bool storage::set_string(const char *key, const char *str)
{
	SAVE_STACK;

	if (!lua_isuserdata(L, -1)) {
		qLog << "Called set_string on an invalid storage object.\n";
		printLuaStack(L);
		goto err;
	}

	lua_getfield(L, -1, "set_string"); // Assuming 'storage' is at the top of the stack

	if (!lua_isfunction(L, -1))
		goto err;

	lua_pushvalue(L, __old_top);
	lua_pushstring(L, key);
	lua_pushstring(L, str);

	if (lua_pcall(L, 3, 0, 0)) {
		qLog << "Error calling storage function\n" << lua_tostring(L, -1) << "\n";
		goto err;
	}

	RESTORE_STACK;
	return true;
err:
	RESTORE_STACK;
	return false;
}

bool storage::contains(const char *key) const
{
	SAVE_STACK;
	bool res = false;

	if (!lua_isuserdata(L, -1)) {
		qLog << "Called contains on an invalid storage object.\n";
		printLuaStack(L);
		goto out;
	}

	lua_getfield(L, -1, "contains"); // Assuming the StorageRef object is at the top of the stack
	if (!lua_isfunction(L, -1))
		goto out;

	lua_pushvalue(L, __old_top);
	lua_pushstring(L, key);
	if (lua_pcall(L, 2, 1, 0)) {
		qLog << "Error calling storage function\n" << lua_tostring(L, -1) << "\n";
		goto out;
	}

	if (!lua_isboolean(L, -1))
		goto out;

	res = lua_toboolean(L, -1);
out:
	RESTORE_STACK;
	return res;
}
