-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
local sqlite = algorithms.require("lsqlite3")
if not sqlite then
	core.log("[ipdb]: lsqlite3 needed for operation. Make sure that the library is installed and ipdb is added to secure.c_mods or secure.trusted_mods")
	return
end

local modpath = core.get_modpath(core.get_current_modname())
local dbmanager = dofile(modpath .. "/dbmanager.lua")
local db = dbmanager.init_ipdb(sqlite)
local no_newentries
ipdb = {}
if not db then
	core.log("error", "[ipdb]: Database initialization failed, mod cannot function")
	ipdb.register_new_ids = function(name, ip)
		core.log("error", "[ipdb]: ipdb.register_new_ids called while ipdb is disabled")
	end
	return
end

local function log(err)
	core.log("error", "[ipdb]: Database operation failed with code: "..tostring(err))
end

local function register_new_ids(name, ip)
	local err = db:exec("BEGIN")
	if err ~= sqlite.OK then log(err); return end

	-- Almost every statement needs error checking. Just use pcall to catch exceptions instead of bloating the code
	local ok, err_or_ret = pcall(function()
		if no_newentries == nil then
			no_newentries = dbmanager.no_newentries()
		end
		local user
		local ipent
		if name then user = dbmanager.user_exists(name) end
		if ip then ipent = dbmanager.ip_exists(ip) end
		if not user and not ipent then
			if no_newentries then
				return "[Access restriction]: New account from an unrecognized network detected. Please contact us on Discord: www.ctf.jma-sig.de or E-Mail loki@jma-sig.de to get whitelisted."
			end
			local entryid = dbmanager.new_entry()
			if name then dbmanager.add_name(entryid, name) end
			if ip then dbmanager.add_ip(entryid, ip) end
		end
		if user and not ipent then
			if ip then dbmanager.add_ip(user.userentry_id, ip) end
			dbmanager.update_last_seen(user.userentry_id, user.id)
		end
		if ipent and not user then
			if name then dbmanager.add_name(ipent.userentry_id, name) end
			dbmanager.update_last_seen(ipent.userentry_id, nil, ipent.id)
		end
		if ipent and user then
			if ipent.userentry_id ~= user.userentry_id then
				-- This is where we need to merge
				if not dbmanager.can_merge(ipent.userentry_id, user.userentry_id) then return end
				local ids = dbmanager.get_all_identifiers(ipent.userentry_id)
				-- We removed the entry that came from the IP address, now we need to insert its ids into
				-- the entry that came from the username
				dbmanager.delete_entry(ipent.userentry_id)
				local newipent_id
				for old_ip in ids.ips do
					local newid = dbmanager.add_ip(user.userentry_id, old_ip)
					if old_ip == ip then
						newipent_id = newid
					end
				end
				for old_name in ids.names do
					dbmanager.add_name(user.userentry_id, old_name)
				end
				dbmanager.update_last_seen(user.userentry_id, user.id, newipent_id)
			else
				dbmanager.update_last_seen(user.userentry_id, user.id, ipent.id)
			end
		end
	end)
	if not ok then
		log(err_or_ret)
		db:exec("ROLLBACK")
	else
		err = db:exec("COMMIT")
		if err ~= sqlite.OK then log(err) end
		if err_or_ret then return err_or_ret end
	end
end

core.register_on_prejoinplayer(register_new_ids)

ipdb.register_new_ids = function(name, ip)
	-- We don't want to trigger enforcement here
	local old_no_newentries = no_newentries
	no_newentries = false
	register_new_ids(name, ip)
	no_newentries = old_no_newentries
end

local function is_ipv4(str)
	local pattern = "^%d+%.%d+%.%d+%.%d+$"
	return str:match(pattern) ~= nil
end

