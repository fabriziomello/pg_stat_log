SET client_min_messages TO error;
DO $$ BEGIN RAISE WARNING 'demo warning'; END $$;
