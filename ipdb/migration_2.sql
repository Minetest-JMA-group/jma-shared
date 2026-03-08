BEGIN TRANSACTION;
PRAGMA user_version = 3;

-- Migration to multimap
-- Recreate table without the UNIQUE constraint
CREATE TABLE Modstorage_new (
    id INTEGER PRIMARY KEY,
    modname TEXT NOT NULL,
    userentry_id INTEGER NOT NULL REFERENCES UserEntry(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    data ANY NOT NULL,
    auxiliary INTEGER
) STRICT;
INSERT INTO Modstorage_new SELECT * FROM Modstorage;
DROP TABLE Modstorage;
ALTER TABLE Modstorage_new RENAME TO Modstorage;

CREATE INDEX idx_modstorage_user_mod_key_aux ON Modstorage(userentry_id, modname, key, auxiliary);
CREATE INDEX idx_modstorage_user_mod_aux ON Modstorage(userentry_id, modname, auxiliary);
CREATE INDEX idx_modstorage_mod_key_aux ON Modstorage(modname, key, auxiliary);

-- Add tables for merge logs, currently unused but collect data
CREATE TABLE MergeEvent (
	id INTEGER PRIMARY KEY,
	entry_src INTEGER,
	entry_dst INTEGER,
	name TEXT NOT NULL,
	ip TEXT NOT NULL,
	timestamp INTEGER NOT NULL DEFAULT (unixepoch('now'))
);
CREATE INDEX idx_mergeevent_timestamp ON MergeEvent(timestamp);

CREATE TABLE Modstorage_log (
	id INTEGER PRIMARY KEY,
	modname TEXT NOT NULL,
	userentry_id INTEGER,
	key TEXT NOT NULL,
	data ANY NOT NULL,
	auxiliary INTEGER,
	merge_id INTEGER NOT NULL REFERENCES MergeEvent(id) ON DELETE CASCADE
);
CREATE INDEX idx_modstorage_log_mergeid ON Modstorage_log(merge_id);

INSERT INTO Metadata (key, value) VALUES ('log_merges', 'true');

COMMIT;