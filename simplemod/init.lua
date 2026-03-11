-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local modpath = core.get_modpath(core.get_current_modname())

simplemod = {}
local internal = {}

local function load_module(filename)
	local loader = dofile(modpath .. "/" .. filename)
	loader(internal)
end

local function disable_simplemod(reason)
	simplemod.disabled = true
	simplemod.disable_reason = reason
	simplemod.log_message_to_discord = function() end
	simplemod.ban_name = function() return false, reason end
	simplemod.unban_name = function() return false, reason end
	simplemod.is_banned_name = function() return false end
	simplemod.mute_name = function() return false, reason end
	simplemod.unmute_name = function() return false, reason end
	simplemod.is_muted_name = function() return false end
	simplemod.ban_ip = function() return false, reason end
	simplemod.unban_ip = function() return false, reason end
	simplemod.is_banned_ip = function() return false end
	simplemod.mute_ip = function() return false, reason end
	simplemod.unmute_ip = function() return false, reason end
	simplemod.is_muted_ip = function() return false end
	simplemod.is_muted = function() return false end
	simplemod.is_restricted = function() return false end
	simplemod.get_player_log = function() return {} end
end

load_module("migration.lua")

if internal.disabled then
	local reason = tostring(internal.disable_reason or "unknown reason")
	disable_simplemod(reason)
	core.log("error", "[simplemod] disabled: " .. reason)
	return
end

load_module("base.lua")

if internal.disabled then
	local reason = tostring(internal.disable_reason or "unknown reason")
	disable_simplemod(reason)
	core.log("error", "[simplemod] disabled: " .. reason)
	return
end

load_module("gui.lua")
load_module("commands.lua")

core.log("action", "[simplemod] loaded successfully")
