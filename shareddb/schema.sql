-- Not applied automatically, because permissions have to be configured manually
-- But the mod expects to find a database with this schema

CREATE TABLE modstorage (
    id SERIAL PRIMARY KEY,
    modname text NOT NULL,
    key text NOT NULL,
    value text NOT NULL,
    UNIQUE (modname, key)
);

CREATE OR REPLACE FUNCTION modstorage_notify_func()
RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        PERFORM pg_notify('shareddb_changed', NEW.modname || E'\n' || NEW.key);
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM pg_notify('shareddb_changed', OLD.modname || E'\n' || OLD.key);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER modstorage_notify_trigger
AFTER INSERT OR UPDATE OR DELETE ON modstorage
FOR EACH ROW EXECUTE FUNCTION modstorage_notify_func();