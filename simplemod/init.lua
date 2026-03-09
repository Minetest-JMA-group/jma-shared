-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local modpath = core.get_modpath(core.get_current_modname())

simplemod = {}
local internal = {}

local function load_module(filename)
	local loader = dofile(modpath .. "/" .. filename)
	loader(internal)
end

load_module("migration.lua")

if internal.disabled then
	core.log("error", "[simplemod] disabled: " .. tostring(internal.disable_reason or "unknown reason"))
	return
end

load_module("base.lua")

if internal.disabled then
	core.log("error", "[simplemod] disabled: " .. tostring(internal.disable_reason or "unknown reason"))
	return
end

load_module("gui.lua")
load_module("commands.lua")

core.log("action", "[simplemod] loaded successfully")
