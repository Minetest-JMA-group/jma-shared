-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Database layer of one recording: it owns the SQLite connection, the schema,
-- and the rows waiting to be written. One instance per recording, so several
-- recordings can be written at once - they are separate files, and therefore
-- separate connections.
--
-- Recording has to stay off the server's critical path: the callbacks that feed
-- it have to return at once, so nothing here may commit per action, and a
-- commit is a disk synchronization. Callbacks only append rows to the buffers
-- here; a globalstep hands the whole batch to SQLite in one transaction a few
-- times a second.
--
-- Rows of both tables take their id from one shared sequence (next_id), which
-- is what makes the order of events and movement samples recoverable from the
-- two tables together - see the Timeline view in schema.sql. Ids are therefore
-- assigned when a row is buffered, not when it is written.

local dbmanager = {}

local modpath = core.get_modpath("recorder_capture")
local unpack = table.unpack or unpack

-- Rows are positional arrays in column order. They may hold nils (the NULL
-- columns), so their length has to come from here: # on a table with holes is
-- the length of neither its head nor its tail, and unpack would bind the wrong
-- number of parameters.
local EVENT_COLUMNS = 13
local MOVEMENT_COLUMNS = 20

-- What schema.sql puts in PRAGMA application_id ('JMAR'), and what tells a
-- recorder file apart from any other database. The same value is in
-- recorder_common, which is what a reader checks before trusting a file.
local APPLICATION_ID = recorder_common.APPLICATION_ID

-- How long a statement waits for a lock before it gives up. See open().
local BUSY_TIMEOUT_MS = 250

local DB = {}
DB.__index = DB

-- One connection's worth of state, waiting for open(). The SQLite library is
-- handed in rather than loaded here, so a test can substitute a stand-in.
---@param sqlite_lib table
---@return table
function dbmanager.new(sqlite_lib)
	return setmetatable({
		sqlite = sqlite_lib,
		db = nil,
		seq = 0,            -- id handed out last; shared by Events and Movement
		events = {},        -- buffered Events rows, in recording order
		movement = {},      -- buffered Movement rows, in recording order
		player_ids = {},    -- player name -> Players.id
		failed = 0,         -- consecutive failed flushes
		dropped = 0,        -- rows lost to failed flushes
		written = {events = 0, movement = 0, players = 0},
		in_transaction = false,
	}, DB)
end

local function errmsg(self, where)
	return string.format("%s: %s", where, tostring(self.db and self.db:errmsg()))
end

-- Run a statement that returns no rows of interest
local function exec(self, sql)
	local ret = self.db:exec(sql)
	if ret ~= self.sqlite.OK then
		return nil, string.format("cannot execute '%s' (%i): %s", sql, ret, tostring(self.db:errmsg()))
	end
	return true
end

local function apply_schema(self)
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
	local ret = self.db:exec(sql)
	if ret ~= self.sqlite.OK then
		return nil, string.format("cannot apply %s (%i): %s", path, ret, tostring(self.db:errmsg()))
	end
	return true
end

local function prepare_statement(self, sql)
	local stmt = self.db:prepare(sql)
	if not stmt then
		return nil, errmsg(self, "cannot prepare statement")
	end
	return stmt
end

