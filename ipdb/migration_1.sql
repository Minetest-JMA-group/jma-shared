BEGIN TRANSACTION;
PRAGMA user_version = 2;

-- We didn't need this, we already had an index from UNIQUE
DROP INDEX idx_modstorage_user_mod_key;

ALTER TABLE Modstorage ADD COLUMN auxiliary INTEGER;
CREATE INDEX idx_modstorage_user_mod_aux ON Modstorage(userentry_id, modname, auxiliary);

INSERT INTO Metadata (key, value) VALUES ('db_migrated_v2', CURRENT_TIMESTAMP);

COMMIT;