-- Raise default max_concurrent from 3 to 5 for faster initial sync.
-- Only affects newly created runs; existing runs keep their current value.
ALTER TABLE stripe._sync_runs ALTER COLUMN max_concurrent SET DEFAULT 5;
