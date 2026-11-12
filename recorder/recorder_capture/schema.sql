-- Recording schema: application_id identifies JMAR; user_version identifies
-- the schema version. README.md documents columns and event types.

PRAGMA application_id = 0x4A4D4152;
PRAGMA user_version = 1;

-- Annotations about the recording as a whole. recorder.add_meta() writes here,
-- as does the recorder itself: keys starting with "recorder." describe the
-- recording, everything else belongs to whatever mod put it there.
CREATE TABLE Metadata (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
) STRICT;

-- Initial regional snapshot: low corner, dimensions, newline-separated node
-- names and sparse non-air data (recorder_common.snapshot, x/y/z order).
-- encoding is deflate or raw. Names replace run-specific content ids.
-- light uses the same order, densely including air: low 4 bits skylight,
-- high 4 artificial light. light_encoding controls compression; both light
-- columns are NULL when disabled, so replay recalculates lighting.
CREATE TABLE Snapshot (
	tick INTEGER PRIMARY KEY,
	t REAL NOT NULL,
	pos1_x INTEGER NOT NULL,
	pos1_y INTEGER NOT NULL,
	pos1_z INTEGER NOT NULL,
	size_x INTEGER NOT NULL,
	size_y INTEGER NOT NULL,
	size_z INTEGER NOT NULL,
	names TEXT NOT NULL,
	encoding TEXT NOT NULL,
	data BLOB NOT NULL,
	light BLOB,
	light_encoding TEXT
) STRICT;

-- core.serialize(NodeMetaRef:to_table()), with inventory slots converted to
-- itemstrings (including empty slots). Empty data clears metadata.
-- Shared timeline ids; tick 0 holds the baseline, later ticks/times identify
-- the periodic scan that observed a change.
CREATE TABLE NodeMetadata (
	id INTEGER PRIMARY KEY,
	tick INTEGER NOT NULL,
	t REAL NOT NULL,
	pos_x INTEGER NOT NULL,
	pos_y INTEGER NOT NULL,
	pos_z INTEGER NOT NULL,
	data TEXT NOT NULL
) STRICT;

-- One row per mapblock diff round, including light-only changes. data uses
-- recorder_common.snapshot entries: region index and new light byte;
-- encoding controls compression.
CREATE TABLE LightChanges (
	id INTEGER PRIMARY KEY,
	tick INTEGER NOT NULL,
	t REAL NOT NULL,
	data BLOB NOT NULL,
	encoding TEXT NOT NULL
) STRICT;

-- One row per player seen during the recording. Events.subject_player,
-- Events.object_player and Movement.player_id all reference this, so a player
-- keeps one identity even across leaving and rejoining.
CREATE TABLE Players (
	id INTEGER PRIMARY KEY,
	name TEXT NOT NULL UNIQUE
) STRICT;

-- Sparse per-player movement; readers carry unchanged samples forward.
-- id shares the timeline sequence. tick counts steps; t is elapsed server
-- seconds and dtime is this step's length (step lengths vary).
-- pitch/yaw are radians, speed is |vel|, acc_* is velocity delta / dtime
-- (NULL for the first sample). controls is get_player_control_bits(); move_x/y
-- are analog axes from get_player_control().
CREATE TABLE Movement (
	id INTEGER PRIMARY KEY,
	tick INTEGER NOT NULL,
	t REAL NOT NULL,
	dtime REAL NOT NULL,
	player_id INTEGER NOT NULL REFERENCES Players(id),
	pos_x REAL NOT NULL,
	pos_y REAL NOT NULL,
	pos_z REAL NOT NULL,
	pitch REAL NOT NULL,
	yaw REAL NOT NULL,
	vel_x REAL NOT NULL,
	vel_y REAL NOT NULL,
	vel_z REAL NOT NULL,
	acc_x REAL,
	acc_y REAL,
	acc_z REAL,
	speed REAL NOT NULL,
	controls INTEGER NOT NULL,
	move_x REAL NOT NULL,
	move_y REAL NOT NULL
) STRICT;

-- Event participants are nullable Players ids; non-player actors use data.actor.
-- pos_* describes the action target; the actor's position is in Movement.
-- node/param2 describes the node (param1 is engine-derived); item is an
-- itemstring. data is event-specific JSON; see README.md for fields.
CREATE TABLE Events (
	id INTEGER PRIMARY KEY,
	tick INTEGER NOT NULL,
	t REAL NOT NULL,
	type TEXT NOT NULL,
	subject_player INTEGER REFERENCES Players(id),
	object_player INTEGER REFERENCES Players(id),
	pos_x REAL,
	pos_y REAL,
	pos_z REAL,
	node TEXT,
	param2 INTEGER,
	item TEXT,
	data TEXT
) STRICT;

-- Both tables walk the one sequence of ids described above, which makes this
-- a faithful merge of the two. Reading it with ORDER BY id gives the events of
-- a recording in the order in which they happened, across table boundaries.
CREATE VIEW Timeline AS
	SELECT id, tick, t, 'movement' AS kind, NULL AS type, player_id AS subject_player, NULL AS object_player
		FROM Movement
	UNION ALL
	SELECT id, tick, t, 'event' AS kind, type, subject_player, object_player
		FROM Events;

CREATE INDEX idx_movement_tick ON Movement(tick);
CREATE INDEX idx_movement_player ON Movement(player_id, tick);
CREATE INDEX idx_events_tick ON Events(tick);
CREATE INDEX idx_events_type ON Events(type);
CREATE INDEX idx_events_subject ON Events(subject_player);
CREATE INDEX idx_node_metadata_tick ON NodeMetadata(tick);
CREATE INDEX idx_light_changes_tick ON LightChanges(tick);
