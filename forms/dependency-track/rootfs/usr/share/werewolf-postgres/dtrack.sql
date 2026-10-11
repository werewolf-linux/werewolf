-- Dependency-Track's role, which pg-init applies before each start
-- (forms/postgresql/README.md). Dependency-Track logs in over loopback as
-- the role dtrack (pg_hba.conf) and keeps its tables in the postgres
-- database, which it owns.

DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dtrack') THEN CREATE ROLE dtrack LOGIN; END IF; END $$;

ALTER DATABASE postgres OWNER TO dtrack;
