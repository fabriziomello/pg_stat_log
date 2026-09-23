CREATE ROLE app_shop LOGIN PASSWORD 'shop';
CREATE ROLE app_analytics LOGIN PASSWORD 'analytics';
CREATE ROLE demo_monitor LOGIN PASSWORD 'monitor';

CREATE DATABASE shop OWNER app_shop;
CREATE DATABASE analytics OWNER app_analytics;

GRANT pg_read_all_stats TO demo_monitor;
GRANT CONNECT ON DATABASE postgres TO demo_monitor;

\c shop

CREATE TABLE demo_orders (
    id   serial PRIMARY KEY,
    sku  text UNIQUE,
    note text
);
INSERT INTO demo_orders (sku, note) VALUES ('FIXED', 'seed');
GRANT ALL ON TABLE demo_orders TO app_shop;
GRANT USAGE, SELECT ON SEQUENCE demo_orders_id_seq TO app_shop;

\c analytics

CREATE TABLE demo_orders (
    id   serial PRIMARY KEY,
    sku  text UNIQUE,
    note text
);
INSERT INTO demo_orders (sku, note) VALUES ('FIXED', 'seed');
GRANT ALL ON TABLE demo_orders TO app_analytics;
GRANT USAGE, SELECT ON SEQUENCE demo_orders_id_seq TO app_analytics;

\c postgres

SELECT pg_stat_log_reset();
