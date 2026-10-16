-- Task 1: test notes table, used only to prove phone-laptop sync.
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.

create table public.notes (
  id         bigint generated always as identity primary key,
  -- Filled in automatically with the signed-in user's id.
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

-- Row Level Security: with this on, nobody can read or write any row
-- unless a policy below allows it.
alter table public.notes enable row level security;

-- Signed-in users can read only their own notes.
create policy "notes: read own"
  on public.notes for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- Signed-in users can add notes only as themselves.
create policy "notes: add own"
  on public.notes for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

-- Table permissions: signed-in users may read and add; signed-out visitors get nothing.
revoke all on public.notes from anon;
grant select, insert on public.notes to authenticated;
