-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

ipdb = {}

local function register_dummmies()
	ipdb.register_new_ids = function(name, ip)
		core.log("error", "[ipdb]: ipdb.register_new_ids called while ipdb is disabled")
	end
	ipdb.register_merger = function(func)
		local msg = "[ipdb]: ipdb.register_merger called while ipdb is disabled"
		core.log("error", msg)
		return msg
	end
	ipdb.get_mod_storage = function(func)
		local msg = "[ipdb]: ipdb.get_mod_storage called while ipdb is disabled"
		core.log("error", msg)
		return nil, msg
	end
end
local sqlite = algorithms.require("lsqlite3")
if not sqlite then
	core.log("[ipdb]: lsqlite3 needed for operation. Make sure that the library is installed and ipdb is added to secure.c_mods or secure.trusted_mods")
	register_dummmies()
	return
end

local modpath = core.get_modpath(core.get_current_modname())
local dbmanager = dofile(modpath .. "/dbmanager.lua")
local db = dbmanager.init_ipdb(sqlite)
local mergers = {}
if not db then
	core.log("error", "[ipdb]: Database initialization failed, mod cannot function")
	register_dummmies()
	return
end

local function log(err)
	core.log("error", "[ipdb]: Database operation failed with code: "..tostring(err))
end

local function merge_modstorage(entrysrcid, entrydestid)
	for modname, merger in pairs(mergers) do
		local srctable = dbmanager.get_all_modstorage(entrysrcid, modname)
		local desttable = dbmanager.get_all_modstorage(entrydestid, modname)
		if next(srctable) == nil then goto continue end -- Destination is already the exact thing we preserve
		if next(desttable) == nil then
			-- We need to reassociate srctable to destid userentry
			dbmanager.update_modstorage(modname, entrysrcid, entrydestid)
			goto continue
		end
		-- We passed the simple situations, now we need to actually call the custom merger to decide what to do
		-- First erase dest modstorage as we are about to replace it
		dbmanager.delete_modstorage(entrydestid, modname)
		local merged = merger(srctable, desttable)
		for k, v in pairs(merged) do
			dbmanager.insert_into_modstorage(entrydestid, modname, k, v)
		end
		::continue::
	end
end

ipdb.register_new_ids = function(name, ip)
	local err = db:exec("BEGIN")
	local err_msg = "The server has experienced an internal database error, please try again..."
	if err ~= sqlite.OK then log(err); return err_msg end

	-- Almost every statement needs error checking. Just use pcall to catch exceptions instead of bloating the code
	local ok, err = pcall(function()
		local user
		local ipent
		if name then user = dbmanager.user_exists(name) end
		if ip then ipent = dbmanager.ip_exists(ip) end
		if not user and not ipent then
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
				merge_modstorage(ipent.userentry_id, user.userentry_id)
				local ids = dbmanager.get_all_identifiers(ipent.userentry_id)
				-- We removed the entry that came from the IP address, now we need to insert its ids into
				-- the entry that came from the username
				dbmanager.delete_entry(ipent.userentry_id)
				local newipent_id
				for _, old_ip in ipairs(ids.ips) do
					local newid = dbmanager.add_ip(user.userentry_id, old_ip)
					if old_ip == ip then
						newipent_id = newid
					end
				end
				for _, old_name in ipairs(ids.names) do
					dbmanager.add_name(user.userentry_id, old_name)
				end
				dbmanager.update_last_seen(user.userentry_id, user.id, newipent_id)
			else
				dbmanager.update_last_seen(user.userentry_id, user.id, ipent.id)
			end
		end
	end)
	if ok then
		err = db:exec("COMMIT")
		if err == sqlite.OK then return end
	end

	-- Reachable only in the case of error
	log(err)
	db:exec("ROLLBACK")
	return err_msg
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
				if err ~= sqlite.OK then log(err); db:exec("ROLLBACK"); return false, "Internal error" end
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
				if err ~= sqlite.OK then log(err); db:exec("ROLLBACK"); return false, "Internal error" end
				if res then return res end
				return true, "IP removed"
			end
		end

		return false, "Usage: /ipdb <subcommand> args"
	end
})

