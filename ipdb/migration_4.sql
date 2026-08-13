PRAGMA user_version = 5;

-- Recreate UserEntry with AUTOINCREMENT so that entry ids are never reused.
-- Historical references to entry ids (MergeEvent, *_log tables) must remain
-- unambiguous; a reused id could point history at an unrelated entry.
-- The runner (dbmanager.init_ipdb) disables foreign key enforcement for the
-- duration of the migration batch, so dropping the old table does not cascade
-- into Usernames, IPs and Modstorage. The new table is created under the
-- original name instead of being renamed into it: renaming a table onto a
-- name that a trigger body references fails while that name is temporarily
-- absent, so the dance stays rename-free. The children's foreign key clauses
-- keep referencing "UserEntry" throughout.
CREATE TABLE UserEntry_new (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen TEXT NOT NULL,
	no_merging INTEGER	-- 1 if set, NULL if not
) STRICT;
INSERT INTO UserEntry_new (id, created_at, last_seen, no_merging)
SELECT id, created_at, last_seen, no_merging FROM UserEntry;
DROP TABLE UserEntry;
CREATE TABLE UserEntry (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen TEXT NOT NULL,
	no_merging INTEGER	-- 1 if set, NULL if not
) STRICT;
INSERT INTO UserEntry (id, created_at, last_seen, no_merging)
SELECT id, created_at, last_seen, no_merging FROM UserEntry_new;
DROP TABLE UserEntry_new;

-- Record when a merge is undone by a rollback
ALTER TABLE MergeEvent ADD COLUMN reverted_at INTEGER;

-- History walks: find all merges that produced a given entry
CREATE INDEX idx_mergeevent_dst_timestamp ON MergeEvent(entry_dst, timestamp);

INSERT INTO Metadata (key, value) VALUES ('db_migrated_v5', CURRENT_TIMESTAMP);
UPDATE Metadata SET value = '5' WHERE key = 'db_version';
