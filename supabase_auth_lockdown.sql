-- FINAL STEP of the Supabase Auth migration. Do NOT run this until every
-- account has been migrated and everyone has signed in successfully at least
-- once through Supabase Auth.
--
-- Until now the anon policies have been left in place so that anyone not yet
-- migrated could still use the app through the localStorage fallback. This
-- removes them, which is the point of the whole exercise: the anon key is
-- published in the served HTML, so while these policies exist, anyone who
-- views source can read and write every school's audit data.
--
-- After this runs:
--   - Signed-in users keep full access through the authenticated policies.
--   - The localStorage fallback still logs someone in locally, but they will
--     see no cloud data, because the anon role can no longer read these tables.
--
-- Check before running — this should list every person who needs access:
--   select login_id, role, name from public.profiles order by login_id;
--
-- To undo, re-create the three policies with `to anon`.

drop policy if exists anon_all_schools on public.schools;
drop policy if exists anon_all_audit   on public.audit_states;
drop policy if exists anon_all_journey on public.journey_records;
