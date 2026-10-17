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
---@field arena table          -- {pos1 = {x,y,z}, pos2 = {x,y,z}} the box the replay is built in
---@field offset table         -- recorded position -> arena position
---@field reconstruct table    -- the reconstructed region's state
---@field reconstruct_dirty boolean -- node changes waiting to be written

---@class ReplayArena
---@field init fun(dependencies: table)
---@field set_mark fun(name: string, which: string, pos: table): boolean|nil, string?
---@field clear_marks fun(name: string)
---@field has_marks fun(name: string): boolean
---@field available fun(player_name: string): boolean, string?
---@field resolve fun(player_name: string, recorded: table): table|nil, string?
---@field prepare fun(box: table): boolean|nil, string?
---@field clear fun(box: table): boolean|nil, string?
---@field viewing_position fun(box: table): table
---@field offset fun(box: table, recorded: table): table
---@field translate fun(pos: table?, offset: table): table?
---@field save_flag fun(box: table, session_id: string)
---@field clear_flag fun(session_id: string)
---@field recover fun()

---@class RecorderReplayAPI
---@field sessions table       -- the session registry
---@field arena ReplayArena    -- arena choice, preparation and boot recovery
---@field end_session fun(id: string?, reason: string?): boolean
---@field unavailable string?  -- set when lsqlite3 is missing

---@type RecorderReplayAPI
recorder_replay = {}
