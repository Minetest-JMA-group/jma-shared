BEGIN TRANSACTION;
PRAGMA user_version = 1;

CREATE TABLE UserEntry (
	id INTEGER PRIMARY KEY,
	created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen TEXT NOT NULL,
	no_merging INTEGER	-- 1 if set, NULL if not
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
	data ANY NOT NULL,
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

-- Trigger for when Usernames are deleted
CREATE TRIGGER cleanup_userentry_after_username_delete
AFTER DELETE ON Usernames
BEGIN
    DELETE FROM UserEntry
    WHERE id = OLD.userentry_id
    AND NOT EXISTS (SELECT 1 FROM Usernames WHERE userentry_id = OLD.userentry_id)
    AND NOT EXISTS (SELECT 1 FROM IPs WHERE userentry_id = OLD.userentry_id);
END;

-- Trigger for when IPs are deleted
CREATE TRIGGER cleanup_userentry_after_ip_delete
AFTER DELETE ON IPs
BEGIN
    DELETE FROM UserEntry
    WHERE id = OLD.userentry_id
    AND NOT EXISTS (SELECT 1 FROM Usernames WHERE userentry_id = OLD.userentry_id)
    AND NOT EXISTS (SELECT 1 FROM IPs WHERE userentry_id = OLD.userentry_id);
END;

-- Trigger for when Usernames are updated (if they change userentry_id)
CREATE TRIGGER cleanup_userentry_after_username_update
AFTER UPDATE OF userentry_id ON Usernames
BEGIN
    DELETE FROM UserEntry
    WHERE id = OLD.userentry_id
    AND NOT EXISTS (SELECT 1 FROM Usernames WHERE userentry_id = OLD.userentry_id)
    AND NOT EXISTS (SELECT 1 FROM IPs WHERE userentry_id = OLD.userentry_id);
END;

-- Trigger for when IPs are updated (if they change userentry_id)
CREATE TRIGGER cleanup_userentry_after_ip_update
AFTER UPDATE OF userentry_id ON IPs
BEGIN
    DELETE FROM UserEntry
    WHERE id = OLD.userentry_id
    AND NOT EXISTS (SELECT 1 FROM Usernames WHERE userentry_id = OLD.userentry_id)
    AND NOT EXISTS (SELECT 1 FROM IPs WHERE userentry_id = OLD.userentry_id);
END;

COMMIT;