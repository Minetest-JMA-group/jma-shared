-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Database layer of the recorder mod: owns the SQLite connection of the
-- recording in progress, its schema, and the rows waiting to be written.
--
-- Recording has to stay off the server's critical path: the callbacks that
-- feed it have to return at once, so nothing here may commit per action, and
-- a commit is a disk synchronization. Callbacks only append rows to the
-- buffers here; a globalstep hands the whole batch to SQLite in one
-- transaction a few times a second.
--
-- Rows of both tables take their id from one shared sequence (next_id), which
-- is what makes the order of events and movement samples recoverable from the
-- two tables together - see the Timeline view in schema.sql. Ids are therefore
-- assigned when a row is buffered, not when it is written.

local modpath = core.get_modpath(core.get_current_modname())
local unpack = table.unpack or unpack

-- Rows are positional arrays in column order. They may hold nils (the NULL
-- columns), so their length has to come from here: # on a table with holes is
-- the length of neither its head nor its tail, and unpack would bind the wrong
-- number of parameters.
local EVENT_COLUMNS = 13
local MOVEMENT_COLUMNS = 20

-- What schema.sql puts in PRAGMA application_id ('JMAR'), and what tells a
-- recorder file apart from any other database.
local APPLICATION_ID = 0x4A4D4152

-- How long a statement waits for a lock before it gives up. See open().
local BUSY_TIMEOUT_MS = 250

---@class DBManager
local dbmanager = {}

local sqlite ---@type table
local db ---@type userdata?  -- connection of the recording in progress

local seq = 0          -- id handed out last; shared by Events and Movement
local events = {}      -- buffered Events rows, in recording order
local movement = {}    -- buffered Movement rows, in recording order
local player_ids = {}  -- player name -> Players.id
local failed = 0       -- consecutive failed flushes
local dropped = 0      -- rows lost to failed flushes
local written = { events = 0, movement = 0, players = 0 }
local in_transaction = false

local insert_player, insert_event, insert_movement, set_meta_stmt, get_meta_stmt

local function errmsg(where)
	return string.format("%s: %s", where, tostring(db and db:errmsg()))
end

-- Hand the module the lsqlite3 library the mod loaded. The connection itself
-- belongs to a recording and comes and goes with it.
---@param sqlite_lib table
---@return boolean|nil, string?
dbmanager.init = function(sqlite_lib)
	if sqlite then
		return nil, "dbmanager.init called more than once"
	end
	sqlite = sqlite_lib
	return true
end

-- Run a statement that returns no rows of interest
local function exec(sql)
	local ret = db:exec(sql)
	if ret ~= sqlite.OK then
		return nil, string.format("cannot execute '%s' (%i): %s", sql, ret, tostring(db:errmsg()))
	end
	return true
end

local function apply_schema()
	local path = modpath .. "/schema.sql"
	local f = io.open(path, "rb")
	if not f then
		return nil, "cannot open " .. path
	end
	local sql = f:read("*a")
	f:close()
	if not sql or #sql == 0 then
		return nil, "schema file is empty or unreadable: " .. path
	end
	local ret = db:exec(sql)
	if ret ~= sqlite.OK then
		return nil, string.format("cannot apply %s (%i): %s", path, ret, tostring(db:errmsg()))
	end
	return true
end

local function prepare_statement(sql)
	local stmt = db:prepare(sql)
	if not stmt then
		return nil, errmsg("cannot prepare statement")
	end
	return stmt
end

