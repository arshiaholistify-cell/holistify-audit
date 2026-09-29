-- Supabase Auth migration for the Holistify audit platform.
--
-- Accounts previously lived only in each browser's localStorage, under
-- 'holistify_users', with passwords in plain text. This moves identity into
-- Supabase Auth and role/scope data into public.profiles.
--
-- Login IDs are not email addresses, so each one maps to a synthetic address:
--   <login_id>@audit.holistify.local
-- The app derives it; nothing is ever sent to that domain.
--
-- DELIBERATELY ADDITIVE. The existing anon policies are left in place so the
-- app keeps working for anyone not yet migrated. Revoking anon access is a
-- separate, final step (see supabase_auth_lockdown.sql), run only once every
-- account has been migrated.

-- ── Profiles ────────────────────────────────────────────────────────────────
create table if not exists public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  login_id         text unique not null,
  name             text not null default '',
  role             text not null default 'school_staff',
  school           text not null default '',
  assigned_schools jsonb not null default '[]'::jsonb,
  page_access      jsonb,
  holistify_team   boolean not null default false,
  created_at       timestamptz not null default now()
);

create index if not exists profiles_login_id_idx on public.profiles (login_id);

alter table public.profiles enable row level security;

-- SECURITY DEFINER so the lookup inside the policy does not re-enter RLS on
-- profiles, which would recurse. Fixed search_path so the function cannot be
-- redirected by a caller's search_path.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role in ('holistify_admin', 'super_admin')
  );
$$;

-- Supabase's default privileges on the public schema grant EXECUTE on new
-- functions to anon and authenticated, so revoking from PUBLIC alone leaves
-- those role grants in place. anon has no reason to call this; authenticated
-- must keep it, because RLS policy expressions run as the querying role.
revoke all on function public.is_admin() from public;
revoke execute on function public.is_admin() from anon;
grant execute on function public.is_admin() to authenticated;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists profiles_admin_write on public.profiles;
create policy profiles_admin_write on public.profiles
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ── Signed-in access to the audit data ──────────────────────────────────────
-- Added alongside the existing anon policies, not replacing them.
drop policy if exists auth_all_schools on public.schools;
create policy auth_all_schools on public.schools
  for all to authenticated using (true) with check (true);

drop policy if exists auth_all_audit on public.audit_states;
create policy auth_all_audit on public.audit_states
  for all to authenticated using (true) with check (true);

drop policy if exists auth_all_journey on public.journey_records;
create policy auth_all_journey on public.journey_records
  for all to authenticated using (true) with check (true);
