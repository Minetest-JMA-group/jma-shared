---@class IPDBContext
---@field _userentry_id integer
---@field set_string fun(self: IPDBContext, key: string, value: string?): nil|string
---@field get_string fun(self: IPDBContext, key: string): string?
---@field finalize fun(self: IPDBContext): nil|string
local IPDBContext = {}

-- The second argument is a string only on error
---@overload fun(self: IPDBContext): nil, string
IPDBContext.get_string = function(self) return nil, "" end

---@class IPDBStorage
---@field get_context_by_name fun(self: IPDBStorage, name: string): IPDBContext
---@field get_context_by_ip fun(self: IPDBStorage, ip: string): IPDBContext
local IPDBStorage = {}

---@overload fun(self: IPDBStorage, name: string): nil, string
IPDBStorage.get_context_by_name = function(self, name) return nil, "" end

---@overload fun(self: IPDBStorage, ip: string): nil, string
IPDBStorage.get_context_by_ip = function(self, ip) return nil, "" end