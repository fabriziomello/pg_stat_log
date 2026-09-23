-- Cheap work that should not produce WARNING/ERROR log traffic.
SET client_min_messages TO error;
SELECT count(*) FROM demo_orders;
INSERT INTO demo_orders (note) VALUES ('ok');
SELECT 1;
