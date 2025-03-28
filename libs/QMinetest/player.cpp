// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2023 Marko Petrović
#include <player.h>
#define qLog QTextStream(stderr)

bool player::get_meta() const
{
	SAVE_STACK;

	if (!lua_isuserdata(L, -1))
		goto err;
	lua_getfield(L, -1, "get_meta"); // Assuming the Player object is at the top of the stack
	if (!lua_isfunction(L, -1))
		goto err;

	lua_pushvalue(L, __old_top);
	if (lua_pcall(L, 1, 1, 0)) {
		qLog << "Error calling player function\n" << lua_tostring(L, -1) << "\n";
		goto err;
	}
	if (!lua_isuserdata(L, -1))
		goto err;
	return true;
err:
	RESTORE_STACK;
	return false;
}

const char *player::get_player_name() const
{
	SAVE_STACK;

	if (!lua_isuserdata(L, -1))
		goto err;
	lua_getfield(L, -1, "get_player_name"); // Assuming the Player object is at the top of the stack
	if (!lua_isfunction(L, -1))
		goto err;

	lua_pushvalue(L, __old_top);
	if (lua_pcall(L, 1, 1, 0)) {
		qLog << "Error calling player function\n" << lua_tostring(L, -1) << "\n";
		goto err;
	}
	if (!lua_isstring(L, -1))
		goto err;

	return lua_tostring(L, -1);
err:
	RESTORE_STACK;
	return "";
}
