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
	local migrations = { [0] = {num = 1, file = modpath.."/schema.sqlite"} }
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
	return true
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
		local try_meta = dbmanager.get_meta("db_version")
		if try_meta then
			version = tonumber(try_meta)
		end
	end
	if not run_migration(db, version) then
		db:exec("ROLLBACK")
		db:close()
		return nil
	end

	ipdb = db
	return db
end

local user_check
-- Search for the given username and return the row as Lua key-value table if it exists
---@param username string
---@return UsernameEntity?
dbmanager.user_exists = function(username)
	if not user_check then
		user_check = ipdb:prepare("SELECT * FROM Usernames WHERE name = ?;")
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
	else
		remove_name:reset()
	end
	local ret = remove_name:bind(1, nameid)
	if ret ~= sqlite.OK then error(ret) end
	ret = remove_name:step()
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
---@param aux string?
dbmanager.insert_into_modstorage = function(userentry_id, modname, key, value, aux)
	if not modstorage_insert then
		modstorage_insert = ipdb:prepare("INSERT INTO Modstorage (userentry_id, modname, key, data, auxiliary) "..
	                                     "VALUES (?, ?, ?, ?, ?)")
	else
		modstorage_insert:reset()
	end
	local ret = modstorage_insert:bind_values(userentry_id, modname, key, value)
	if ret ~= sqlite.OK then error(ret) end
	ret = modstorage_insert:bind(5, aux)
	if ret ~= sqlite.OK then error(ret) end
	ret = modstorage_insert:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local modstorage_get
local modstorage_get_all
-- Get the values associated with the given key in modstorage table
---@param userentry_id integer
---@param modname string
---@param key string
---@param limit integer?
---@return table<integer, string>
dbmanager.get_from_modstorage = function(userentry_id, modname, key, limit)
	local mystmt
	local ret
	if limit then
		if not modstorage_get then
			modstorage_get = ipdb:prepare("SELECT id, data FROM Modstorage WHERE userentry_id = ? AND modname = ? "..
			                              "AND key = ? LIMIT ?")
		else
			modstorage_get:reset()
		end
		ret = modstorage_get:bind_values(userentry_id, modname, key, limit)
		mystmt = modstorage_get
	else
		if not modstorage_get_all then
			modstorage_get_all = ipdb:prepare("SELECT id, data FROM Modstorage WHERE userentry_id = ? AND modname = ? "..
			                                  "AND key = ?")
		else
			modstorage_get_all:reset()
		end
		ret = modstorage_get_all:bind_values(userentry_id, modname, key)
		mystmt = modstorage_get_all
	end
	if ret ~= sqlite.OK then error(ret) end

	local values = {}
	ret = mystmt:step()
	while ret == sqlite.ROW do
		local id = mystmt:get_value(0)
		local data = mystmt:get_value(1)
		values[id] = data
		ret = mystmt:step()
	end
	if ret ~= sqlite.DONE then error(ret) end
	return values
end

local update_modstorage1
-- Update a value identified by modstorage_id
---@param modstorage_id integer
---@param value string
---@param aux string?
dbmanager.update_modstorage1 = function(modstorage_id, value, aux)
	if not update_modstorage1 then
		update_modstorage1 = ipdb:prepare("UPDATE Modstorage SET data = ?, auxiliary = ? WHERE id = ?")
	else
		update_modstorage1:reset()
	end
	local ret = update_modstorage1:bind_values(value, aux, modstorage_id)
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
---@param aux string?
dbmanager.update_modstorage2 = function(userentry_id, modname, key, value, aux)
	if not update_modstorage2 then
		update_modstorage2 = ipdb:prepare("UPDATE Modstorage SET data = ?, auxiliary = ? WHERE userentry_id = ? "..
		                                  "AND modname = ? AND KEY = ?")
	else
		update_modstorage2:reset()
	end
	local ret = update_modstorage2:bind_values(value, aux, userentry_id, modname, key)
	if ret ~= sqlite.OK then error(ret) end
	ret = update_modstorage2:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local modstorage_get_all
-- Get all key-value pairs associated with given user entry and modname
---@param userentry_id integer
---@param modname string
---@return table<string, string|table<integer, string>>
dbmanager.get_all_modstorage = function(userentry_id, modname)
	if not modstorage_get_all then
		modstorage_get_all = ipdb:prepare("SELECT key, data, id FROM Modstorage WHERE userentry_id = ? AND modname = ?")
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

local reassociate_modstorage
-- Reassociate modstorage to a new entry
---@param modname string
---@param old_userentry_id integer
---@param new_userentry_id integer
dbmanager.reassociate_modstorage = function(modname, old_userentry_id, new_userentry_id)
	if not reassociate_modstorage then
		reassociate_modstorage = ipdb:prepare("UPDATE Modstorage SET userentry_id = ? WHERE userentry_id = ? "..
		                                      "AND modname = ?")
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
local log_modstorage_stmt = [[INSERT INTO Modstorage_log (modname, userentry_id, key, data, auxiliary, merge_id)
SELECT modname, userentry_id, key, data, auxiliary, ?
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
	else
		new_merge:reset()
	end
	if not log_modstorage then
		log_modstorage = ipdb:prepare(log_modstorage_stmt)
	else
		log_modstorage:reset()
	end
	if not log_usernames then
		log_usernames = ipdb:prepare(log_usernames_stmt)
	else
		log_usernames:reset()
	end
	if not log_ips then
		log_ips = ipdb:prepare(log_ips_stmt)
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
	else
		prune_merge:reset()
	end
	local ret = prune_merge:bind(1, max_age)
	if ret ~= sqlite.OK then error(ret) end
	ret = prune_merge:step()
	if ret ~= sqlite.DONE then error(ret) end
end

return dbmanager