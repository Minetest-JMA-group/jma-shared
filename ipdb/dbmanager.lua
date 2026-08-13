-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
local modpath = core.get_modpath(core.get_current_modname())
local dbpath = core.get_worldpath() .. "/ipdb.sqlite"
---@class DBManager
local dbmanager = {}
local ipdb
local sqlite

local function apply_schema(db, schema)
	local f = io.open(schema, "rb")
	if not f then
		core.log("error", "[ipdb]: Failed to open schema file: " .. schema)
		return false
	end
	local sql = f:read("*a")
	f:close()

	if not sql or #sql == 0 then
		core.log("error", "[ipdb]: Schema file is empty or unreadable: " .. schema)
		return false
	end

	local ret = db:exec(sql)
	if ret ~= sqlite.OK then
		core.log("error", string.format("[ipdb]: Failed to execute schema (%i): %s", ret, schema))
		return false
	end
	return true
end

local function open_database()
	local db, errcode, errmsg = sqlite.open(dbpath)
	if not db then
		core.log("error", string.format("[ipdb]: Failed to open database (%s): %s", errmsg, dbpath))
		return nil
	end
	return db
end
local function run_migration(db, current_version)
	local file_list = core.get_dir_list(modpath, false)
	local migrations = { {num = 1, file = "schema.sql"} }
	for _, filename in ipairs(file_list) do
		local num = filename:match("^migration_(%d+)%.sql$")
		if num then
			-- Version is one larger because version 1 is schema.sql
			table.insert(migrations, {num = num+1, file = filename})
		end
	end
	table.sort(migrations, function(a, b) return a.num < b.num end)
	local max_version = migrations[#migrations].num
	if current_version > max_version then
		core.log("error", "[ipdb]: Unknown database version")
		return false
	end
	for _, v in ipairs(migrations) do
		if v.num > current_version then
			if not apply_schema(db, modpath.."/"..v.file) then return false end
		end
	end
	if current_version ~= max_version then
		core.log("action", "[ipdb]: Schema applied successfully, version set to "..tostring(max_version))
	end
	return true, max_version
end
dbmanager.init_ipdb = function(sqlite_param)
	if sqlite then
		core.log("error", "[ipdb]: dbmanager.init_ipdb called more than once")
		return nil
	end
	sqlite = sqlite_param
	local db = open_database()
	if not db then return nil end
	db:busy_timeout(1000)
	local ret = db:exec("PRAGMA foreign_keys = ON")
	if ret ~= sqlite.OK then
		core.log("error", "[ipdb]: Failed to enable foreign keys and set journal mode")
		db:close()
		return nil
	end

	ret = db:exec("BEGIN")
	if ret ~= sqlite.OK then
		core.log("error", "[ipdb]: Cannot start a transaction. Error: "..tostring(ret))
		db:exec("ROLLBACK")
		db:close()
		return nil
	end
	local version
	for val in db:urows("PRAGMA user_version;") do
		version = val
	end
	if version >= 4 then
		ipdb = db
		local ok, err_or_try_meta = pcall(dbmanager.get_meta, "db_version")
		ipdb = nil
		if not ok then
			core.log("error", "[ipdb]: Database operation failed with code: "..tostring(err_or_try_meta))
			db:exec("ROLLBACK")
			db:close()
			return nil
		end
		if err_or_try_meta then
			version = tonumber(err_or_try_meta)
		end
	end
	-- The version read is done, release the transaction: PRAGMA foreign_keys can
	-- only be toggled outside of a transaction, and the migration batch needs it
	-- off (migration 5 recreates UserEntry; dropping the old table would otherwise
	-- cascade into Usernames, IPs and Modstorage)
	ret = db:exec("COMMIT")
	if ret ~= sqlite.OK then
		core.log("error", "[ipdb]: Failed to commit initial transaction. Error: "..tostring(ret))
		db:exec("ROLLBACK")
		db:close()
		return nil
	end
	ret = db:exec("PRAGMA foreign_keys = OFF")
	if ret ~= sqlite.OK then
		core.log("error", "[ipdb]: Failed to disable foreign keys for the migration. Error: "..tostring(ret))
		db:close()
		return nil
	end
	ret = db:exec("BEGIN")
	if ret ~= sqlite.OK then
		core.log("error", "[ipdb]: Cannot start a transaction. Error: "..tostring(ret))
		db:exec("PRAGMA foreign_keys = ON")
		db:close()
		return nil
	end
	local ok, new_version = run_migration(db, version)
	if not ok then
		db:exec("ROLLBACK")
		db:exec("PRAGMA foreign_keys = ON")
		db:close()
		return nil
	end
	ret = db:exec("COMMIT")
	if ret ~= sqlite.OK then
		core.log("error", "[ipdb]: Failed to commit migration transaction. Error: "..tostring(ret))
		db:exec("ROLLBACK")
		db:exec("PRAGMA foreign_keys = ON")
		db:close()
		return nil
	end
	ret = db:exec("PRAGMA foreign_keys = ON")
	if ret ~= sqlite.OK then
		core.log("error", "[ipdb]: Failed to re-enable foreign keys. Error: "..tostring(ret))
		db:close()
		return nil
	end

	ipdb = db
	return { db = db, version = new_version }
end

local user_check
-- Search for the given username and return the row as Lua key-value table if it exists
---@param username string
---@return UsernameEntity?
dbmanager.user_exists = function(username)
	if not user_check then
		user_check = ipdb:prepare("SELECT * FROM Usernames WHERE name = ?;")
		if not user_check then error(ipdb:errmsg()) end
	else
		user_check:reset()
	end
	local ret = user_check:bind(1, username)
	if ret ~= sqlite.OK then error(ret) end
	for result in user_check:nrows() do
		return result
	end
end

local ip_check
-- Search for the given IP and return the row as Lua key-value table if it exists
---@param ip string
---@return IPEntity?
dbmanager.ip_exists = function(ip)
	if not ip_check then
		ip_check = ipdb:prepare("SELECT * FROM IPs WHERE ip = ?;")
		if not ip_check then error(ipdb:errmsg()) end
	else
		ip_check:reset()
	end
	local ret = ip_check:bind(1, ip)
	if ret ~= sqlite.OK then error(ret) end
	for result in ip_check:nrows() do
		return result
	end
end

local new_entry
-- Create a new user entry and return its id
---@return integer
dbmanager.new_entry = function()
	if not new_entry then
		new_entry = ipdb:prepare("INSERT INTO UserEntry (last_seen) VALUES (CURRENT_TIMESTAMP);")
		if not new_entry then error(ipdb:errmsg()) end
	else
		new_entry:reset()
	end
	local ret = new_entry:step()
	if ret ~= sqlite.DONE then error(ret) end
	return new_entry:last_insert_rowid()
end

local update_entry_time
local update_name_time
local update_ip_time
-- Update last_seen time for given entries
---@param entryid integer?
---@param nameid integer?
---@param ipid integer?
dbmanager.update_last_seen = function(entryid, nameid, ipid)
	local now = os.date("!%Y-%m-%d %H:%M:%S")
	if entryid then
		if not update_entry_time then
			update_entry_time = ipdb:prepare("UPDATE UserEntry SET last_seen = ? WHERE id = ?")
			if not update_entry_time then error(ipdb:errmsg()) end
		else
			update_entry_time:reset()
		end
		local ret = update_entry_time:bind_values(now, entryid)
		if ret ~= sqlite.OK then error(ret) end
		ret = update_entry_time:step()
		if ret ~= sqlite.DONE then error(ret) end
	end
	if nameid then
		if not update_name_time then
			update_name_time = ipdb:prepare("UPDATE Usernames SET last_seen = ? WHERE id = ?")
			if not update_name_time then error(ipdb:errmsg()) end
		else
			update_name_time:reset()
		end
		local ret = update_name_time:bind_values(now, nameid)
		if ret ~= sqlite.OK then error(ret) end
		ret = update_name_time:step()
		if ret ~= sqlite.DONE then error(ret) end
	end
	if ipid then
		if not update_ip_time then
			update_ip_time = ipdb:prepare("UPDATE IPs SET last_seen = ? WHERE id = ?")
			if not update_ip_time then error(ipdb:errmsg()) end
		else
			update_ip_time:reset()
		end
		local ret = update_ip_time:bind_values(now, ipid)
		if ret ~= sqlite.OK then error(ret) end
		ret = update_ip_time:step()
		if ret ~= sqlite.DONE then error(ret) end
	end
end

-- Return a table { ips = {}, names = {}} with a list of ips and names belonging to this entry.
local get_ips
local get_names
---@param entryid integer
---@return { ips: string[], names: string[] }
dbmanager.get_all_identifiers = function(entryid)
	local res = { ips = {}, names = {} }
	if not get_ips then
		get_ips = ipdb:prepare("SELECT ip FROM IPs WHERE userentry_id = ?")
		get_names = ipdb:prepare("SELECT name FROM Usernames WHERE userentry_id = ?")
		if not get_ips then error(ipdb:errmsg()) end
		if not get_names then error(ipdb:errmsg()) end
	else
		get_ips:reset()
		get_names:reset()
	end
	local ret = get_ips:bind(1, entryid)
	if ret ~= sqlite.OK then error(ret) end
	ret = get_names:bind(1, entryid)
	if ret ~= sqlite.OK then error(ret) end

	for result in get_ips:nrows() do
		table.insert(res.ips, result.ip)
	end
	for result in get_names:nrows() do
		table.insert(res.names, result.name)
	end
	return res
end

local insert_ip
-- Return the id of the new IP row
---@param entryid integer
---@param ip string
---@return integer
dbmanager.add_ip = function(entryid, ip)
	if not insert_ip then
		insert_ip = ipdb:prepare("INSERT INTO IPs (userentry_id, ip, last_seen) VALUES (?, ?, CURRENT_TIMESTAMP)")
		if not insert_ip then error(ipdb:errmsg()) end
	else
		insert_ip:reset()
	end
	local ret = insert_ip:bind_values(entryid, ip)
	if ret ~= sqlite.OK then error(ret) end
	ret = insert_ip:step()
	if ret ~= sqlite.DONE then error(ret) end
	return insert_ip:last_insert_rowid()
end

local insert_name
---@param entryid integer
---@param name string
dbmanager.add_name = function(entryid, name)
	if not insert_name then
		insert_name = ipdb:prepare("INSERT INTO Usernames (userentry_id, name, last_seen) VALUES (?, ?, CURRENT_TIMESTAMP)")
		if not insert_name then error(ipdb:errmsg()) end
	else
		insert_name:reset()
	end
	local ret = insert_name:bind_values(entryid, name)
	if ret ~= sqlite.OK then error(ret) end
	ret = insert_name:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local delete_entry
---@param entryid integer
dbmanager.delete_entry = function(entryid)
	if not delete_entry then
		delete_entry = ipdb:prepare("DELETE FROM UserEntry WHERE id = ?")
		if not delete_entry then error(ipdb:errmsg()) end
	else
		delete_entry:reset()
	end
	local ret = delete_entry:bind(1, entryid)
	if ret ~= sqlite.OK then error(ret) end
	ret = delete_entry:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local set_meta
local delete_meta
---@param key string
---@param newval string?
dbmanager.set_meta = function(key, newval)
	if newval ~= nil then
		if not set_meta then
			set_meta = ipdb:prepare("UPDATE Metadata SET value = ? WHERE key = ?")
			if not set_meta then error(ipdb:errmsg()) end
		else
			set_meta:reset()
		end
		newval = tostring(newval)
		local ret = set_meta:bind_values(newval, key)
		if ret ~= sqlite.OK then error(ret) end
		ret = set_meta:step()
		if ret ~= sqlite.DONE then error(ret) end
	else
		if not delete_meta then
			delete_meta = ipdb:prepare("DELETE FROM Metadata WHERE key = ?")
			if not delete_meta then error(ipdb:errmsg()) end
		else
			delete_meta:reset()
		end
		local ret = delete_meta:bind(1, key)
		if ret ~= sqlite.OK then error(ret) end
		ret = delete_meta:step()
		if ret ~= sqlite.DONE then error(ret) end
	end
end

local get_meta
---@param key string
---@return string?
dbmanager.get_meta = function(key)
	if not get_meta then
		get_meta = ipdb:prepare("SELECT value FROM Metadata WHERE key = ?")
		if not get_meta then error(ipdb:errmsg()) end
	else
		get_meta:reset()
	end
	local ret = get_meta:bind(1, key)
	if ret ~= sqlite.OK then error(ret) end
	ret = get_meta:step()
	if ret ~= sqlite.ROW then
		if ret == sqlite.DONE then
			return nil
		end
		error(ret)
	end
	local val = get_meta:get_value(0)
	ret = get_meta:step()
	if ret ~= sqlite.DONE then error(ret) end
	return val
end

local set_merge_perm
-- Set no_merging flag in entry
---@param entryid integer
---@param allowed boolean
dbmanager.set_merge_allowance = function(entryid, allowed)
	local no_merging = nil
	if not allowed then no_merging = 1 end

	if not set_merge_perm then
		set_merge_perm = ipdb:prepare("UPDATE UserEntry SET no_merging = ? WHERE id = ?")
		if not set_merge_perm then error(ipdb:errmsg()) end
	else
		set_merge_perm:reset()
	end
	local ret = set_merge_perm:bind_values(no_merging, entryid)
	if ret ~= sqlite.OK then error(ret) end
	ret = set_merge_perm:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local check_merge_blocked
---@param entryid1 integer
---@param entryid2 integer
dbmanager.can_merge = function(entryid1, entryid2)
	if not check_merge_blocked then
		check_merge_blocked = ipdb:prepare("SELECT COUNT(*) FROM UserEntry WHERE id IN (?, ?) AND no_merging = 1;")
		if not check_merge_blocked then error(ipdb:errmsg()) end
	else
		check_merge_blocked:reset()
	end

	local ret = check_merge_blocked:bind_values(entryid1, entryid2)
	if ret ~= sqlite.OK then error(ret) end

	ret = check_merge_blocked:step()
	if ret ~= sqlite.ROW then error(ret) end

	local blocked_count = check_merge_blocked:get_value(0)
	ret = check_merge_blocked:step()
	if ret ~= sqlite.DONE then error(ret) end

	return blocked_count == 0
end

local remove_ip
---@param ipid integer
dbmanager.remove_ip = function(ipid)
	if not remove_ip then
		remove_ip = ipdb:prepare("DELETE FROM IPs WHERE id = ?")
		if not remove_ip then error(ipdb:errmsg()) end
	else
		remove_ip:reset()
	end
	local ret = remove_ip:bind(1, ipid)
	if ret ~= sqlite.OK then error(ret) end
	ret = remove_ip:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local remove_name
---@param nameid integer
dbmanager.remove_name = function(nameid)
	if not remove_name then
		remove_name = ipdb:prepare("DELETE FROM Usernames WHERE id = ?")
		if not remove_name then error(ipdb:errmsg()) end
	else
		remove_name:reset()
	end
	local ret = remove_name:bind(1, nameid)
	if ret ~= sqlite.OK then error(ret) end
	ret = remove_name:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local remove_all_ips
---@param entryid integer
dbmanager.remove_all_ips = function(entryid)
	if not remove_all_ips then
		remove_all_ips = ipdb:prepare("DELETE FROM IPs WHERE userentry_id = ?")
		if not remove_all_ips then error(ipdb:errmsg()) end
	else
		remove_all_ips:reset()
	end
	local ret = remove_all_ips:bind(1, entryid)
	if ret ~= sqlite.OK then error(ret) end
	ret = remove_all_ips:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local reassociate_ip
local reassociate_name
-- Change the userentry_id of an IP row and/or a Username row to the given new entry ID
---@param newentryid integer
---@param nameid integer?
---@param ipid integer?
dbmanager.reassociate_ids = function(newentryid, nameid, ipid)
	if ipid then
		if not reassociate_ip then
			reassociate_ip = ipdb:prepare("UPDATE IPs SET userentry_id = ? WHERE id = ?")
			if not reassociate_ip then error(ipdb:errmsg()) end
		else
			reassociate_ip:reset()
		end
		local ret = reassociate_ip:bind_values(newentryid, ipid)
		if ret ~= sqlite.OK then error(ret) end
		ret = reassociate_ip:step()
		if ret ~= sqlite.DONE then error(ret) end
	end
	if nameid then
		if not reassociate_name then
			reassociate_name = ipdb:prepare("UPDATE Usernames SET userentry_id = ? WHERE id = ?")
			if not reassociate_name then error(ipdb:errmsg()) end
		else
			reassociate_name:reset()
		end
		local ret = reassociate_name:bind_values(newentryid, nameid)
		if ret ~= sqlite.OK then error(ret) end
		ret = reassociate_name:step()
		if ret ~= sqlite.DONE then error(ret) end
	end
end

local modstorage_insert
-- Insert a value into modstorage table
---@param userentry_id integer
---@param modname string
---@param key string
---@param value string?
---@param ancillary integer?
dbmanager.insert_into_modstorage = function(userentry_id, modname, key, value, ancillary)
	if not modstorage_insert then
		modstorage_insert = ipdb:prepare("INSERT INTO Modstorage (userentry_id, modname, key, data, ancillary) "..
	                                     "VALUES (?, ?, ?, ?, ?)")
		if not modstorage_insert then error(ipdb:errmsg()) end
	else
		modstorage_insert:reset()
	end
	local ret = modstorage_insert:bind_values(userentry_id, modname, key, value, ancillary)
	if ret ~= sqlite.OK then error(ret) end
	ret = modstorage_insert:step()
	if ret ~= sqlite.DONE then error(ret) end
end

---@class ModstorageValue
---@field value string
---@field ancillary integer?

local modstorage_get
local modstorage_get_no_limit
-- Get the values associated with the given key in modstorage table.
-- Returns { modstorage_id = { ["value"] = data, ["ancillary"] = ancillary } }
---@param userentry_id integer
---@param modname string
---@param key string
---@param limit integer?
---@return table<integer, ModstorageValue>
dbmanager.get_from_modstorage = function(userentry_id, modname, key, limit)
	local mystmt
	local ret
	if limit then
		if not modstorage_get then
			modstorage_get = ipdb:prepare("SELECT id, data, ancillary FROM Modstorage WHERE userentry_id = ? "..
			                              "AND modname = ? AND key = ? LIMIT ?")
			if not modstorage_get then error(ipdb:errmsg()) end
		else
			modstorage_get:reset()
		end
		ret = modstorage_get:bind_values(userentry_id, modname, key, limit)
		mystmt = modstorage_get
	else
		if not modstorage_get_no_limit then
			modstorage_get_no_limit = ipdb:prepare("SELECT id, data, ancillary FROM Modstorage WHERE userentry_id = ? "..
			                                  "AND modname = ? AND key = ?")
			if not modstorage_get_no_limit then error(ipdb:errmsg()) end
		else
			modstorage_get_no_limit:reset()
		end
		ret = modstorage_get_no_limit:bind_values(userentry_id, modname, key)
		mystmt = modstorage_get_no_limit
	end
	if ret ~= sqlite.OK then error(ret) end

	local values = {}
	ret = mystmt:step()
	while ret == sqlite.ROW do
		local id = mystmt:get_value(0)
		local data = mystmt:get_value(1)
		local ancillary = mystmt:get_value(2)
		values[id] = { value = data, ancillary = ancillary }
		ret = mystmt:step()
	end
	if ret ~= sqlite.DONE then error(ret) end
	return values
end

local update_modstorage1
local update_modstorage1_stmt = [[UPDATE Modstorage
SET modname      = COALESCE(?, modname),
    userentry_id = COALESCE(?, userentry_id),
    key          = COALESCE(?, key),
    data         = COALESCE(?, data),
    ancillary    = CASE WHEN ? THEN ? ELSE ancillary END
WHERE id = ?]]
-- Update a value identified by modstorage_id
---@param modstorage_id integer
---@param userentry_id integer?
---@param modname string?
---@param key string?
---@param value string?
---@param ... integer?	-- Supply ancillary if you want to modify it
dbmanager.update_modstorage1 = function(modstorage_id, userentry_id, modname, key, value, ...)
	local ancillary
	local update_ancillary = false
	local errmsg = "Accepting at most one variadic argument - ancillary integer|nil"
	if select('#', ...) > 1 then
		error(errmsg)
	end
	if select('#', ...) == 1 then
		update_ancillary = true
		ancillary = select(1, ...)
		if type(ancillary) ~= "nil" and type(ancillary) ~= "number" then
			error(errmsg)
		end
		if type(ancillary) == "number" and ancillary ~= math.floor(ancillary) then
			error(errmsg)
		end
	end

	if not update_modstorage1 then
		update_modstorage1 = ipdb:prepare(update_modstorage1_stmt)
		if not update_modstorage1 then error(ipdb:errmsg()) end
	else
		update_modstorage1:reset()
	end
	local ret = update_modstorage1:bind_values(modname, userentry_id, key, value, update_ancillary, ancillary, modstorage_id)
	if ret ~= sqlite.OK then error(ret) end
	ret = update_modstorage1:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local update_modstorage2
-- Update all values identified by (userentry_id, modname, key) tuple
---@param userentry_id integer
---@param modname string
---@param key string
---@param value string
---@param ancillary integer?
dbmanager.update_modstorage2 = function(userentry_id, modname, key, value, ancillary)
	if not update_modstorage2 then
		update_modstorage2 = ipdb:prepare("UPDATE Modstorage SET data = ?, ancillary = ? WHERE userentry_id = ? "..
		                                  "AND modname = ? AND KEY = ?")
		if not update_modstorage2 then error(ipdb:errmsg()) end
	else
		update_modstorage2:reset()
	end
	local ret = update_modstorage2:bind_values(value, ancillary, userentry_id, modname, key)
	if ret ~= sqlite.OK then error(ret) end
	ret = update_modstorage2:step()
	if ret ~= sqlite.DONE then error(ret) end
end

---@alias ModstorageValueTypes string|ModstorageValue
local modstorage_get_all
-- Get all key-value pairs associated with given user entry and modname
---@param userentry_id integer
---@param modname string
---@return table<string, ModstorageValueTypes|table<integer, ModstorageValueTypes>> -- { key = data } in the simplest case, { key = {id = data}} for multimap, data = {["value"] = data, ["ancillary"] = ancillary} when ancillary exists
dbmanager.get_all_modstorage = function(userentry_id, modname)
	if not modstorage_get_all then
		modstorage_get_all = ipdb:prepare("SELECT key, data, id, ancillary FROM Modstorage WHERE userentry_id = ? "..
		                                  "AND modname = ?")
		if not modstorage_get_all then error(ipdb:errmsg()) end
	else
		modstorage_get_all:reset()
	end

	local ret = modstorage_get_all:bind_values(userentry_id, modname)
	if ret ~= sqlite.OK then error(ret) end

	local results = {}
	local is_multimap = {}
	local saved_ids = {}
	while true do
		ret = modstorage_get_all:step()
		if ret == sqlite.DONE then
			break
		elseif ret ~= sqlite.ROW then
			error(ret)
		end
		local key = modstorage_get_all:get_value(0)
		local data = modstorage_get_all:get_value(1)
		local id = modstorage_get_all:get_value(2)
		local ancillary = modstorage_get_all:get_value(3)
		if ancillary then
			data = { value = data, ancillary = ancillary }
		end
		if not results[key] then
			results[key] = data
			saved_ids[key] = id
		else
			if not is_multimap[key] then
				local val = results[key]
				local val_id = saved_ids[key]
				saved_ids[key] = nil
				results[key] = {[val_id] = val}
				is_multimap[key] = true
			end
			results[key][id] = data
		end
	end

	return results
end

---@class ModstorageInfo
---@field modname string
---@field userentry_id integer

-- Get information about a modstorage row
local get_modstorage_info
---@param modstorage_id integer
---@return ModstorageInfo?
dbmanager.get_modstorage_info = function(modstorage_id)
	if not get_modstorage_info then
		get_modstorage_info = ipdb:prepare("SELECT modname, userentry_id FROM Modstorage WHERE id = ?")
		if not get_modstorage_info then error(ipdb:errmsg()) end
	else
		get_modstorage_info:reset()
	end
	local ret = get_modstorage_info:bind(1, modstorage_id)
	if ret ~= sqlite.OK then error(ret) end
	ret = get_modstorage_info:step()
	if ret ~= sqlite.ROW then
		if ret == sqlite.DONE then
			return nil
		end
		error(ret)
	end
	local val = {
		modname = get_modstorage_info:get_value(0),
		userentry_id = get_modstorage_info:get_value(1)
	}

	ret = get_modstorage_info:step()
	if ret ~= sqlite.DONE then error(ret) end
	return val
end

local reassociate_modstorage
-- Reassociate modstorage to a new entry
---@param modname string
---@param old_userentry_id integer
---@param new_userentry_id integer
dbmanager.reassociate_modstorage = function(modname, old_userentry_id, new_userentry_id)
	if not reassociate_modstorage then
		reassociate_modstorage = ipdb:prepare("UPDATE Modstorage SET userentry_id = ? WHERE userentry_id = ? "..
		                                      "AND modname = ?")
		if not reassociate_modstorage then error(ipdb:errmsg()) end
	else
		reassociate_modstorage:reset()
	end

	local ret = reassociate_modstorage:bind_values(new_userentry_id, old_userentry_id, modname)
	if ret ~= sqlite.OK then error(ret) end

	ret = reassociate_modstorage:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local modstorage_delete_one
local modstorage_delete_all
-- Delete all rows identified by the given (userentry_id, modname, key) or,
-- if the key is missing, (userentry_id, modname) tuple
---@param userentry_id integer
---@param modname string
---@param key string?
dbmanager.delete_modstorage = function(userentry_id, modname, key)
	if key then
		if not modstorage_delete_one then
			modstorage_delete_one = ipdb:prepare("DELETE FROM Modstorage WHERE userentry_id = ? AND modname = ? AND key = ?")
			if not modstorage_delete_one then error(ipdb:errmsg()) end
		else
			modstorage_delete_one:reset()
		end
		local ret = modstorage_delete_one:bind_values(userentry_id, modname, key)
		if ret ~= sqlite.OK then error(ret) end
		ret = modstorage_delete_one:step()
		if ret ~= sqlite.DONE then error(ret) end
	else
		if not modstorage_delete_all then
			modstorage_delete_all = ipdb:prepare("DELETE FROM Modstorage WHERE userentry_id = ? AND modname = ?")
			if not modstorage_delete_all then error(ipdb:errmsg()) end
		else
			modstorage_delete_all:reset()
		end
		local ret = modstorage_delete_all:bind_values(userentry_id, modname)
		if ret ~= sqlite.OK then error(ret) end
		ret = modstorage_delete_all:step()
		if ret ~= sqlite.DONE then error(ret) end
	end
end

local remove_modstorage
-- Delete the given row from Modstorage
---@param modstorage_id integer
dbmanager.remove_modstorage = function(modstorage_id)
	if not remove_modstorage then
		remove_modstorage = ipdb:prepare("DELETE FROM Modstorage WHERE id = ?")
		if not remove_modstorage then error(ipdb:errmsg()) end
	else
		remove_modstorage:reset()
	end
	local ret = remove_modstorage:bind(1, modstorage_id)
	if ret ~= sqlite.OK then error(ret) end
	ret = remove_modstorage:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local new_merge
local log_modstorage
local log_modstorage_stmt = [[INSERT INTO Modstorage_log (modname, userentry_id, key, data, ancillary, merge_id)
SELECT modname, userentry_id, key, data, ancillary, ?
FROM Modstorage
WHERE userentry_id IN (?, ?)]]
local log_usernames
local log_usernames_stmt = [[INSERT INTO Usernames_log (userentry_id, name, created_at, last_seen, merge_id)
SELECT userentry_id, name, created_at, last_seen, ?
FROM Usernames
WHERE userentry_id = ?]]
local log_ips
local log_ips_stmt = [[INSERT INTO IPs_log (userentry_id, ip, created_at, last_seen, merge_id)
SELECT userentry_id, ip, created_at, last_seen, ?
FROM IPs
WHERE userentry_id = ?]]
---@param entry_src integer
---@param entry_dst integer
---@param name string
---@param ip string
dbmanager.new_merge_event = function(entry_src, entry_dst, name, ip)
	if not new_merge then
		new_merge = ipdb:prepare("INSERT INTO MergeEvent (entry_src, entry_dst, name, ip) VALUES (?, ?, ?, ?)")
		if not new_merge then error(ipdb:errmsg()) end
	else
		new_merge:reset()
	end
	if not log_modstorage then
		log_modstorage = ipdb:prepare(log_modstorage_stmt)
		if not log_modstorage then error(ipdb:errmsg()) end
	else
		log_modstorage:reset()
	end
	if not log_usernames then
		log_usernames = ipdb:prepare(log_usernames_stmt)
		if not log_usernames then error(ipdb:errmsg()) end
	else
		log_usernames:reset()
	end
	if not log_ips then
		log_ips = ipdb:prepare(log_ips_stmt)
		if not log_ips then error(ipdb:errmsg()) end
	else
		log_ips:reset()
	end

	local ret = new_merge:bind_values(entry_src, entry_dst, name, ip)
	if ret ~= sqlite.OK then error(ret) end
	ret = new_merge:step()
	if ret ~= sqlite.DONE then error(ret) end
	local merge_id = new_merge:last_insert_rowid()

	ret = log_modstorage:bind_values(merge_id, entry_src, entry_dst)
	if ret ~= sqlite.OK then error(ret) end
	ret = log_modstorage:step()
	if ret ~= sqlite.DONE then error(ret) end

	ret = log_usernames:bind_values(merge_id, entry_src)
	if ret ~= sqlite.OK then error(ret) end
	ret = log_usernames:step()
	if ret ~= sqlite.DONE then error(ret) end

	ret = log_ips:bind_values(merge_id, entry_src)
	if ret ~= sqlite.OK then error(ret) end
	ret = log_ips:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local prune_merge
---@param max_age integer
dbmanager.prune_merge_events = function(max_age)
	if not prune_merge then
		prune_merge = ipdb:prepare("DELETE FROM MergeEvent WHERE timestamp < unixepoch('now') - ?")
		if not prune_merge then error(ipdb:errmsg()) end
	else
		prune_merge:reset()
	end
	local ret = prune_merge:bind(1, max_age)
	if ret ~= sqlite.OK then error(ret) end
	ret = prune_merge:step()
	if ret ~= sqlite.DONE then error(ret) end
end

-- ═══════════════ Merge history and rollback ═══════════════

---@class MergeEventRow
---@field id integer
---@field entry_src integer
---@field entry_dst integer
---@field name string
---@field ip string
---@field timestamp integer
---@field reverted_at integer?

local entry_by_id
-- Get a user entry row by its id
---@param entryid integer
---@return UserEntryEntity?
dbmanager.get_userentry = function(entryid)
	if not entry_by_id then
		entry_by_id = ipdb:prepare("SELECT * FROM UserEntry WHERE id = ?")
		if not entry_by_id then error(ipdb:errmsg()) end
	else
		entry_by_id:reset()
	end
	local ret = entry_by_id:bind(1, entryid)
	if ret ~= sqlite.OK then error(ret) end
	for result in entry_by_id:nrows() do
		return result
	end
end

local merge_events_list
-- List the given number of most recent merge events, with the size of the
-- snapshots taken for each of them
---@param limit integer
---@return MergeEventRow[]
dbmanager.get_merge_events = function(limit)
	if not merge_events_list then
		merge_events_list = ipdb:prepare("SELECT m.id, m.entry_src, m.entry_dst, m.name, m.ip, "..
		                                 "m.timestamp, m.reverted_at, "..
		                                 "(SELECT COUNT(*) FROM Usernames_log l WHERE l.merge_id = m.id) AS name_count, "..
		                                 "(SELECT COUNT(*) FROM IPs_log l WHERE l.merge_id = m.id) AS ip_count "..
		                                 "FROM MergeEvent m ORDER BY m.timestamp DESC LIMIT ?")
		if not merge_events_list then error(ipdb:errmsg()) end
	else
		merge_events_list:reset()
	end
	local ret = merge_events_list:bind(1, limit)
	if ret ~= sqlite.OK then error(ret) end
	local results = {}
	for result in merge_events_list:nrows() do
		table.insert(results, result)
	end
	return results
end

local merge_event_by_id
---@param merge_id integer
---@return MergeEventRow?
dbmanager.get_merge_event = function(merge_id)
	if not merge_event_by_id then
		merge_event_by_id = ipdb:prepare("SELECT * FROM MergeEvent WHERE id = ?")
		if not merge_event_by_id then error(ipdb:errmsg()) end
	else
		merge_event_by_id:reset()
	end
	local ret = merge_event_by_id:bind(1, merge_id)
	if ret ~= sqlite.OK then error(ret) end
	for result in merge_event_by_id:nrows() do
		return result
	end
end

local log_names_stmt
local log_ips_stmt
local log_modstorage_stmt
-- Get all logged rows of a merge event: the pre-merge state of the absorbed
-- entry's identifiers and of both entries' modstorage
---@param merge_id integer
---@return { names: table[], ips: table[], modstorage: table[] }
dbmanager.get_merge_log = function(merge_id)
	if not log_names_stmt then
		log_names_stmt = ipdb:prepare("SELECT * FROM Usernames_log WHERE merge_id = ?")
		log_ips_stmt = ipdb:prepare("SELECT * FROM IPs_log WHERE merge_id = ?")
		log_modstorage_stmt = ipdb:prepare("SELECT * FROM Modstorage_log WHERE merge_id = ?")
		if not log_names_stmt or not log_ips_stmt or not log_modstorage_stmt then error(ipdb:errmsg()) end
	else
		log_names_stmt:reset()
		log_ips_stmt:reset()
		log_modstorage_stmt:reset()
	end
	local ret = log_names_stmt:bind(1, merge_id)
	if ret ~= sqlite.OK then error(ret) end
	ret = log_ips_stmt:bind(1, merge_id)
	if ret ~= sqlite.OK then error(ret) end
	ret = log_modstorage_stmt:bind(1, merge_id)
	if ret ~= sqlite.OK then error(ret) end
	local res = { names = {}, ips = {}, modstorage = {} }
	for result in log_names_stmt:nrows() do
		table.insert(res.names, result)
	end
	for result in log_ips_stmt:nrows() do
		table.insert(res.ips, result)
	end
	for result in log_modstorage_stmt:nrows() do
		table.insert(res.modstorage, result)
	end
	return res
end

local idents_at_names
local idents_at_names_all
local idents_at_ips
local idents_at_ips_all
-- Identifiers of an entry together with their timestamps. If max_timestamp is
-- given, only those that already existed at that time are returned
---@param entryid integer
---@param max_timestamp string?
---@return { names: { { name: string, created_at: string, last_seen: string } }[], ips: { { ip: string, created_at: string, last_seen: string } }[] }
dbmanager.get_identifiers_at = function(entryid, max_timestamp)
	local mystmt
	local ret
	if max_timestamp then
		if not idents_at_names then
			idents_at_names = ipdb:prepare("SELECT name, created_at, last_seen FROM Usernames "..
			                               "WHERE userentry_id = ? AND created_at <= ?")
			idents_at_ips = ipdb:prepare("SELECT ip, created_at, last_seen FROM IPs "..
			                             "WHERE userentry_id = ? AND created_at <= ?")
			if not idents_at_names or not idents_at_ips then error(ipdb:errmsg()) end
		else
			idents_at_names:reset()
			idents_at_ips:reset()
		end
		ret = idents_at_names:bind_values(entryid, max_timestamp)
		if ret ~= sqlite.OK then error(ret) end
		ret = idents_at_ips:bind_values(entryid, max_timestamp)
		if ret ~= sqlite.OK then error(ret) end
		mystmt = { n = idents_at_names, i = idents_at_ips }
	else
		if not idents_at_names_all then
			idents_at_names_all = ipdb:prepare("SELECT name, created_at, last_seen FROM Usernames WHERE userentry_id = ?")
			idents_at_ips_all = ipdb:prepare("SELECT ip, created_at, last_seen FROM IPs WHERE userentry_id = ?")
			if not idents_at_names_all or not idents_at_ips_all then error(ipdb:errmsg()) end
		else
			idents_at_names_all:reset()
			idents_at_ips_all:reset()
		end
		ret = idents_at_names_all:bind(1, entryid)
		if ret ~= sqlite.OK then error(ret) end
		ret = idents_at_ips_all:bind(1, entryid)
		if ret ~= sqlite.OK then error(ret) end
		mystmt = { n = idents_at_names_all, i = idents_at_ips_all }
	end
	local res = { names = {}, ips = {} }
	for result in mystmt.n:nrows() do
		table.insert(res.names, result)
	end
	for result in mystmt.i:nrows() do
		table.insert(res.ips, result)
	end
	return res
end

local latest_dst_merge
local latest_dst_merge_before
-- The most recent merge that produced the given entry, if any
---@param entryid integer
---@return MergeEventRow?
dbmanager.get_latest_merge = function(entryid)
	if not latest_dst_merge then
		latest_dst_merge = ipdb:prepare("SELECT * FROM MergeEvent WHERE entry_dst = ? AND reverted_at IS NULL "..
		                                "ORDER BY timestamp DESC LIMIT 1")
		if not latest_dst_merge then error(ipdb:errmsg()) end
	else
		latest_dst_merge:reset()
	end
	local ret = latest_dst_merge:bind(1, entryid)
	if ret ~= sqlite.OK then error(ret) end
	for result in latest_dst_merge:nrows() do
		return result
	end
end

-- The most recent merge that produced the given entry at a time before max_ts
---@param entryid integer
---@param max_ts integer  -- merges at or after this time are not part of the entry's past
---@return MergeEventRow?
dbmanager.get_latest_merge_before = function(entryid, max_ts)
	if not latest_dst_merge_before then
		latest_dst_merge_before = ipdb:prepare("SELECT * FROM MergeEvent WHERE entry_dst = ? "..
		                                       "AND reverted_at IS NULL AND timestamp < ? "..
		                                       "ORDER BY timestamp DESC LIMIT 1")
		if not latest_dst_merge_before then error(ipdb:errmsg()) end
	else
		latest_dst_merge_before:reset()
	end
	local ret = latest_dst_merge_before:bind_values(entryid, max_ts)
	if ret ~= sqlite.OK then error(ret) end
	for result in latest_dst_merge_before:nrows() do
		return result
	end
end

local older_merges
-- Count the merges that are older than the given entry itself; they belong to
-- a previous entry that had the same id (id reuse)
---@param entryid integer
---@param created_at string
---@return integer
dbmanager.count_older_merges = function(entryid, created_at)
	if not older_merges then
		older_merges = ipdb:prepare("SELECT COUNT(*) FROM MergeEvent WHERE entry_dst = ? "..
		                            "AND reverted_at IS NULL AND timestamp < strftime('%s', ?)")
		if not older_merges then error(ipdb:errmsg()) end
	else
		older_merges:reset()
	end
	local ret = older_merges:bind_values(entryid, created_at)
	if ret ~= sqlite.OK then error(ret) end
	ret = older_merges:step()
	if ret ~= sqlite.ROW then error(ret) end
	local count = older_merges:get_value(0)
	ret = older_merges:step()
	if ret ~= sqlite.DONE then error(ret) end
	return count
end

-- Shared analysis for rollback: verifies that the merge can be rolled back and
-- collects everything the rollback needs - where the logged identifiers live
-- now, which of the destination entry's identifiers were created after the
-- merge, and whether the old source entry id is still free
---@param merge_id integer
---@return MergeEventRow?, table?, integer?, table[]?, string?
local function analyze_merge(merge_id)
	local me = dbmanager.get_merge_event(merge_id)
	if not me then
		return nil, nil, nil, nil, "No such merge event"
	end
	if me.reverted_at then
		return nil, nil, nil, nil, "This merge has already been rolled back"
	end
	local log = dbmanager.get_merge_log(merge_id)
	-- The logged identifiers were moved to the destination at merge time; find
	-- the single entry they currently belong to
	local dst_id
	for _, row in ipairs(log.names) do
		local live = dbmanager.user_exists(row.name)
		if live then
			if dst_id and live.userentry_id ~= dst_id then
				return nil, nil, nil, nil, "Identifiers of this merge now belong to multiple entries; roll back the later merges first"
			end
			dst_id = live.userentry_id
		end
	end
	for _, row in ipairs(log.ips) do
		local live = dbmanager.ip_exists(row.ip)
		if live then
			if dst_id and live.userentry_id ~= dst_id then
				return nil, nil, nil, nil, "Identifiers of this merge now belong to multiple entries; roll back the later merges first"
			end
			dst_id = live.userentry_id
		end
	end
	if not dst_id then
		return nil, nil, nil, nil, "None of the identifiers of this merge remain in the database; there is nothing to roll back to"
	end
	if dst_id ~= me.entry_dst then
		return nil, nil, nil, nil, "The destination entry no longer exists under its original id (its identifiers now belong to entry #"..
		                           tostring(dst_id).."); roll back the later merges first"
	end
	-- The source entry was deleted at merge time; any entry with its id now is
	-- an unrelated entry that reused it, and the id cannot be restored
	if dbmanager.get_userentry(me.entry_src) then
		return nil, nil, nil, nil, "Entry id #"..tostring(me.entry_src)..
		                           " was reused by another entry after this merge; remove that entry first to roll this back"
	end
	-- Identifiers of the destination entry that were created after the merge
	-- did not exist in the pre-merge state, so their ownership is ambiguous
	local merge_ts_text = os.date("!%Y-%m-%d %H:%M:%S", me.timestamp)
	local logged = { names = {}, ips = {} }
	for _, row in ipairs(log.names) do logged.names[row.name] = true end
	for _, row in ipairs(log.ips) do logged.ips[row.ip] = true end
	local additions = {}
	local allids = dbmanager.get_identifiers_at(dst_id, nil)
	for _, row in ipairs(allids.names) do
		if not logged.names[row.name] and row.created_at > merge_ts_text then
			table.insert(additions, { type = "name", value = row.name, created_at = row.created_at })
		end
	end
	for _, row in ipairs(allids.ips) do
		if not logged.ips[row.ip] and row.created_at > merge_ts_text then
			table.insert(additions, { type = "ip", value = row.ip, created_at = row.created_at })
		end
	end
	table.sort(additions, function(a, b) return a.created_at < b.created_at end)
	return me, log, dst_id, additions
end

---@param merge_id integer
---@return { merge: MergeEventRow, log: table, dst_id: integer, additions: table[] }?
---@overload fun(merge_id: integer): nil, string
dbmanager.get_merge_rollback_info = function(merge_id)
	local me, log, dst_id, additions, err = analyze_merge(merge_id)
	if err then return nil, err end
	return { merge = me, log = log, dst_id = dst_id, additions = additions }
end

local restore_entry_stmt
-- Recreate a user entry with an explicit id and timestamps
---@param entryid integer
---@param created_at string
---@param last_seen string
dbmanager.restore_entry = function(entryid, created_at, last_seen)
	if not restore_entry_stmt then
		restore_entry_stmt = ipdb:prepare("INSERT INTO UserEntry (id, created_at, last_seen) VALUES (?, ?, ?)")
		if not restore_entry_stmt then error(ipdb:errmsg()) end
	else
		restore_entry_stmt:reset()
	end
	local ret = restore_entry_stmt:bind_values(entryid, created_at, last_seen)
	if ret ~= sqlite.OK then error(ret) end
	ret = restore_entry_stmt:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local restore_name_stmt
local restore_ip_stmt
-- Move an identifier back to the recreated entry, restoring its pre-merge
-- timestamps from the log
---@param name string
---@param entryid integer
---@param created_at string
---@param last_seen string
dbmanager.restore_name = function(name, entryid, created_at, last_seen)
	if not restore_name_stmt then
		restore_name_stmt = ipdb:prepare("UPDATE Usernames SET userentry_id = ?, created_at = ?, last_seen = ? WHERE name = ?")
		if not restore_name_stmt then error(ipdb:errmsg()) end
	else
		restore_name_stmt:reset()
	end
	local ret = restore_name_stmt:bind_values(entryid, created_at, last_seen, name)
	if ret ~= sqlite.OK then error(ret) end
	ret = restore_name_stmt:step()
	if ret ~= sqlite.DONE then error(ret) end
end

-- Move an IP back to the recreated entry, restoring its pre-merge timestamps
-- from the log
---@param ip string
---@param entryid integer
---@param created_at string
---@param last_seen string
dbmanager.restore_ip = function(ip, entryid, created_at, last_seen)
	if not restore_ip_stmt then
		restore_ip_stmt = ipdb:prepare("UPDATE IPs SET userentry_id = ?, created_at = ?, last_seen = ? WHERE ip = ?")
		if not restore_ip_stmt then error(ipdb:errmsg()) end
	else
		restore_ip_stmt:reset()
	end
	local ret = restore_ip_stmt:bind_values(entryid, created_at, last_seen, ip)
	if ret ~= sqlite.OK then error(ret) end
	ret = restore_ip_stmt:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local insert_restored_name_stmt
local insert_restored_ip_stmt
-- Re-add an identifier that was removed since the merge, using its logged
-- pre-merge timestamps
---@param entryid integer
---@param name string
---@param created_at string
---@param last_seen string
dbmanager.insert_restored_name = function(entryid, name, created_at, last_seen)
	if not insert_restored_name_stmt then
		insert_restored_name_stmt = ipdb:prepare("INSERT INTO Usernames (userentry_id, name, created_at, last_seen) VALUES (?, ?, ?, ?)")
		if not insert_restored_name_stmt then error(ipdb:errmsg()) end
	else
		insert_restored_name_stmt:reset()
	end
	local ret = insert_restored_name_stmt:bind_values(entryid, name, created_at, last_seen)
	if ret ~= sqlite.OK then error(ret) end
	ret = insert_restored_name_stmt:step()
	if ret ~= sqlite.DONE then error(ret) end
end

-- Re-add an IP that was removed since the merge, using its logged pre-merge
-- timestamps
---@param entryid integer
---@param ip string
---@param created_at string
---@param last_seen string
dbmanager.insert_restored_ip = function(entryid, ip, created_at, last_seen)
	if not insert_restored_ip_stmt then
		insert_restored_ip_stmt = ipdb:prepare("INSERT INTO IPs (userentry_id, ip, created_at, last_seen) VALUES (?, ?, ?, ?)")
		if not insert_restored_ip_stmt then error(ipdb:errmsg()) end
	else
		insert_restored_ip_stmt:reset()
	end
	local ret = insert_restored_ip_stmt:bind_values(entryid, ip, created_at, last_seen)
	if ret ~= sqlite.OK then error(ret) end
	ret = insert_restored_ip_stmt:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local mark_reverted
---@param merge_id integer
dbmanager.mark_merge_reverted = function(merge_id)
	if not mark_reverted then
		mark_reverted = ipdb:prepare("UPDATE MergeEvent SET reverted_at = unixepoch('now') WHERE id = ?")
		if not mark_reverted then error(ipdb:errmsg()) end
	else
		mark_reverted:reset()
	end
	local ret = mark_reverted:bind(1, merge_id)
	if ret ~= sqlite.OK then error(ret) end
	ret = mark_reverted:step()
	if ret ~= sqlite.DONE then error(ret) end
end

-- Roll back a merge event: recreate the absorbed entry with its original id
-- and the logged pre-merge state, and remove the merge's traces from the
-- destination entry. Identifiers of the destination created after the merge
-- are handled according to the plan: "keep" leaves them where they are,
-- "delete" removes them, "move" reassigns them to the recreated entry.
---@param merge_id integer
---@param plan table<string, string>?
---@return table?  -- report
---@overload fun(merge_id: integer, plan?: table): nil, string  -- refusal reason
dbmanager.rollback_merge = function(merge_id, plan)
	local me, log, dst_id, additions, err = analyze_merge(merge_id)
	if err then return nil, err end
	plan = plan or {}
	-- Recreate the source entry with its original id so that the merge log's
	-- references to it become live again and the history stays coherent
	local merge_ts_text = os.date("!%Y-%m-%d %H:%M:%S", me.timestamp)
	dbmanager.restore_entry(me.entry_src, merge_ts_text, merge_ts_text)
	-- Move the logged identifiers back to the recreated entry, restoring their
	-- pre-merge timestamps; identifiers removed since the merge are re-added
	local moved_names, moved_ips = 0, 0
	local restored_names, restored_ips = 0, 0
	for _, row in ipairs(log.names) do
		local live = dbmanager.user_exists(row.name)
		if live then
			dbmanager.restore_name(row.name, me.entry_src, row.created_at, row.last_seen)
			moved_names = moved_names + 1
		else
			dbmanager.insert_restored_name(me.entry_src, row.name, row.created_at, row.last_seen)
			restored_names = restored_names + 1
		end
	end
	for _, row in ipairs(log.ips) do
		local live = dbmanager.ip_exists(row.ip)
		if live then
			dbmanager.restore_ip(row.ip, me.entry_src, row.created_at, row.last_seen)
			moved_ips = moved_ips + 1
		else
			dbmanager.insert_restored_ip(me.entry_src, row.ip, row.created_at, row.last_seen)
			restored_ips = restored_ips + 1
		end
	end
	-- Deal with identifiers created after the merge according to the plan
	local del_count, move_count, keep_count = 0, 0, 0
	for _, a in ipairs(additions) do
		local action = plan[a.value]
		local live
		if action == "delete" or action == "move" then
			live = a.type == "name" and dbmanager.user_exists(a.value) or dbmanager.ip_exists(a.value)
		end
		if action == "delete" and live then
			if a.type == "name" then dbmanager.remove_name(live.id) else dbmanager.remove_ip(live.id) end
			del_count = del_count + 1
		elseif action == "move" and live then
			if a.type == "name" then dbmanager.reassociate_ids(me.entry_src, live.id) else dbmanager.reassociate_ids(me.entry_src, nil, live.id) end
			move_count = move_count + 1
		else
			keep_count = keep_count + 1
		end
	end
	-- The destination entry may have been emptied (and deleted by the cleanup
	-- triggers) while its identifiers were moved away
	local dst_alive = dbmanager.get_userentry(dst_id) ~= nil
	-- Replace the destination's modstorage of the merged mods with the logged
	-- pre-merge snapshot; the recreated entry gets its own rows back
	local modnames = {}
	local modstorage_restored = 0
	local modstorage_dst_skipped = 0
	for _, row in ipairs(log.modstorage) do
		modnames[row.modname] = true
	end
	if dst_alive then
		for modname in pairs(modnames) do
			dbmanager.delete_modstorage(dst_id, modname)
		end
	end
	for _, row in ipairs(log.modstorage) do
		local target
		if row.userentry_id == me.entry_src then
			target = me.entry_src
		else
			if not dst_alive then
				modstorage_dst_skipped = modstorage_dst_skipped + 1
				goto continue
			end
			target = dst_id
		end
		dbmanager.insert_into_modstorage(target, row.modname, row.key, row.data, row.ancillary)
		modstorage_restored = modstorage_restored + 1
		::continue::
	end
	dbmanager.mark_merge_reverted(merge_id)
	return {
		src_id = me.entry_src,
		dst_id = dst_id,
		moved_names = moved_names,
		moved_ips = moved_ips,
		restored_names = restored_names,
		restored_ips = restored_ips,
		additions_total = #additions,
		additions_deleted = del_count,
		additions_moved = move_count,
		additions_kept = keep_count,
		modstorage_restored = modstorage_restored,
		modstorage_dst_skipped = modstorage_dst_skipped,
		dst_deleted = not dst_alive,
	}
end

---@class MergeTreeNode
---@field entry_id integer
---@field live boolean
---@field kind string  -- "root", "src" or "cont"
---@field merge MergeEventRow?  -- the merge that produced this node (nil for the root)
---@field names string[]
---@field ips string[]
---@field children MergeTreeNode[]?

-- Build a node of the merge history tree for an entry: the node is the entry
-- at a point in time, its children are the absorbed entry and the entry
-- itself as it was just before the merge
---@param entryid integer
---@param min_ts_text string  -- created_at of the entry; merges older than this belong to a previous entry that had this id
---@param max_ts integer?  -- merges at or after this time are not part of the entry's past
---@param live boolean
---@param kind string
---@param edge_merge MergeEventRow?
---@param edge_log table?
---@param depth integer
---@param max_depth integer
---@return MergeTreeNode
local function build_tree_node(entryid, min_ts_text, max_ts, live, kind, edge_merge, edge_log, depth, max_depth)
	local node = {
		entry_id = entryid,
		live = live,
		kind = kind,
		merge = edge_merge,
		names = {},
		ips = {},
	}
	if kind == "root" then
		local ids = dbmanager.get_all_identifiers(entryid)
		node.names = ids.names
		node.ips = ids.ips
	elseif kind == "src" then
		for _, row in ipairs(edge_log.names) do table.insert(node.names, row.name) end
		for _, row in ipairs(edge_log.ips) do table.insert(node.ips, row.ip) end
	elseif live and edge_merge then
		local ids = dbmanager.get_identifiers_at(entryid, os.date("!%Y-%m-%d %H:%M:%S", edge_merge.timestamp))
		for _, row in ipairs(ids.names) do table.insert(node.names, row.name) end
		for _, row in ipairs(ids.ips) do table.insert(node.ips, row.ip) end
	end
	if depth >= max_depth then
		return node
	end
	local m
	if max_ts then
		m = dbmanager.get_latest_merge_before(entryid, max_ts)
	else
		m = dbmanager.get_latest_merge(entryid)
	end
	if m and live and os.date("!%Y-%m-%d %H:%M:%S", m.timestamp) < min_ts_text then
		-- The merge predates the entry itself: it belongs to a previous entry
		-- that had this id, and the entry has no history of its own
		m = nil
	end
	if not m then
		return node
	end
	local log = dbmanager.get_merge_log(m.id)
	local src_node = build_tree_node(m.entry_src, nil, m.timestamp, false, "src", m, log, depth + 1, max_depth)
	local cont_node = build_tree_node(entryid, min_ts_text, m.timestamp, live, "cont", m, log, depth + 1, max_depth)
	node.children = { src_node, cont_node }
	return node
end

-- Build the binary merge history tree for the given entry, root first
---@param entryid integer
---@param max_depth integer
---@return { root: MergeTreeNode, notes: { reused: { id: integer, created_at: string }[], older_merges: table<integer, integer> } }?
---@overload fun(entryid: integer, max_depth: integer): nil, string
dbmanager.get_merge_tree = function(entryid, max_depth)
	local entry = dbmanager.get_userentry(entryid)
	if not entry then return nil, "No such entry" end
	local root = build_tree_node(entryid, entry.created_at, nil, true, "root", nil, nil, 0, max_depth)
	local notes = { reused = {}, older_merges = {} }
	-- Any unreverted merge older than the entry itself belongs to a previous
	-- entry that had this id (id reuse); they are hidden from the tree
	local older = dbmanager.count_older_merges(entryid, entry.created_at)
	if older > 0 then notes.older_merges[entryid] = older end
	-- The same for absorbed entries along the way: collect them while walking
	local walk = { root }
	while #walk > 0 do
		local n = table.remove(walk)
		if n.kind == "src" then
			local h = dbmanager.get_userentry(n.entry_id)
			if h then
				table.insert(notes.reused, { id = n.entry_id, created_at = h.created_at })
			end
		end
		if n.children then
			table.insert(walk, n.children[1])
			table.insert(walk, n.children[2])
		end
	end
	return { root = root, notes = notes }
end

return dbmanager