-- Open a fresh recording file. Passing a database that already holds something
-- is an error: recordings are never appended to, and silently writing into
-- someone else's file would be the worst way to find out.
---@param path string
---@return boolean|nil, string?
dbmanager.open = function(path)
	if not sqlite then
		return nil, "no SQLite library: dbmanager.init was not called"
	end
	if db then
		return nil, "a recording database is already open"
	end
	local handle, err1, err2 = sqlite.open(path)
	if not handle then
		-- lsqlite3 hands back either (nil, errmsg) or (nil, errcode, errmsg)
		return nil, string.format("cannot open %s: %s", path, tostring(err2 or err1))
	end

	-- Everything below, and every statement run later, waits for a lock instead
	-- of failing outright - but not for long: this runs inside a server step,
	-- and a step that stops for a second is worse for the players than a batch
	-- of rows given up on. Readers never hold us up (WAL), so this is only
	-- about another writer.
	handle:busy_timeout(BUSY_TIMEOUT_MS)
	db = handle

	-- Reading the file is also the first thing that touches it, and what it
	-- says about itself is what tells a fresh recording from a database that
	-- is already something - ours or somebody else's. Writing a schema into a
	-- database that belongs to another mod would be the worst way to find out.
	local read_ok, version, app_id, objects = pcall(function()
		local v, app, count = 0, 0, 0
		for row in db:urows("PRAGMA user_version;") do v = row end
		for row in db:urows("PRAGMA application_id;") do app = row end
		for row in db:urows("SELECT COUNT(*) FROM sqlite_master;") do count = row end
		return v, app, count
	end)
	if not read_ok then
		db:close() db = nil
		return nil, path .. " is not a SQLite database"
	end
	if app_id == APPLICATION_ID or version ~= 0 then
		db:close() db = nil
		return nil, string.format("%s already holds a recording (schema version %d)", path, version)
	end
	if app_id ~= 0 or objects ~= 0 then
		db:close() db = nil
		return nil, string.format("%s is not empty: it holds %d object(s) that the recorder did not put there",
			path, objects)
	end

	-- WAL keeps a query running against the live recording from blocking the
	-- recording itself; it is checkpointed away by close(). On top of that,
	-- NORMAL is the right durability trade for a recording: a crash can lose
	-- the last batch of rows, but never the file.
	local ok, err = exec("PRAGMA journal_mode = WAL")
	if not ok then db:close() db = nil return nil, err end
	ok, err = exec("PRAGMA synchronous = NORMAL")
	if not ok then db:close() db = nil return nil, err end
	ok, err = exec("PRAGMA foreign_keys = ON")
	if not ok then db:close() db = nil return nil, err end

	ok, err = apply_schema()
	if not ok then db:close() db = nil return nil, err end

	local stmt, serr = prepare_statement("INSERT INTO Players (name) VALUES (?)")
	if not stmt then db:close() db = nil return nil, serr end
	insert_player = stmt
	stmt, serr = prepare_statement("INSERT INTO Events (id, tick, t, type, subject_player, " ..
		"object_player, pos_x, pos_y, pos_z, node, param2, item, data) " ..
		"VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
	if not stmt then db:close() db = nil return nil, serr end
	insert_event = stmt
	stmt, serr = prepare_statement("INSERT INTO Movement (id, tick, t, dtime, player_id, " ..
		"pos_x, pos_y, pos_z, pitch, yaw, vel_x, vel_y, vel_z, acc_x, acc_y, acc_z, " ..
		"speed, controls, move_x, move_y) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
	if not stmt then db:close() db = nil return nil, serr end
	insert_movement = stmt
	stmt, serr = prepare_statement("INSERT OR REPLACE INTO Metadata (key, value) VALUES (?, ?)")
	if not stmt then db:close() db = nil return nil, serr end
	set_meta_stmt = stmt
	stmt, serr = prepare_statement("SELECT value FROM Metadata WHERE key = ?")
	if not stmt then db:close() db = nil return nil, serr end
	get_meta_stmt = stmt

	seq, failed, dropped, in_transaction = 0, 0, 0, false
	events, movement, player_ids = {}, {}, {}
	written = { events = 0, movement = 0, players = 0 }
	return true
end

---@return boolean
dbmanager.is_open = function()
	return db ~= nil
end

-- Fold the write-ahead log back into the main file, so a finished recording is
-- the single .sqlite file it looks like. A connection that is still reading the
-- recording holds that back (WAL is what lets it read while the recorder
-- writes, so this is a normal thing to meet): the pages stay in the -wal, and
-- whoever takes the file away has to take that with it.
local function checkpoint()
	local stmt = db:prepare("PRAGMA wal_checkpoint(TRUNCATE)")
	if not stmt then
		return false, tostring(db:errmsg())
	end
	local busy, err
	if stmt:step() == sqlite.ROW then
		busy = stmt:get_value(0)  -- lsqlite3 counts result columns from 0
	end
	stmt:reset()
	stmt:finalize()
	if busy == nil then
		return false, tostring(db:errmsg())
	end
	if busy ~= 0 then
		err = "another connection is using the recording, so its write-ahead log could not be" ..
			" folded back into the file"
	end
	return busy == 0, err
end

dbmanager.close = function()
	if not db then
		return nil, "no recording database is open"
	end
	local ok, err = dbmanager.flush()
	-- Let SQLite refresh the planner statistics for whoever reads the file
	-- later, and fold the log back in.
	db:exec("PRAGMA optimize;")
	local checkpointed, checkpoint_err = checkpoint()
	if not checkpointed then
		core.log("warning", "[recorder] " .. tostring(checkpoint_err) ..
			"; keep the -wal file next to it or open the database once")
	end
	db:close()
	db = nil
	insert_player, insert_event, insert_movement, set_meta_stmt, get_meta_stmt = nil, nil, nil, nil, nil
	player_ids = {}
	events, movement = {}, {}
	in_transaction = false
	return ok, err
end

-- Ids are handed out while buffering, so they reflect the order in which
-- things happened rather than the order in which they reach SQLite.
---@return integer
dbmanager.next_id = function()
	seq = seq + 1
	return seq
end

-- Id of the player with this name, creating their row on first sight.
--
-- A row that cannot be written is retried the next time the player is seen
-- rather than remembered as a lost cause: a database that was busy for a
-- moment must not cost the recording a player for the rest of its length. The
-- caller is told about each failure and decides how often to say so.
---@param name string
---@return integer|nil, string?
dbmanager.player_id = function(name)
	local id = player_ids[name]
	if id then
		return id
	end
	local ret = insert_player:bind_values(name)
	if ret ~= sqlite.OK then
		insert_player:reset()
		return nil, "cannot add player " .. name .. ": " .. tostring(db:errmsg())
	end
	ret = insert_player:step()
	if ret ~= sqlite.DONE then
		local err = "cannot add player " .. name .. ": " .. tostring(db:errmsg())
		insert_player:reset()
		return nil, err
	end
	id = insert_player:last_insert_rowid()
	insert_player:reset()
	player_ids[name] = id
	written.players = written.players + 1
	return id
end

---@param row table  -- an Events row, in column order, ids included
dbmanager.add_event = function(row)
	events[#events + 1] = row
end

---@param row table  -- a Movement row, in column order, ids included
dbmanager.add_movement = function(row)
	movement[#movement + 1] = row
end

---@return integer
dbmanager.buffered = function()
	return #events + #movement
end

---@return table
dbmanager.stats = function()
	return {
		players = written.players,
		events = written.events,
		movement = written.movement,
		buffered = #events + #movement,
		dropped = dropped,
		failed = failed,
	}
end

local function insert_row(stmt, row, columns)
	local ret = stmt:bind_values(unpack(row, 1, columns))
	if ret ~= sqlite.OK then
		return nil, errmsg("cannot bind row")
	end
	ret = stmt:step()
	if ret ~= sqlite.DONE then
		return nil, errmsg("cannot insert row")
	end
	return true
end

local function insert_rows(stmt, rows, count, columns)
	for i = 1, count do
		-- Bind and step under pcall: lsqlite3 raises rather than returning a
		-- code for a value it cannot bind, and that raise would unwind out of
		-- the caller's transaction, leaving it open forever.
		local raised, done, err = pcall(insert_row, stmt, rows[i], columns)
		stmt:reset()
		if not raised then
			return nil, "cannot insert row: " .. tostring(done)
		end
		if not done then
			return nil, err
		end
	end
	return true
end

-- Write everything buffered so far in one transaction.
--
-- A batch that cannot be written is dropped: keeping it for a retry would grow
-- the buffer without bound for as long as the disk stays full. The caller is
-- told how many rows were lost so it can put a marker in the recording; the
-- counters here let it report the total at the end.
---@return boolean|nil, string?, integer?  -- ok, error, rows dropped
dbmanager.flush = function()
	if not db then
		return nil, "no recording database is open"
	end
	local nevents, nmovement = #events, #movement
	if nevents == 0 and nmovement == 0 then
		-- Nothing to write, but the run of failures (if any) ends here.
		failed = 0
		return true
	end
	if in_transaction then
		return nil, "a transaction is already open"
	end

	local ret = db:exec("BEGIN")
	if ret ~= sqlite.OK then
		return nil, errmsg("cannot start a transaction")
	end
	in_transaction = true

	-- Which of the two tables has rows in a given batch is up to the server: a
	-- batch of movement with no events at all is the ordinary case, so the
	-- insert of one table may not be conditional on the other having run.
	local ok, err = true, nil
	if nevents > 0 then
		ok, err = insert_rows(insert_event, events, nevents, EVENT_COLUMNS)
	end
	if ok and nmovement > 0 then
		ok, err = insert_rows(insert_movement, movement, nmovement, MOVEMENT_COLUMNS)
	end

	if ok then
		ret = db:exec("COMMIT")
		if ret ~= sqlite.OK then
			err = errmsg("cannot commit")
			ok = nil
		end
	end

	if ok then
		in_transaction = false
		written.events = written.events + nevents
		written.movement = written.movement + nmovement
		failed = 0
		events, movement = {}, {}
		return true
	end

	db:exec("ROLLBACK")
	in_transaction = false
	local lost = nevents + nmovement
	dropped = dropped + lost
	failed = failed + 1
	events, movement = {}, {}
	return nil, err, lost
end

---@param key string
---@param value string
---@return boolean|nil, string?
dbmanager.set_meta = function(key, value)
	local ret = set_meta_stmt:bind_values(key, value)
	if ret ~= sqlite.OK then
		return nil, errmsg("cannot bind metadata")
	end
	ret = set_meta_stmt:step()
	if ret ~= sqlite.DONE then
		local err = errmsg("cannot write metadata")
		set_meta_stmt:reset()
		return nil, err
	end
	set_meta_stmt:reset()
	return true
end

---@param key string
---@return string|nil, string?
dbmanager.get_meta = function(key)
	local ret = get_meta_stmt:bind_values(key)
	if ret ~= sqlite.OK then
		return nil, errmsg("cannot bind metadata query")
	end
	ret = get_meta_stmt:step()
	if ret == sqlite.ROW then
		-- lsqlite3 counts result columns from 0, whatever bind() does
		local value = get_meta_stmt:get_value(0)
		get_meta_stmt:reset()
		return value
	end
	get_meta_stmt:reset()
	if ret ~= sqlite.DONE then
		return nil, errmsg("cannot read metadata")
	end
	return nil
end

return dbmanager
