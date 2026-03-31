-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2025 Nanowolf4 (n4w@tutanota.com)

lockdown = {}
local modstorage = core.get_mod_storage()

local reglock = modstorage:get_int("reglock") == 1
local lockdown_until = modstorage:get_int("lockdown_until")

local reg_cooldown = modstorage:contains("reg_cooldown") and modstorage:get_int("reg_cooldown") or 60
local last_reg_timestamp = 0
local whitelist_min_playtime = tonumber(core.settings:get("lockdown_whitelist_min_playtime")) or 10

local contact_info = "Discord: www.ctf.jma-sig.de or E-Mail loki@jma-sig.de"
local disconnect_message = "Server Lockdown!\nWe aren't accepting new players right now.\n\n" ..
	"If you want to create a new account, contact us on " .. contact_info
local disconnect_message_cooldown = "We aren't accepting new players right now.\n" ..
	"Please wait %s before trying to create a new account.\n\n" ..
	"If you want to create a new account right now, contact us on " .. contact_info

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

function lockdown.get_reg_cooldown()
	return reg_cooldown
end

function lockdown.set_reg_cooldown(seconds)
	reg_cooldown = tonumber(seconds) or 0
	if reg_cooldown < 0 then
		reg_cooldown = 0
	end
	modstorage:set_int("reg_cooldown", reg_cooldown)
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
    local auth = core.get_auth_handler().get_auth(name)
    local is_whitelisted = lockdown.is_whitelisted(name)

    if lockdown.is_enabled() and not is_whitelisted then
		if auth then
			-- Block existing accounts with too little playtime (except whitelisted).
			local ptime = playtime.get_total_playtime(name) or 0
            if ptime < whitelist_min_playtime then
                core.log("action",
                    "[lockdown] Blocked join attempt for low-playtime account: " ..
                    name .. " (" .. ptime .. "s < " .. whitelist_min_playtime .. "s)")
                return disconnect_message
            end
        else
			core.log("action", "[lockdown] Blocked new account registration attempt: " .. name)
			return disconnect_message
		end
	end

	if not auth and not is_whitelisted then
		local now = os.time()
		local cd = reg_cooldown
		if cd > 0 and now < last_reg_timestamp + cd then
			local wait = algorithms.time_to_string(last_reg_timestamp + cd - now)
			core.log("action",
			"[lockdown] Blocked new account registration due to cooldown: " .. name .. " (wait " .. wait .. ")")
			return disconnect_message_cooldown:format(wait)
		end
	end
end)

core.register_on_newplayer(function(player)
	last_reg_timestamp = os.time()
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	if not lockdown.is_whitelisted(name) then
		return
	end

	local ptime = playtime.get_total_playtime(name) or 0
	if ptime >= whitelist_min_playtime then
		lockdown.remove_whitelist(name)
		core.log("action", "[lockdown] Player " .. name .. " left with " .. ptime .. "s playtime (>= " .. whitelist_min_playtime .. "s), whitelist entry removed")
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

core.register_chatcommand("regcooldown", {
	description = "Configure registration cooldown",
	params = "<set/get> [time]",
	privs = {server = true},
	func = function(name, param)
		local parts = param:split(" ")
		local action = parts[1]

        if action == "set" then
            local value = parts[2]
            if not value or value == "" then
                return false, "Usage: /regcooldown set <time> (0 to disable)"
            end

			local time = algorithms.parse_time(value)
			if not time or time < 0 then
				return false, "Usage: /regcooldown set <time> (0 to disable)"
			end
			lockdown.set_reg_cooldown(time)
			if time > 0 then
				core.log("action", "[lockdown] Player " .. name .. " set reg_cooldown to " .. time .. "s")
				return true, "Registration cooldown set to " .. time .. " seconds"
			else
				core.log("action", "[lockdown] Player " .. name .. " disabled reg_cooldown")
				return true, "Registration cooldown disabled"
			end
		elseif action == "get" then
			local cd = reg_cooldown
			if cd > 0 then
				return true, "Registration cooldown is " .. algorithms.time_to_string(cd) .. " seconds"
			else
				return true, "Registration cooldown is disabled"
			end
		else
			return false, "Usage: /regcooldown <set/get> [time]"
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
