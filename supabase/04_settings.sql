-- Task 5: your settings (starting balances, today's rate, ADX threshold).
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
--
-- One row per user, so the phone and laptop share the same settings.
-- The row is created the first time you tap "Save settings".

create table public.settings (
  -- Filled in automatically with the signed-in user's id. Also the row's key,
  -- so each user can only ever have one settings row.
  user_id                 uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  -- Starting balance of each account, in $. Empty until you type one in.
  start_balance_daily     numeric(12, 2) check (start_balance_daily > 0),
  start_balance_backtest  numeric(12, 2) check (start_balance_backtest > 0),
  -- "Today's rate", typed in by hand. Only used for totals "at today's rate".
  -- Each closed trade keeps its own rate in the trades table.
  usdzar_today            numeric(10, 4) check (usdzar_today > 0),
  adx_threshold           numeric(5, 2) not null default 20 check (adx_threshold >= 0 and adx_threshold <= 100)
);

-- Row Level Security: with this on, nobody can read or write any row
-- unless a policy below allows it.
alter table public.settings enable row level security;

-- Signed-in users can read only their own settings.
create policy "settings: read own"
  on public.settings for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- Signed-in users can create a settings row only for themselves.
create policy "settings: add own"
  on public.settings for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

-- Signed-in users can change only their own settings.
create policy "settings: change own"
  on public.settings for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- Table permissions: signed-in users may read, add and change; signed-out visitors get nothing.
revoke all on public.settings from anon;
grant select, insert, update on public.settings to authenticated;
