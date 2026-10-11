-- BloodHound's role, which pg-init applies before each start. BloodHound
-- logs in over loopback as the role bloodhound and keeps its tables in
-- the postgres database, which it owns.

DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bloodhound') THEN CREATE ROLE bloodhound LOGIN; END IF; END $$;

ALTER DATABASE postgres OWNER TO bloodhound;
