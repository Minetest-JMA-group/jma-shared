---@meta

---@class IPDBStorage
---@field get_context_by_name fun(self: IPDBStorage, name: string): IPDBContext
---@field get_context_by_ip fun(self: IPDBStorage, ip: string): IPDBContext
local IPDBStorage = {}

---@overload fun(self: IPDBStorage, name: string): nil, string
IPDBStorage.get_context_by_name = function(self, name) return nil, "" end

---@overload fun(self: IPDBStorage, ip: string): nil, string
IPDBStorage.get_context_by_ip = function(self, ip) return nil, "" end

---@class UsernameEntity
---@field id integer
---@field userentry_id integer
---@field name string
---@field created_at string
---@field last_seen string

---@class IPEntity
---@field id integer
---@field userentry_id integer
---@field ip string
---@field created_at string
---@field last_seen string