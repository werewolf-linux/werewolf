-- MISP's role, which mariadb-init applies before each start
-- (forms/mariadb-local/README.md). MISP logs in over loopback as misp.
-- The password is not a secret: nothing but MISP can open the port, and
-- it is not the image's published password.

CREATE DATABASE IF NOT EXISTS misp;

CREATE USER IF NOT EXISTS 'misp'@'127.0.0.1' IDENTIFIED BY 'misp';

GRANT ALL PRIVILEGES ON misp.* TO 'misp'@'127.0.0.1';
