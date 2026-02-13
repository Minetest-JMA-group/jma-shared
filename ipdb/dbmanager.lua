-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
local modpath = core.get_modpath(core.get_current_modname())
local dbpath = core.get_worldpath() .. "/ipdb.sqlite"
local schema_path = modpath .. "/schema.sql"
local dbmanager = {}
local ipdb
local sqlite

dbmanager.init_ipdb = function(sqlite_param)
	sqlite = sqlite_param
	local db, errcode, errmsg = sqlite.open(dbpath)
	if not db then
		core.log("error", string.format("[ipdb]: Failed to open database (%s): %s", errmsg, dbpath))
		return nil
	end
	local ret = db:exec("PRAGMA foreign_keys = ON;")
	if ret ~= sqlite.OK then
		core.log("error", "[ipdb]: Failed to enable foreign keys")
		db:close()
		return nil
	end

	local version
	for val in db:urows("PRAGMA user_version;") do
		version = val
		break
	end

	if version == 0 then
		local f = io.open(schema_path, "rb")
		if not f then
			core.log("error", "[ipdb]: Failed to open schema file: " .. schema_path)
			db:close()
			return nil
		end
		local sql = f:read("*a")
		f:close()

		if not sql or #sql == 0 then
			core.log("error", "[ipdb]: Schema file is empty or unreadable: " .. schema_path)
			db:close()
			return nil
		end

		local ret = db:exec(sql)
		if ret ~= sqlite.OK then
			core.log("error", "[ipdb]: Failed to execute schema: " .. schema_path)
			db:close()
			return nil
		end
		core.log("action", "[ipdb]: Schema applied successfully, version set to 1")
	elseif version ~= 1 then
		core.log("error", "[ipdb]: Unknown database version")
		db:close()
		return nil
	end

	ipdb = db
	return db
end

local user_check
-- Search for the given username and return the row as Lua key-value table if it exists
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

local new_entry_stmt
-- Create a new user entry and return its id
dbmanager.new_entry = function()
	if not new_entry_stmt then
		new_entry_stmt = ipdb:prepare("INSERT INTO UserEntry (last_seen) VALUES (CURRENT_TIMESTAMP);")
	else
		new_entry_stmt:reset()
	end
	local ret = new_entry_stmt:step()
	if ret ~= sqlite.DONE then error(ret) end
	return new_entry_stmt:last_insert_rowid()
end

local update_entry_time
local update_name_time
local update_ip_time
-- Update last_seen time for given entries
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

local set_no_newentries
local get_no_newentries
dbmanager.no_newentries = function(newval)
	if newval ~= nil then
		if not set_no_newentries then
			set_no_newentries = ipdb:prepare("UPDATE Metadata SET value = ? WHERE key = 'no_new_entries'")
		else
			set_no_newentries:reset()
		end
		newval = newval and "true" or "false"
		local ret = set_no_newentries:bind(1, newval)
		if ret ~= sqlite.OK then error(ret) end
		ret = set_no_newentries:step()
		if ret ~= sqlite.DONE then error(ret) end
	else
		if not get_no_newentries then
			get_no_newentries = ipdb:prepare("SELECT value FROM Metadata WHERE key = 'no_new_entries'")
		else
			get_no_newentries:reset()
		end
		local ret = get_no_newentries:step()
		if ret ~= sqlite.ROW then error(ret) end
		local no_newentries = get_no_newentries:get_value(0)
		return no_newentries == "true"
	end
end

local set_merge_perm
-- Set no_merging flag in entry
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
	return blocked_count == 0
end

local remove_ip
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
dbmanager.reassociate = function(newentryid, nameid, ipid)
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
local modstorage_insert_stmt = [[INSERT INTO Modstorage (userentry_id, modname, key, data)
VALUES (?, ?, ?, ?)
ON CONFLICT(userentry_id, modname, key) 
DO UPDATE SET data = excluded.data]]
-- Insert a value into modstorage table, potentially replacing the old one
dbmanager.insert_into_modstorage = function(userentry_id, modname, key, value)
	if not modstorage_insert then
		modstorage_insert = ipdb:prepare(modstorage_insert_stmt)
	else
		modstorage_insert:reset()
	end
	local ret = modstorage_insert:bind_values(userentry_id, modname, key, value)
	if ret ~= sqlite.OK then error(ret) end
	ret = modstorage_insert:step()
	if ret ~= sqlite.DONE then error(ret) end
end

local modstorage_get
-- Get the value associated with the given key in modstorage table
dbmanager.get_from_modstorage = function(userentry_id, modname, key)
	if not modstorage_get then
		modstorage_get = ipdb:prepare("SELECT data FROM Modstorage WHERE userentry_id = ? AND modname = ? AND key = ?")
	else
		modstorage_get:reset()
	end
	local ret = modstorage_get:bind_values(userentry_id, modname, key)
	if ret ~= sqlite.OK then error(ret) end

	ret = modstorage_get:step()
	if ret == sqlite.DONE then return nil end
	if ret ~= sqlite.ROW then error(ret) end
	return modstorage_get:get_value(0)
end

local modstorage_get_all
-- Get all key-value pairs associated with given user entry and modname
dbmanager.get_all_modstorage = function(userentry_id, modname)
    if not modstorage_get_all then
        modstorage_get_all = ipdb:prepare("SELECT key, data FROM Modstorage WHERE userentry_id = ? AND modname = ?")
    else
        modstorage_get_all:reset()
    end

    local ret = modstorage_get_all:bind_values(userentry_id, modname)
    if ret ~= sqlite.OK then error(ret) end

    local results = {}
    while true do
        ret = modstorage_get_all:step()
        if ret == sqlite.DONE then
            break
        elseif ret ~= sqlite.ROW then
            error(ret)
        end
        local key = modstorage_get_all:get_value(0)
        local data = modstorage_get_all:get_value(1)
        results[key] = data
    end

    return results
end

local modstorage_update
-- Reassociate modstorage to a new entry
dbmanager.update_modstorage = function(modname, old_userentry_id, new_userentry_id)
    if not modstorage_update then
        modstorage_update = ipdb:prepare("UPDATE Modstorage SET userentry_id = ? WHERE userentry_id = ? AND modname = ?")
    else
        modstorage_update:reset()
    end

    local ret = modstorage_update:bind_values(new_userentry_id, old_userentry_id, modname)
    if ret ~= sqlite.OK then error(ret) end

    ret = modstorage_update:step()
    if ret ~= sqlite.DONE then error(ret) end
end

local modstorage_delete_one
local modstorage_delete_all
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

return dbmanager