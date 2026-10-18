-- Task 2: the trades table.
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
--
-- One row per trade. The "open" columns are filled when you enter a trade.
-- The "close" columns stay empty (null) until you close it, which Task 3 adds.
-- Screenshot columns hold the file's path in storage, which Task 4 adds.

create table public.trades (
  id          bigint generated always as identity primary key,
  -- Filled in automatically with the signed-in user's id.
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  -- When the row was saved. Used to find "the last account used".
  created_at  timestamptz not null default now(),

  -- ---- At open ----
  account         text not null check (account in ('daily', 'backtest')),
  opened_at       timestamptz not null default now(),
  direction       text not null check (direction in ('buy', 'sell')),
  risk_usd        numeric(12, 2) not null check (risk_usd > 0),
  adx             numeric(5, 2) check (adx >= 0 and adx <= 100),
  check_h1_bias   boolean not null default false,
  check_m15_flip  boolean not null default false,
  check_adx       boolean not null default false,
  check_stop      boolean not null default false,
  open_screenshot_path text,

  -- ---- At close (Task 3) ----
  closed_at       timestamptz,
  pnl_usd         numeric(12, 2),
  usdzar_rate     numeric(10, 4) check (usdzar_rate > 0),
  close_screenshot_path text,
  mistake_tag     text check (mistake_tag in
                    ('moved stop', 'closed early', 'chased entry', 'traded news', 'no setup')),
  lesson          text check (char_length(lesson) <= 300),

  -- A closed trade must have all three required close values; an open trade has none.
  constraint close_fields_together check (
    (closed_at is null and pnl_usd is null and usdzar_rate is null)
    or (closed_at is not null and pnl_usd is not null and usdzar_rate is not null)
  )
);

-- Row Level Security: with this on, nobody can read or write any row
-- unless a policy below allows it.
alter table public.trades enable row level security;

-- Signed-in users can read only their own trades.
create policy "trades: read own"
  on public.trades for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- Signed-in users can add trades only as themselves.
create policy "trades: add own"
  on public.trades for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

-- Signed-in users can change only their own trades (needed to close a trade in Task 3),
-- and can't hand a trade over to another user.
create policy "trades: change own"
  on public.trades for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- Table permissions: signed-in users may read, add and change; signed-out visitors get nothing.
-- There is deliberately no delete permission here. Task 9 adds it in 05_delete.sql.
revoke all on public.trades from anon;
grant select, insert, update on public.trades to authenticated;
