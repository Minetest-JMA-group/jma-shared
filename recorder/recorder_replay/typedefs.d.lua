---@meta
-- Type declarations for the recorder_replay mod, for editors that read LuaLS
-- annotations. This file is not loaded by the engine.

---@class ReplaySession
---@field id string
---@field name string          -- the recording's name
---@field path string          -- the recording file
---@field T number             -- recording seconds shown
---@field speed number
---@field paused boolean
---@field participants table<string, boolean>
---@field rec table            -- the reader's recording handle

---@class RecorderReplayAPI
---@field sessions table       -- the session registry
---@field end_session fun(id: string?, reason: string?): boolean
---@field unavailable string?  -- set when lsqlite3 is missing

---@type RecorderReplayAPI
recorder_replay = {}
