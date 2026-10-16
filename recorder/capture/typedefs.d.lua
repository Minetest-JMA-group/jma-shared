---@meta
-- Type declarations for the recorder mod, for editors that read LuaLS
-- annotations. This file is not loaded by the engine.

---@class RecorderEventFields
---@field subject ObjectRef|string|nil  -- who did it; a player name is accepted too
---@field object ObjectRef|string|nil  -- whom it was done to
---@field pos table|nil  -- {x=, y=, z=} the event is about
---@field node string|nil
---@field param2 integer|nil
---@field item string|nil
---@field data table|nil  -- JSON-encoded into the event

---@class RecorderAPI
---@field start fun(record_name: string?): string?  -- nil on success, message on failure
---@field stop fun(reason: string?): string?  -- nil on success, message on failure
---@field add_meta fun(key: string, value: string): string?
---@field log_event fun(event_type: string, fields: RecorderEventFields?): string?
---@field is_recording fun(): boolean
---@field get_recording_name fun(): string?
---@field get_recording_path fun(): string?

---@type RecorderAPI
recorder = {}

---@class DBManager
---@field init fun(sqlite_lib: table): boolean?
---@field open fun(path: string): boolean?, string?
---@field close fun(): boolean?, string?
---@field is_open fun(): boolean
---@field next_id fun(): integer
---@field player_id fun(name: string): integer?
---@field add_event fun(row: table)
---@field add_movement fun(row: table)
---@field buffered fun(): integer
---@field stats fun(): table
---@field flush fun(): boolean?, string?, integer?
---@field set_meta fun(key: string, value: string): boolean?
---@field get_meta fun(key: string): string?
local DBManager = {}
