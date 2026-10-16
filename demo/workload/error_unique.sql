-- Fails on half of the runs, so pg_stat_statements also has its text.
SET client_min_messages TO error;
\set dup random(0, 1)
INSERT INTO demo_orders (sku, note) SELECT 'FIXED', 'dup' WHERE :dup = 1;