-- Open a fresh recording file. Passing a database that already holds something
-- is an error: recordings are never appended to, and silently writing into
-- someone else's file would be the worst way to find out.
---@param path string
---@return boolean|nil, string?
function DB:open(path)
	if self.db then
		return nil, "a recording database is already open"
	end
	local handle, err1, err2 = self.sqlite.open(path)
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
	self.db = handle

	-- Reading the file is also the first thing that touches it, and what it
	-- says about itself is what tells a fresh recording from a database that
	-- is already something - ours or somebody else's. Writing a schema into a
	-- database that belongs to another mod would be the worst way to find out.
	local read_ok, version, app_id, objects = pcall(function()
		local v, app, count = 0, 0, 0
		for row in self.db:urows("PRAGMA user_version;") do v = row end
		for row in self.db:urows("PRAGMA application_id;") do app = row end
		for row in self.db:urows("SELECT COUNT(*) FROM sqlite_master;") do count = row end
		return v, app, count
	end)
	if not read_ok then
		self.db:close() self.db = nil
		return nil, path .. " is not a SQLite database"
	end
	if app_id == APPLICATION_ID or version ~= 0 then
		self.db:close() self.db = nil
		return nil, string.format("%s already holds a recording (schema version %d)", path, version)
	end
	if app_id ~= 0 or objects ~= 0 then
		self.db:close() self.db = nil
		return nil, string.format("%s is not empty: it holds %d object(s) that the recorder did not put there",
			path, objects)
	end

	-- WAL keeps a query running against the live recording from blocking the
	-- recording itself; it is checkpointed away by close(). On top of that,
	-- NORMAL is the right durability trade for a recording: a crash can lose
	-- the last batch of rows, but never the file.
	local ok, err = exec(self, "PRAGMA journal_mode = WAL")
	if not ok then self.db:close() self.db = nil return nil, err end
	ok, err = exec(self, "PRAGMA synchronous = NORMAL")
	if not ok then self.db:close() self.db = nil return nil, err end
	ok, err = exec(self, "PRAGMA foreign_keys = ON")
	if not ok then self.db:close() self.db = nil return nil, err end

	ok, err = apply_schema(self)
	if not ok then self.db:close() self.db = nil return nil, err end

	local stmt, serr = prepare_statement(self, "INSERT INTO Players (name) VALUES (?)")
	if not stmt then self.db:close() self.db = nil return nil, serr end
	self.insert_player = stmt
	stmt, serr = prepare_statement(self, "INSERT INTO Events (id, tick, t, type, subject_player, " ..
		"object_player, pos_x, pos_y, pos_z, node, param2, item, data) " ..
		"VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
	if not stmt then self.db:close() self.db = nil return nil, serr end
	self.insert_event = stmt
	stmt, serr = prepare_statement(self, "INSERT INTO Movement (id, tick, t, dtime, player_id, " ..
		"pos_x, pos_y, pos_z, pitch, yaw, vel_x, vel_y, vel_z, acc_x, acc_y, acc_z, " ..
		"speed, controls, move_x, move_y) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
	if not stmt then self.db:close() self.db = nil return nil, serr end
	self.insert_movement = stmt
	stmt, serr = prepare_statement(self, "INSERT OR REPLACE INTO Metadata (key, value) VALUES (?, ?)")
	if not stmt then self.db:close() self.db = nil return nil, serr end
	self.set_meta_stmt = stmt
	stmt, serr = prepare_statement(self, "SELECT value FROM Metadata WHERE key = ?")
	if not stmt then self.db:close() self.db = nil return nil, serr end
	self.get_meta_stmt = stmt
	stmt, serr = prepare_statement(self, "INSERT INTO Snapshot (tick, t, pos1_x, pos1_y, pos1_z, " ..
		"size_x, size_y, size_z, names, encoding, data) " ..
		"VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
	if not stmt then self.db:close() self.db = nil return nil, serr end
	self.insert_snapshot = stmt

	self.seq, self.failed, self.dropped, self.in_transaction = 0, 0, 0, false
	self.events, self.movement, self.player_ids = {}, {}, {}
	self.written = {events = 0, movement = 0, players = 0}
	return true
end

---@return boolean
function DB:is_open()
	return self.db ~= nil
end

-- Fold the write-ahead log back into the main file, so a finished recording is
-- the single .sqlite file it looks like. A connection that is still reading the
-- recording holds that back (WAL is what lets it read while the recorder
-- writes, so this is a normal thing to meet): the pages stay in the -wal, and
-- whoever takes the file away has to take that with it.
local function checkpoint(self)
	local stmt = self.db:prepare("PRAGMA wal_checkpoint(TRUNCATE)")
	if not stmt then
		return false, tostring(self.db:errmsg())
	end
	local busy, err
	if stmt:step() == self.sqlite.ROW then
		busy = stmt:get_value(0)  -- lsqlite3 counts result columns from 0
	end
	stmt:reset()
	stmt:finalize()
	if busy == nil then
		return false, tostring(self.db:errmsg())
	end
	if busy ~= 0 then
		err = "another connection is using the recording, so its write-ahead log could not be" ..
			" folded back into the file"
	end
	return busy == 0, err
end

function DB:close()
	if not self.db then
		return nil, "no recording database is open"
	end
	local ok, err = self:flush()
	-- Let SQLite refresh the planner statistics for whoever reads the file
	-- later, and fold the log back in.
	self.db:exec("PRAGMA optimize;")
	local checkpointed, checkpoint_err = checkpoint(self)
	if not checkpointed then
		core.log("warning", "[recorder] " .. tostring(checkpoint_err) ..
			"; keep the -wal file next to it or open the database once")
	end
	self.db:close()
	self.db = nil
	self.insert_player, self.insert_event, self.insert_movement = nil, nil, nil
	self.set_meta_stmt, self.get_meta_stmt, self.insert_snapshot = nil, nil, nil
	self.player_ids = {}
	self.events, self.movement = {}, {}
	self.in_transaction = false
	return ok, err
end

-- Ids are handed out while buffering, so they reflect the order in which
-- things happened rather than the order in which they reach SQLite.
---@return integer
function DB:next_id()
	self.seq = self.seq + 1
	return self.seq
end

-- Id of the player with this name, creating their row on first sight.
--
-- A row that cannot be written is retried the next time the player is seen
-- rather than remembered as a lost cause: a database that was busy for a
-- moment must not cost the recording a player for the rest of its length. The
-- caller is told about each failure and decides how often to say so.
---@param name string
---@return integer|nil, string?
function DB:player_id(name)
	local id = self.player_ids[name]
	if id then
		return id
	end
	local ret = self.insert_player:bind_values(name)
	if ret ~= self.sqlite.OK then
		self.insert_player:reset()
		return nil, "cannot add player " .. name .. ": " .. tostring(self.db:errmsg())
	end
	ret = self.insert_player:step()
	if ret ~= self.sqlite.DONE then
		local err = "cannot add player " .. name .. ": " .. tostring(self.db:errmsg())
		self.insert_player:reset()
		return nil, err
	end
	id = self.insert_player:last_insert_rowid()
	self.insert_player:reset()
	self.player_ids[name] = id
	self.written.players = self.written.players + 1
	return id
end

-- The id of a player already written in this recording, without creating one:
-- a leave must not put a Players row into a recording whose region the player
-- was never in.
---@param name string
---@return integer|nil
function DB:known_player_id(name)
	return self.player_ids[name]
end

---@param row table  -- an Events row, in column order, ids included
function DB:add_event(row)
	self.events[#self.events + 1] = row
end

---@param row table  -- a Movement row, in column order, ids included
function DB:add_movement(row)
	self.movement[#self.movement + 1] = row
end

---@return integer
function DB:buffered()
	return #self.events + #self.movement
end

---@return table
function DB:stats()
	return {
		players = self.written.players,
		events = self.written.events,
		movement = self.written.movement,
		buffered = #self.events + #self.movement,
		dropped = self.dropped,
		failed = self.failed,
	}
end

local function insert_row(self, stmt, row, columns)
	local ret = stmt:bind_values(unpack(row, 1, columns))
	if ret ~= self.sqlite.OK then
		return nil, errmsg(self, "cannot bind row")
	end
	ret = stmt:step()
	if ret ~= self.sqlite.DONE then
		return nil, errmsg(self, "cannot insert row")
	end
	return true
end

local function insert_rows(self, stmt, rows, count, columns)
	for i = 1, count do
		-- Bind and step under pcall: lsqlite3 raises rather than returning a
		-- code for a value it cannot bind, and that raise would unwind out of
		-- the caller's transaction, leaving it open forever.
		local raised, done, err = pcall(insert_row, self, stmt, rows[i], columns)
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
function DB:flush()
	if not self.db then
		return nil, "no recording database is open"
	end
	local nevents, nmovement = #self.events, #self.movement
	if nevents == 0 and nmovement == 0 then
		-- Nothing to write, but the run of failures (if any) ends here.
		self.failed = 0
		return true
	end
	if self.in_transaction then
		return nil, "a transaction is already open"
	end

	local ret = self.db:exec("BEGIN")
	if ret ~= self.sqlite.OK then
		return nil, errmsg(self, "cannot start a transaction")
	end
	self.in_transaction = true

	-- Which of the two tables has rows in a given batch is up to the server: a
	-- batch of movement with no events at all is the ordinary case, so the
	-- insert of one table may not be conditional on the other having run.
	local ok, err = true, nil
	if nevents > 0 then
		ok, err = insert_rows(self, self.insert_event, self.events, nevents, EVENT_COLUMNS)
	end
	if ok and nmovement > 0 then
		ok, err = insert_rows(self, self.insert_movement, self.movement, nmovement, MOVEMENT_COLUMNS)
	end

	if ok then
		ret = self.db:exec("COMMIT")
		if ret ~= self.sqlite.OK then
			err = errmsg(self, "cannot commit")
			ok = nil
		end
	end

	if ok then
		self.in_transaction = false
		self.written.events = self.written.events + nevents
		self.written.movement = self.written.movement + nmovement
		self.failed = 0
		self.events, self.movement = {}, {}
		return true
	end

	self.db:exec("ROLLBACK")
	self.in_transaction = false
	local lost = nevents + nmovement
	self.dropped = self.dropped + lost
	self.failed = self.failed + 1
	self.events, self.movement = {}, {}
	return nil, err, lost
end

-- The region snapshot is one row written once, when the snapshot phase is done:
-- the baseline every later change is measured against. It is deliberately not
-- buffered with the event rows - it is not a row in the timeline, and it has to
-- be in the file before the first event refers to the world it describes.
---@param row table  -- {tick, t, pos1, size, names, encoding, data}
---@return boolean|nil, string?
function DB:set_snapshot(row)
	-- Bind one by one, because the body has to go in as a BLOB: lsqlite3 binds
	-- a Lua string as TEXT, and a STRICT BLOB column refuses TEXT.
	local values = {
		row.tick, row.t,
		row.pos1.x, row.pos1.y, row.pos1.z,
		row.size.x, row.size.y, row.size.z,
		row.names, row.encoding,
	}
	for index = 1, #values do
		if self.insert_snapshot:bind(index, values[index]) ~= self.sqlite.OK then
			local err = errmsg(self, "cannot bind snapshot")
			self.insert_snapshot:reset()
			return nil, err
		end
	end
	if self.insert_snapshot:bind_blob(#values + 1, row.data) ~= self.sqlite.OK then
		local err = errmsg(self, "cannot bind the snapshot body")
		self.insert_snapshot:reset()
		return nil, err
	end
	local ret = self.insert_snapshot:step()
	if ret ~= self.sqlite.DONE then
		local err = errmsg(self, "cannot write snapshot")
		self.insert_snapshot:reset()
		return nil, err
	end
	self.insert_snapshot:reset()
	return true
end

---@param key string
---@param value string
---@return boolean|nil, string?
function DB:set_meta(key, value)
	local ret = self.set_meta_stmt:bind_values(key, value)
	if ret ~= self.sqlite.OK then
		return nil, errmsg(self, "cannot bind metadata")
	end
	ret = self.set_meta_stmt:step()
	if ret ~= self.sqlite.DONE then
		local err = errmsg(self, "cannot write metadata")
		self.set_meta_stmt:reset()
		return nil, err
	end
	self.set_meta_stmt:reset()
	return true
end

---@param key string
---@return string|nil, string?
function DB:get_meta(key)
	local ret = self.get_meta_stmt:bind_values(key)
	if ret ~= self.sqlite.OK then
		return nil, errmsg(self, "cannot bind metadata query")
	end
	ret = self.get_meta_stmt:step()
	if ret == self.sqlite.ROW then
		-- lsqlite3 counts result columns from 0, whatever bind() does
		local value = self.get_meta_stmt:get_value(0)
		self.get_meta_stmt:reset()
		return value
	end
	self.get_meta_stmt:reset()
	if ret ~= self.sqlite.DONE then
		return nil, errmsg(self, "cannot read metadata")
	end
	return nil
end

return dbmanager
