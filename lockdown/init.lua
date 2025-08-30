-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2025 Nanowolf4 (n4w@tutanota.com)

lockdown = {}
local modstorage = core.get_mod_storage()

local reglock = modstorage:get_int("reglock") == 1
local lockdown_until = modstorage:get_int("lockdown_until")

function lockdown.is_enabled()
	if lockdown_until > 0 then
		if os.time() >= lockdown_until then
			core.log("action", "[lockdown] Lockdown timeout expired, disabling automatically")
			lockdown.set(false)
			return false
		end
		return true
	end
	return reglock
end

function lockdown.set(state, duration)
	if state then
		modstorage:set_int("reglock", 1)
		reglock = true

		if duration and duration > 0 then
			lockdown_until = os.time() + duration
			modstorage:set_int("lockdown_until", lockdown_until)
		else
			lockdown_until = 0
			modstorage:set_int("lockdown_until", 0)
		end
	else
		modstorage:set_int("reglock", 0)
		reglock = false
		lockdown_until = 0
		modstorage:set_int("lockdown_until", 0)
	end
end

function lockdown.is_whitelisted(name)
	return modstorage:get_int("wl:" .. name) == 1
end

function lockdown.add_whitelist(name)
	modstorage:set_int("wl:" .. name, 1)
	core.log("action", "[lockdown] Player " .. name .. " added to whitelist")
end

function lockdown.remove_whitelist(name)
	modstorage:set_int("wl:" .. name, 0)
	core.log("action", "[lockdown] Player " .. name .. " removed from whitelist")
end

function lockdown.list_whitelist()
	local res = {}
	local fields = modstorage:to_table().fields
	for key, val in pairs(fields) do
		if key:sub(1, 3) == "wl:" and tonumber(val) == 1 then
			table.insert(res, key:sub(4))
		end
	end
	return res
end

core.register_on_prejoinplayer(function(name)
	if lockdown.is_enabled()
	and core.get_auth_handler().get_auth(name) == nil
	and not lockdown.is_whitelisted(name) then
		core.log("action", "[lockdown] Blocked new player registration attempt: " .. name)
		return "Server Lockdown!\nWe aren't accepting new players right now.\n" ..
			"If you want to create a new account, contact us on Discord: www.ctf.jma-sig.de or E-Mail loki@jma-sig.de"
	end
end)

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	if lockdown.is_whitelisted(name) then
		lockdown.remove_whitelist(name)
		core.log("action", "[lockdown] Player " .. name .. " joined, whitelist entry removed")
	end
end)

core.register_chatcommand("lockdown", {
	description = "Toggle/check lockdown mode (disable new registrations)",
	params = "[yes/no/show] [time]",
	privs = {server = true},
	func = function(name, param)
		local parts = param:split(" ")
		local mode = parts[1] or ""

		if mode:find("y") then
			local time = algorithms.parse_time(parts[2])
			if time > 0 then
				lockdown.set(true, time)
				local time_str = algorithms.time_to_string(time)
				core.log("action", "[lockdown] Player " .. name .. " enabled lockdown with timeout: " .. time_str .. " left")
				return true, "Lockdown enabled for " .. time_str
			else
				lockdown.set(true)
				core.log("action", "[lockdown] Player " .. name .. " enabled lockdown (no timeout)")
				return true, "Lockdown enabled (no timeout)"
			end
		elseif mode:find("n") then
			lockdown.set(false)
			core.log("action", "[lockdown] Player " .. name .. " disabled lockdown")
			return true, "Lockdown disabled"
		elseif mode:find("s") or mode == "" then
			if lockdown.is_enabled() then
				if lockdown_until > 0 then
					return true, "Lockdown active (" .. algorithms.time_to_string(math.abs(lockdown_until - os.time())) .. " left)"
				else
					return true, "Lockdown active (no timeout)"
				end
			else
				return true, "Lockdown is disabled"
			end
		else
			return false, "Usage: /lockdown [yes/no/show] [time]"
		end
	end,
})

core.register_chatcommand("lockdownwl", {
	description = "Manage lockdown whitelist",
	params = "<add/remove/list> [player]",
	privs = {server = true},
	func = function(name, param)
		local parts = param:split(" ")
		local action = parts[1]
		local target = parts[2]

		if action == "add" then
			if not target then
				return false, "Usage: /lockdownwl add <player>"
			end
			lockdown.add_whitelist(target)
			core.log("action", "[lockdown] Player " .. name .. " added " .. target .. " to whitelist via command")
			return true, target .. " added to whitelist"

		elseif action == "remove" then
			if not target then
				return false, "Usage: /lockdownwl remove <player>"
			end
			lockdown.remove_whitelist(target)
			core.log("action", "[lockdown] Player " .. name .. " removed " .. target .. " from whitelist via command")
			return true, target .. " removed from whitelist"

		elseif action == "list" then
			local wl = lockdown.list_whitelist()
			core.log("action", "[lockdown] Player " .. name .. " requested whitelist (entries: " .. #wl .. ")")
			if #wl == 0 then
				return true, "Whitelist is empty"
			end
			return true, "Whitelist: " .. table.concat(wl, ", ")

		else
			return false, "Usage: /lockdownwl <add/remove/list> [player]"
		end
	end,
})