dofile(modpath .. "/migration.lua")

ipdb.register_merger = function(func)
	if type(func) ~= "function" then
		return "Argument must be a function(entry1, entry2)"
	end
	local modname = core.get_current_modname()
	if not modname then
		return "ipdb.register_merger can only be called at load time"
	end
	mergers[modname] = func
end

local is_in_transaction = false

local function modstorage_set_string(self, key, value)
	if type(self) ~= "table" or type(key) ~= "string" or (type(value) ~= "string" and type(value) ~= "nil") or
	   type(self._userentry_id) ~= "number" or type(self._modname) ~= "string" or
	   self._userentry_id ~= math.floor(self._userentry_id) or not is_in_transaction then
		return "Invalid argument"
	end
	local ok, ret
	if value then
		ok, ret = pcall(dbmanager.insert_into_modstorage, self._userentry_id, self._modname, key, value)
	else
		ok, ret = pcall(dbmanager.delete_modstorage, self._userentry_id, self._modname, key)
	end
	if not ok then
		log(ret)
		db:exec("ROLLBACK")
		is_in_transaction = false
		return "Internal error"
	end
end

local function modstorage_get_string(self, key)
	if type(self) ~= "table" or type(key) ~= "string" or
	   type(self._userentry_id) ~= "number" or type(self._modname) ~= "string" or
	   self._userentry_id ~= math.floor(self._userentry_id) or not is_in_transaction then
		return nil, "Invalid argument"
	end
	local ok, ret = pcall(dbmanager.get_from_modstorage, self._userentry_id, self._modname, key)
	if not ok then
		log(ret)
		db:exec("ROLLBACK")
		is_in_transaction = false
		return "Internal error"
	end
end

local function modstorage_finalize()
	if not is_in_transaction then return end
	local err = db:exec("COMMIT")
	if err ~= sqlite.OK then log(err); db:exec("ROLLBACK"); return "Internal error" end
	is_in_transaction = false
end

local function modstorage_getcontext(modname, id, getter)
	if is_in_transaction then
		return nil, "Database locked by another context"
	end
	is_in_transaction = true
	local err = db:exec("BEGIN")
	if err ~= sqlite.OK then log(err); return nil, "Internal error" end

	local ok, ident = pcall(getter, id)
	if not ok then
		log(ident)
		db:exec("ROLLBACK")
		return nil, "Internal error"
	end
	if not ident then
		modstorage_finalize()
		return nil, "This id is unknown to ipdb"
	end
	local context = {
		_modname = modname,
		_userentry_id = ident.userentry_id,
		set_string = modstorage_set_string,
		get_string = modstorage_get_string,
		finalize = modstorage_finalize
	}
	local meta = { __gc = modstorage_finalize }
	setmetatable(context, meta)
	return context
end

ipdb.get_mod_storage = function(func)
	if func and type(func) ~= "function" then
		return nil, "If supplied, the argument must be a function(entry1, entry2)"
	end
	local modname = core.get_current_modname()
	if not modname then
		return nil, "ipdb.get_mod_storage can only be called at load time"
	end
	if func then mergers[modname] = func end
	if not mergers[modname] then
		return nil, "A merger function must be registered before you can use the modstorage"
	end
	return {
		_modname = modname,
		get_context_by_name = function(self, name)
			if type(name) ~= "string" then
				return nil, "Argument must be a username"
			end
			if type(self) ~= "table" or type(self._modname) ~= "string" then
				return nil, "Corrupted modstorage"
			end
			return modstorage_getcontext(self._modname, name, dbmanager.user_exists)
		end,
		get_context_by_ip = function(self, ip)
			if type(ip) ~= "string" or not is_ipv4(ip) then
				return nil, "Argument must be an IP address"
			end
			if type(self) ~= "table" or type(self._modname) ~= "string" then
				return nil, "Corrupted modstorage"
			end
			return modstorage_getcontext(self._modname, ip, dbmanager.ip_exists)
		end,
	}
end