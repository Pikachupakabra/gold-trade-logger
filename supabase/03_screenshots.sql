-- Task 4: a private storage bucket for chart screenshots.
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
--
-- Each file is saved as  <your user id>/<random name>.jpg , so the first folder
-- in the path says whose file it is. The policies below check that folder.
-- The trades table already has open_screenshot_path and close_screenshot_path (Task 2).

-- The bucket. "public = false" means there are no open links: every file needs a
-- signed-in request, or a short-lived signed link made for a signed-in user.
-- The app shrinks every image to a JPEG first, so only JPEGs up to 5 MB are allowed.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('screenshots', 'screenshots', false, 5242880, array['image/jpeg']);

-- Row Level Security is already on for storage files in every Supabase project.
-- With no policy, nobody can read or add anything. These two policies let a
-- signed-in user read and add files only inside their own folder.

create policy "screenshots: read own"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'screenshots'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "screenshots: add own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'screenshots'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- There is deliberately no change or delete policy. Task 9 adds "delete own" in 05_delete.sql.
