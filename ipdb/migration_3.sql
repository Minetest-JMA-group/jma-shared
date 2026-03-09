BEGIN TRANSACTION;
PRAGMA user_version = 4;

CREATE TABLE Usernames_log (
	id INTEGER PRIMARY KEY,
	userentry_id INTEGER NOT NULL,
	name TEXT NOT NULL,
	created_at TEXT NOT NULL,
	last_seen TEXT NOT NULL,
	merge_id INTEGER NOT NULL REFERENCES MergeEvent(id) ON DELETE CASCADE
) STRICT;
CREATE INDEX idx_usernames_log_mergeid ON Usernames_log(merge_id);

CREATE TABLE IPs_log (
	id INTEGER PRIMARY KEY,
	userentry_id INTEGER NOT NULL,
	ip TEXT NOT NULL,
	created_at TEXT NOT NULL,
	last_seen TEXT NOT NULL,
	merge_id INTEGER NOT NULL REFERENCES MergeEvent(id) ON DELETE CASCADE
) STRICT;
CREATE INDEX idx_ips_log_mergeid ON IPs_log(merge_id);

-- Forgot to make tables STRICT in previous script, so recreate them now
ALTER TABLE MergeEvent RENAME TO MergeEvent_old;
ALTER TABLE Modstorage_log RENAME TO Modstorage_log_old;

CREATE TABLE MergeEvent (
	id INTEGER PRIMARY KEY,
	entry_src INTEGER,
	entry_dst INTEGER,
	name TEXT NOT NULL,
	ip TEXT NOT NULL,
	timestamp INTEGER NOT NULL DEFAULT (unixepoch('now'))
) STRICT;

CREATE TABLE Modstorage_log (
	id INTEGER PRIMARY KEY,
	modname TEXT NOT NULL,
	userentry_id INTEGER,
	key TEXT NOT NULL,
	data ANY NOT NULL,
	auxiliary INTEGER,
	merge_id INTEGER NOT NULL REFERENCES MergeEvent(id) ON DELETE CASCADE
) STRICT;

-- Copy data from old tables to new STRICT tables
INSERT INTO MergeEvent (id, entry_src, entry_dst, name, ip, timestamp)
SELECT id, entry_src, entry_dst, name, ip, timestamp
FROM MergeEvent_old;

INSERT INTO Modstorage_log (id, modname, userentry_id, key, data, auxiliary, merge_id)
SELECT id, modname, userentry_id, key, data, auxiliary, merge_id
FROM Modstorage_log_old;

DROP TABLE MergeEvent_old;
DROP TABLE Modstorage_log_old;

-- Recreate indexes
CREATE INDEX idx_mergeevent_timestamp ON MergeEvent(timestamp);
CREATE INDEX idx_modstorage_log_mergeid ON Modstorage_log(merge_id);

COMMIT;