local help_string = [[
  • ipdb console:
help: Print this text
add_name <username>: Record the given username in the database
add_ip <IP Address>: Record the given IP address in the database
rm_name <username>: Remove the given username from the database
rm_ip <IP Address>: Remove the given IP address from the database
isolate name|ip <identifier>: Create an isolated entry (no_merging flag set) and move or add the specified name/IP to it
newentries [yes|no]: If the argument is given, change whether new user entries are allowed or not. Otherwise print current value.
]]
core.register_chatcommand("ipdb", {
	description = "Interface to the IP-based player entry database",
	params = "<subcommand> args",
	privs = { ban = true },
	func = function(name, params)
		local iter = params:gmatch("%S+")
		local cmd = iter()
		if cmd == "help" then
			return true, help_string
		end

		if cmd == "add_name" then
			local newname = iter()
			if not newname then
				return false, "Usage: /ipdb add_name <username>"
			end
			ipdb.register_new_ids(newname)
			return true, "Name recorded"
		end

		if cmd == "add_ip" then
			local newip = iter()
			if not newip or not is_ipv4(newip) then
				return false, "Usage: /ipdb add_name <IP Address>"
			end
			ipdb.register_new_ids(nil, newip)
			return true, "IP recorded"
		end

		if cmd == "newentries" then
			local arg = iter()
			if arg then
				if arg ~= "yes" and arg ~= "no" then
					return false, "Usage: /ipdb newentries [yes|no]"
				end
				no_newentries = (arg == "no")
				local ok, err = pcall(dbmanager.no_newentries, no_newentries)
				if not ok then
					log(err)
					return false, "Internal error"
				end
				if no_newentries then
					return true, "Auto-generation of new user entries is not allowed now."
				else
					return true, "Auto-generation of new user entries is allowed now."
				end
			end
		end

		if cmd == "rm_name" then
			local delname = iter()
			if not delname then
				return false, "Usage: /ipdb rm_name <username>"
			end
			local err = db:exec("BEGIN")
			if err ~= sqlite.OK then log(err); return false, "Internal error" end
			local ok, res = pcall(function()
				local user = dbmanager.user_exists(delname)
				if not user then return "No such username" end
				dbmanager.remove_name(user.id)
			end)
			if not ok then
				log(res)
				db:exec("ROLLBACK")
				return false, "Internal error"
			else
				err = db:exec("COMMIT")
				if err ~= sqlite.OK then log(err); return false, "Internal error" end
				if res then return res end
				return true, "Name removed"
			end
		end

		if cmd == "rm_ip" then
			local delip = iter()
			if not delip or not is_ipv4(delip) then
				return false, "Usage: /ipdb rm_ip <IP Address>"
			end
			local err = db:exec("BEGIN")
			if err ~= sqlite.OK then log(err); return false, "Internal error" end
			local ok, res = pcall(function()
				local ipent = dbmanager.ip_exists(delip)
				if not ipent then return "No such IP" end
				dbmanager.remove_ip(ipent.id)
			end)
			if not ok then
				log(res)
				db:exec("ROLLBACK")
				return false, "Internal error"
			else
				err = db:exec("COMMIT")
				if err ~= sqlite.OK then log(err); return false, "Internal error" end
				if res then return res end
				return true, "IP removed"
			end
		end

		if cmd == "isolate" then
			local subtype = iter()
			local identifier = iter()
			if not subtype or not identifier then
				return false, "Usage: /ipdb isolate name|ip <identifier>"
			end
			if subtype ~= "name" and subtype ~= "ip" then
				return false, "Type must be 'name' or 'ip'"
			end
			if subtype == "ip" and not is_ipv4(identifier) then
				return false, "Invalid IP address format"
			end

			local err = db:exec("BEGIN")
			if err ~= sqlite.OK then log(err); return false, "Internal error" end

			local ok, res = pcall(function()
				local entryid = dbmanager.new_entry()
				dbmanager.set_merge_allowance(entryid, false)

				if subtype == "name" then
					local user = dbmanager.user_exists(identifier)
					if user then
						dbmanager.reassociate(entryid, user.id)
					else
						dbmanager.add_name(entryid, identifier)
					end
				else
					local ipent = dbmanager.ip_exists(identifier)
					if ipent then
						dbmanager.reassociate(entryid, nil, ipent.id)
					else
						dbmanager.add_ip(entryid, identifier)
					end
				end
			end)

			if not ok then
				log(res)
				db:exec("ROLLBACK")
				return false, "Internal error"
			else
				err = db:exec("COMMIT")
				if err ~= sqlite.OK then log(err); return false, "Internal error" end
				return true, "Isolated entry created"
			end
		end
	end
})

dofile(modpath .. "/migration.lua")