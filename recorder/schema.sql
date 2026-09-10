-- Schema of one recording file. Every recording starts as an empty database
-- created from this file, so a reader can always tell what it is looking at:
--
--   PRAGMA application_id = 0x4A4D4152  ('JMAR' - a JMA recorder database)
--   PRAGMA user_version   = schema version, bumped whenever this file changes
--
-- See README.md for the meaning of every column and the list of event types.

PRAGMA application_id = 0x4A4D4152;
PRAGMA user_version = 1;

-- Annotations about the recording as a whole. recorder.add_meta() writes here,
-- as does the recorder itself: keys starting with "recorder." describe the
-- recording, everything else belongs to whatever mod put it there.
CREATE TABLE Metadata (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
) STRICT;

-- One row per player seen during the recording. Events.subject_player,
-- Events.object_player and Movement.player_id all reference this, so a player
-- keeps one identity even across leaving and rejoining.
CREATE TABLE Players (
	id INTEGER PRIMARY KEY,
	name TEXT NOT NULL UNIQUE
) STRICT;

-- Player kinematics, one sample per player per server step in which anything
-- about that player changed (unchanged samples are not written; a reader holds
-- the previous row forward - see README.md).
--
-- id is taken from the same sequence as Events.id, so a single ORDER BY id
-- over both tables (see the Timeline view) reproduces the order in which
-- things happened. tick counts server steps since the recording started; t is
-- the amount of server time since then, in seconds, and dtime the length of
-- this particular step - the server step is not a fixed length, so t is not
-- simply tick * dtime.
--
-- pitch (look up/down) and yaw (look around) are radians, as returned by
-- ObjectRef:get_look_vertical()/get_look_horizontal(). speed is |vel|, kept
-- because filtering by speed is the common query. acc_* is derived from the
-- difference between this sample and the previous one of the same player, and
-- is NULL for the first sample of a player (there is nothing to derive from).
-- controls is the bitmask documented for ObjectRef:get_player_control_bits();
-- move_x/move_y are the analog movement axes of the same call, which carry
-- joystick input that the buttons alone do not describe.
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

-- Everything that happened, one row per event.
--
-- subject_player is who performed the action, object_player is the player it
-- was performed on. Both are NULL when the event has no such participant: an
-- actor that is not a player (a mob, an explosion) is described by
-- data.actor instead, and an action on a node or an item leaves
-- object_player NULL and fills pos_*/node/param2/item.
--
-- pos_* is the position the event is about (the dug or placed node, the player
-- that was hit, where someone spoke, ...) - not the actor's own position,
-- which is in Movement for the same tick. node is a node name with its param2
-- (param1 is derived by the engine from lighting and flow, so it is not
-- stored). item is an itemstring: the tool used to dig, the stack placed, the
-- stack crafted, the wielded stack of a join. data is a JSON object holding
-- the fields that only apply to one kind of event - see README.md. SQLite's
-- JSON functions can dig into it: json_extract(data, '$.reason.type').
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
CREATE INDEX idx_events_object ON Events(object_player);
