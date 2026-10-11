-- gvmd's role, which pg-init applies before each start
-- (forms/postgresql/README.md). gvmd logs in over loopback as the role
-- gvmd (pg_hba.conf) and keeps its tables in the postgres database,
-- which it owns.

DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gvmd') THEN CREATE ROLE gvmd LOGIN CREATEDB; END IF; END $$;

ALTER DATABASE postgres OWNER TO gvmd;
