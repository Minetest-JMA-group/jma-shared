-- Boot defaults, persistent overrides, resets and command validation.
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/tests/[^/]+$") or ".."
local mocklib = dofile(root .. "/tests/mocklib.lua")
local mock = mocklib.new({modpaths = {recorder_common = root}})
core = mock.core
mock.settings["recorder.max_duration"] = "60"
mock.settings["recorder.max_buffered"] = "not a number"
mock.modstorage["setting:recorder.max_duration"] = "=120"
mock.modstorage["setting:replay.model"] = "="
mock.modstorage["setting:recorder.max_size_mb"] = "=-5"
local settings = dofile(root .. "/settings.lua")
local checks = 0
local function check(ok, message)
	assert(ok, message)
	checks = checks + 1
	print("  ok - " .. message)
end
check(settings:get("recorder.max_duration") == "120", "a stored override beats configuration")
check(settings:get("recorder.max_buffered") == "20000", "an invalid default falls back to the built-in value")
check(settings:get("recorder.max_size_mb") == "0", "an invalid stored override falls back to the default")
local ok, description = settings.command("max_duration")
check(ok and description:find("world override", 1, true), "commands report the value's origin")
core.settings.get = function() error("settings must not be read after boot") end
core.settings.get_bool = core.settings.get
check(settings:reset("recorder.max_duration"), "reset succeeds without reading configuration")
check(settings:get("recorder.max_duration") == "60", "reset restores the cached configuration default")
ok, description = settings.command("max_duration")
check(description:find("configuration default", 1, true), "reset restores the default's origin")
check(settings.command("max_duration 30"), "commands can set overrides")
check(settings.command("recorder.retention_age 7d"), "age accepts time units")
check(settings:get("recorder.retention_age") == "604800", "durations are normalized to seconds")
check(settings.command('replay.model ""'), "commands support explicit empty overrides")
check(mock.modstorage["setting:replay.model"] == "=", "empty overrides remain distinct from absence")
local before = settings:snapshot("recorder.")
check(settings:set("recorder.max_duration", "45"), "an override can change again")
check(before["recorder.max_duration"] == "30", "a snapshot retains its previous configuration")
for _, entry in ipairs({
	{"recorder.max_recordings", "1.5"}, {"recorder.max_duration", "-1"},
	{"recorder.max_size_mb", "inf"}, {"recorder.flush_interval", "nan"},
	{"recorder.compression_level", "10"}, {"recorder.chat", "perhaps"},
	{"replay.wield_pos", "1,,3"}, {"replay.wield_scale", "1,0,1"},
	{"replay.arena", "10,10,10,0,0,0"}, {"recorder.retention_age", "7years"},
	{"recorder.unknown", "1"},
}) do
	check(not settings:set(entry[1], entry[2]), "reject invalid " .. entry[1] .. " = " .. entry[2])
end
check(settings:get("recorder.max_duration") == "45", "invalid values leave the effective settings intact")
local saved = mock.modstorage
mock = mocklib.new({modpaths = {recorder_common = root}})
mock.modstorage = saved
mock.settings["recorder.max_duration"] = "90"
core = mock.core
settings = dofile(root .. "/settings.lua")
check(settings:get("recorder.max_duration") == "45", "overrides survive a restart")
check(settings:reset("recorder.max_duration") and settings:get("recorder.max_duration") == "90",
	"reset uses defaults from the current boot")
check(mock.chatcommands.recorder_settings.privs.server, "the standalone command requires server privilege")
print(checks .. " checks passed")
