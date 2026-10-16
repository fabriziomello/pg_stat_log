-- Fails on half of the runs, so pg_stat_statements also has its text.
SET client_min_messages TO error;
\set divisor random(0, 1)
SELECT 1 / :divisor;
