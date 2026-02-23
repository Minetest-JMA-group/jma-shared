-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local host = core.settings:get("shareddb.host") or "localhost"
local port = tonumber(core.settings:get("shareddb.port") or "5432")
local user = core.settings:get("shareddb.user") or "postgres"
local password = core.settings:get("shareddb.password") or ""
local dbname = core.settings:get("shareddb.database") or "shareddb"
local conn
local transaction_active = false
local listeners = {}
local listening = false
shareddb = {}

local dummy = function() return nil, "shareddb not available" end
local dummy_obj = { get_context = dummy }
shareddb.get_mod_storage = function() return dummy_obj end
shareddb.register_listener = dummy

local pg = algorithms.require("pgsql")
if not pg then
	core.log("error", "[shareddb] Failed to load luapgsql")
	return
end

local function disable(reason)
	core.log("error", "[shareddb] Disabling mod: " .. reason)
	if conn then conn:finish(); conn = nil end
end

local function connect()
	local conn_str = string.format("host=%s port=%d user=%s password=%s dbname=%s",
		host, port, user, password, dbname)
	return pg.connectdb(conn_str)
end

local function ensure_connection()
	if conn and conn:status() == pg.CONNECTION_OK then
		return true
	end

	transaction_active = false
	listening = false
	if conn then
		conn:finish()
		conn = nil
	end

	conn = connect()
	if not conn then
		return nil, "Failed to create connection object"
	end
	if conn:status() ~= pg.CONNECTION_OK then
		local err = conn:errorMessage()
		conn:finish()
		conn = nil
		return nil, "Reconnect failed: " .. err
	end

	core.log("action", "[shareddb] Reconnected to PostgreSQL")
	return true
end

local function exec_sql(sql, params)
	local ok, err = ensure_connection()
	if not ok then return nil, err end

	local res
	if params and #params > 0 then
		res = conn:execParams(sql, unpack(params))
	else
		res = conn:exec(sql)
	end
	if not res then return nil, conn:errorMessage() end
	if res:status() == pg.PGRES_FATAL_ERROR then
		return nil, res:errorMessage()
	end
	return res
end

local function ensure_listening()
	if listening then return true end
	local res, err = exec_sql("LISTEN shareddb_changed")
	if not res then
		core.log("error", "[shareddb] Failed to LISTEN: " .. err)
		return false
	end
	listening = true
	return true
end

local function init_database()
	local res, err = exec_sql([[
		SELECT EXISTS (
			SELECT 1 FROM information_schema.tables WHERE table_name = 'modstorage'
		) AS exists
	]])
	if not res then return nil, "Failed to check table existence: " .. err end
	local exists = res:getvalue(1, 1) == "t"

	if not exists then
		return nil, "Database schema not applied. Please apply schema manually."
	end

	return true
end

conn = connect()
if conn:status() ~= pg.CONNECTION_OK then
    local err = conn:errorMessage()
    disable("Connection failed: " .. err)
    return
end

local ok, err = init_database()
if not ok then
	disable("Database initialization failed: " .. err)
	return
end

if not ensure_listening() then
	disable("Failed to LISTEN on startup")
	return
end

core.log("action", "[shareddb] Connected to PostgreSQL and initialized")

local function poll_notifications()
	if not ensure_connection() then return end
	if not ensure_listening() then return end

	-- Read any incoming data from PostgreSQL
    local ok = conn:consumeInput()
    if not ok then
        core.log("error", "[shareddb] consumeInput failed: " .. conn:errorMessage())
        return
    end

	while true do
		local n = conn:notifies()
		if not n then break end
		if n:relname() == "shareddb_changed" then
			local payload = n:extra()
			if payload then
				local modname, key = payload:match("^([^\n]+)\n(.+)$")
				if modname and key then
					local listener = listeners[modname]
					if listener then listener(key) end
				else
					core.log("warning", "[shareddb] Invalid notification payload: " .. payload)
				end
			end
		end
	end
end

core.register_globalstep(poll_notifications)

local function modstorage_set_string(self, key, value)
	if not self._active then return nil, "Transaction not active" end
	if type(key) ~= "string" then return nil, "key must be string" end
	if value ~= nil and type(value) ~= "string" then return nil, "value must be string or nil" end

	local sql, params
	if value == nil then
		sql = "DELETE FROM Modstorage WHERE modname = $1 AND key = $2"
		params = {self._modname, key}
	else
		sql = [[
			INSERT INTO Modstorage (modname, key, value)
			VALUES ($1, $2, $3)
			ON CONFLICT (modname, key) DO UPDATE SET value = EXCLUDED.value
		]]
		params = {self._modname, key, value}
	end

	local res, err = exec_sql(sql, params)
	if not res then
		conn:exec("ROLLBACK")
		self._active = false
		transaction_active = false
		core.log("error", "[shareddb] set_string failed: " .. err)
		return nil, "Database error"
	end
	return true
end

local function modstorage_get_string(self, key)
	if not self._active then return nil, "Transaction not active" end
	if type(key) ~= "string" then return nil, "key must be string" end

	local res, err = exec_sql("SELECT value FROM Modstorage WHERE modname = $1 AND key = $2",
		{self._modname, key})
	if not res then
		conn:exec("ROLLBACK")
		self._active = false
		transaction_active = false
		core.log("error", "[shareddb] get_string failed: " .. err)
		return nil, "Database error"
	end

	if res:ntuples() == 0 then return nil
	else return res:getvalue(1, 1) end
end

local function modstorage_finalize(self)
	if not self._active then return true end
	local ok, err = exec_sql("COMMIT")
	self._active = false
	transaction_active = false
	if not ok then
		core.log("error", "[shareddb] COMMIT failed: " .. err)
		conn:exec("ROLLBACK")
		return nil, "Commit failed"
	end
	return true
end

local function start_transaction(self)
	local ok, err = ensure_connection()
	if not ok then return nil, err end

	if transaction_active then
		return nil, "Another transaction is already active"
	end

	local ok, err = exec_sql("BEGIN")
	if not ok then
		core.log("error", "[shareddb] BEGIN failed: " .. err)
		return nil, "Failed to start transaction"
	end
	transaction_active = true

	local ctx = {
		_modname = self._modname,
		_active = true,
		set_string = modstorage_set_string,
		get_string = modstorage_get_string,
		finalize = modstorage_finalize,
	}
	setmetatable(ctx, { __gc = modstorage_finalize })
	return ctx
end

shareddb.get_mod_storage = function()
	local modname = core.get_current_modname()
	if not modname then
		core.log("error", "[shareddb] get_mod_storage called outside of load time")
		return nil, "Must be called at load time"
	end

	local modstorage_obj = {
		_modname = modname,
		get_context = start_transaction
	}
	return modstorage_obj
end

shareddb.register_listener = function(listener)
	local modname = core.get_current_modname()
	if not modname then
		core.log("error", "[shareddb] register_listener called outside of load time")
		return nil, "Must be called at load time"
	end
	if type(listener) ~= "function" then return nil, "Listener must be a function" end
	listeners[modname] = listener
	return true
end