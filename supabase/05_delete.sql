-- Task 9: allow deleting your own trades and your own screenshots.
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
--
-- Until now the database refused every delete on purpose (see 02_trades.sql and
-- 03_screenshots.sql). Editing a trade needs no change here: "trades: change own"
-- already covers it.

-- ---- Trades ----
-- Signed-in users can delete only their own trades.
create policy "trades: delete own"
  on public.trades for delete
  to authenticated
  using ((select auth.uid()) = user_id);

-- Table permission to match. Signed-out visitors still get nothing.
grant delete on public.trades to authenticated;

-- ---- Screenshots ----
-- Signed-in users can delete only files inside their own folder ( <your user id>/... ).
create policy "screenshots: delete own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'screenshots'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- There is still no "change" policy for screenshots: a file is only ever added or deleted.
