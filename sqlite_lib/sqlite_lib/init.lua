if not core.request_insecure_environment() then
    core.log("error", "Insufficient permissions. Add the mod \"sqlite_lib\" to secure.trusted_mods.")
    return
end

sqlite_lib = {}

local loader = package.loadlib(core.get_modpath(core.get_current_modname()) .. "/api.so", "luaopen_sqlite")
assert(loader)
local c_api = loader()

---@type string Default path to the SQLite database file; used when a function is called without an explicit db_file_path.
local default_db_file_path = core.get_worldpath() .. "/mod_db.sqlite"

---@param db_file_path string Path to the SQLite database file. If nil, `default_db_file_path` will be used.
local function ensure_db(db_file_path)
    local file = io.open(db_file_path, "rb")
    if file then
        file:close()
    end
end

---@param db_file_path string|nil Path to the SQLite database file. If nil, `default_db_file_path` will be used.
---@param query string SQL statement to execute
---@return boolean, string|nil Returns true if successful; on failure returns false and an error message.
function sqlite_lib.execute(db_file_path, query)
    db_file_path = db_file_path or default_db_file_path
    ensure_db(db_file_path)
    local ok, err = c_api.execute(db_file_path, query)
    if ok then
        return true
    end
    return false, err
end

---@param db_file_path string|nil Path to the SQLite database file. If nil, `default_db_file_path` will be used.
---@param query string SQL SELECT statement
---@return table|nil, string|nil Returns a table of rows on success, or nil and an error message on failure.
function sqlite_lib.select(db_file_path, query)
    db_file_path = db_file_path or default_db_file_path
    ensure_db(db_file_path)
    local rows, err = c_api.select(db_file_path, query)
    if rows then
        return rows
    end
    return nil, err
end

---@param text string Text to escape
---@param escaping_type string "value" or "identifier"
---@return string|nil, string|nil Returns the escaped text or nil + error message
function sqlite_lib.escape(text, escaping_type)
    if escaping_type ~= "identifier" and escaping_type ~= "value" then
        escaping_type = "value"
    end
    local res, err = c_api.escape(text, escaping_type)
    if res then
        return res
    end
    return nil, err
end
