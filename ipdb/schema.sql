BEGIN TRANSACTION;
PRAGMA user_version = 1;

CREATE TABLE UserEntry (
	id INTEGER PRIMARY KEY,
	created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen TEXT NOT NULL
) STRICT;

CREATE TABLE Usernames (
	id INTEGER PRIMARY KEY,
	userentry_id INTEGER NOT NULL REFERENCES UserEntry(id) ON DELETE CASCADE,
	name TEXT UNIQUE NOT NULL,
	created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen TEXT NOT NULL
) STRICT;

CREATE TABLE IPs (
	id INTEGER PRIMARY KEY,
	userentry_id INTEGER NOT NULL REFERENCES UserEntry(id) ON DELETE CASCADE,
	ip TEXT UNIQUE NOT NULL,
	created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen TEXT NOT NULL
) STRICT;

CREATE TABLE Modstorage (
	id INTEGER PRIMARY KEY,
	modname TEXT NOT NULL,
	userentry_id INTEGER NOT NULL REFERENCES UserEntry(id) ON DELETE CASCADE,
	key TEXT NOT NULL,
	data BLOB NOT NULL,
	UNIQUE (userentry_id, modname, key)
) STRICT;

CREATE TABLE Metadata (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
) STRICT;

INSERT INTO Metadata (key, value) VALUES ('db_creation', CURRENT_TIMESTAMP);
INSERT INTO Metadata (key, value) VALUES ('no_new_entries', 'false');

CREATE INDEX idx_usernames_userentry ON Usernames(userentry_id);
CREATE INDEX idx_ips_userentry ON IPs(userentry_id);
CREATE INDEX idx_modstorage_user_mod_key ON Modstorage(userentry_id, modname, key);
COMMIT;