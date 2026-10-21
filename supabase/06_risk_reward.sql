-- Task 11: rule 4 of the entry checklist becomes "risk:reward is at least 1:N".
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
--
-- Run it once only. Right after it runs, the live site needs the Task 11 app.js,
-- because the old one still asks for "check_stop" and would show an error until then.

-- ---- Trades ----
-- The fourth tick-box was "the stop is placed at the planned distance". It now means
-- "risk:reward is at least 1:N", so the column gets a name that says so.
-- Renaming keeps every saved tick as it was, so trades logged before this change
-- still hold their old "stop" tick (the app's Details view says so).
-- The row-level security policies and permissions are on the table, so they carry over unchanged.
alter table public.trades rename column check_stop to check_rr;

-- ---- Settings ----
-- N in "risk:reward at least 1:N". Starts at 2, so the rule reads "at least 1:2".
-- Your existing settings row gets 2 as well. The permissions in 04_settings.sql
-- cover new columns, so signed-out visitors still can't read or change it.
alter table public.settings
  add column min_rr numeric(5, 2) not null default 2 check (min_rr > 0 and min_rr <= 100);
