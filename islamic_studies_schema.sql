-- ============================================================
-- Holistify Islamic Studies App — Schema
-- Run this in Supabase SQL Editor (Database › SQL Editor)
-- ============================================================

create extension if not exists "uuid-ossp";

-- ============================================================
-- 1. PROFILES  (linked to auth.users via trigger)
-- ============================================================
create table if not exists is_profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  full_name   text default '',
  role        text not null default 'student' check (role in ('facilitator','student')),
  class_name  text default '',
  is_active   boolean default true,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- ============================================================
-- 2. CURRICULA
-- ============================================================
create table if not exists is_curricula (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  description text default '',
  created_by  uuid references is_profiles(id) on delete set null,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- ============================================================
-- 3. CURRICULUM CHAPTERS
-- ============================================================
create table if not exists is_curriculum_chapters (
  id                 uuid primary key default gen_random_uuid(),
  curriculum_id      uuid references is_curricula(id) on delete cascade,
  title              text not null,
  sequence           int default 0,
  learning_outcomes  jsonb default '[]',
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);

-- ============================================================
-- 4. LESSON PLAN FORMATS
-- ============================================================
create table if not exists is_lesson_plan_formats (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  sections    jsonb not null default '[]', -- [{key,label,guidance,order}]
  philosophy  text default '', -- facilitator's pedagogical approach/instructions given to the AI on every generation
  is_default  boolean default false,
  created_by  uuid references is_profiles(id) on delete set null,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- ============================================================
-- 5. LESSON PLANS
-- ============================================================
create table if not exists is_lesson_plans (
  id                  uuid primary key default gen_random_uuid(),
  curriculum_id       uuid references is_curricula(id) on delete set null,
  chapter_id          uuid references is_curriculum_chapters(id) on delete set null,
  format_id           uuid references is_lesson_plan_formats(id) on delete set null,
  title               text not null,
  chapter_name        text default '',
  learning_outcomes   jsonb default '[]',
  source_content      text default '',
  target_class        text default '',
  generated_sections  jsonb default '{}', -- {sectionKey: text}
  status              text default 'draft' check (status in ('draft','final')),
  created_by          uuid references is_profiles(id) on delete set null,
  created_at          timestamptz default now(),
  updated_at          timestamptz default now()
);

-- ============================================================
-- 6. STUDENT GOALS  (also the outcome-tracking record)
-- ============================================================
create table if not exists is_student_goals (
  id                 uuid primary key default gen_random_uuid(),
  student_id         uuid references is_profiles(id) on delete cascade,
  lesson_plan_id     uuid references is_lesson_plans(id) on delete cascade,
  learning_outcome   text default '',
  goal_text          text not null,
  target_date        date,
  status             text default 'active' check (status in ('active','achieved','missed')),
  achieved_at        timestamptz,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);

-- ============================================================
-- 7. REFLECTIONS  (student + facilitator authored)
-- ============================================================
create table if not exists is_reflections (
  id               uuid primary key default gen_random_uuid(),
  lesson_plan_id   uuid references is_lesson_plans(id) on delete cascade,
  goal_id          uuid references is_student_goals(id) on delete set null,
  student_id       uuid references is_profiles(id) on delete cascade, -- whose journal this reflection belongs to
  author_id        uuid references is_profiles(id) on delete set null,
  author_role      text not null check (author_role in ('facilitator','student')),
  reflection_text  text not null,
  created_at       timestamptz default now()
);

-- ============================================================
-- 8. REWARD DEFINITIONS  (Islamic-themed, auto-award rules)
-- ============================================================
create table if not exists is_reward_definitions (
  id            uuid primary key default gen_random_uuid(),
  key           text unique not null,
  title         text not null,
  description   text default '',
  icon          text default '⭐',
  trigger_type  text not null check (trigger_type in ('goals_achieved_count','reflections_count','manual')),
  threshold     int default 0,
  points        int default 0,
  created_at    timestamptz default now()
);

-- ============================================================
-- 9. REWARDS  (awarded instances)
-- ============================================================
create table if not exists is_rewards (
  id             uuid primary key default gen_random_uuid(),
  student_id     uuid references is_profiles(id) on delete cascade,
  definition_id  uuid references is_reward_definitions(id) on delete set null,
  title          text not null,
  description    text default '',
  icon           text default '⭐',
  points         int default 0,
  awarded_by     uuid references is_profiles(id) on delete set null, -- null = auto-awarded by the system
  awarded_at     timestamptz default now()
);

-- ============================================================
-- 10. SEED REWARD DEFINITIONS
-- ============================================================
insert into is_reward_definitions (key, title, description, icon, trigger_type, threshold, points)
values
  ('goals_1',  'First Step (Awwal Khutwah)', 'Set and achieved your first personal goal.', '🌱', 'goals_achieved_count', 1, 10),
  ('goals_3',  'Sabr Star', 'Achieved 3 goals through patience and consistency.', '⭐', 'goals_achieved_count', 3, 25),
  ('goals_10', 'Ihsan Circle', 'Achieved 10 goals — striving for excellence in every action.', '🕌', 'goals_achieved_count', 10, 75),
  ('refl_3',   'Tadabbur Beginner', 'Wrote 3 thoughtful reflections.', '📖', 'reflections_count', 3, 15),
  ('refl_10',  'Shukr Badge', 'Wrote 10 reflections — a heart practiced in gratitude.', '🤲', 'reflections_count', 10, 40),
  ('refl_25',  'Amanah Keeper', 'Wrote 25 reflections — trustworthy and consistent in self-review.', '🏅', 'reflections_count', 25, 100)
on conflict (key) do nothing;

-- ============================================================
-- 11. ROW LEVEL SECURITY
-- ============================================================
alter table is_profiles              enable row level security;
alter table is_curricula             enable row level security;
alter table is_curriculum_chapters   enable row level security;
alter table is_lesson_plan_formats   enable row level security;
alter table is_lesson_plans          enable row level security;
alter table is_student_goals         enable row level security;
alter table is_reflections           enable row level security;
alter table is_reward_definitions    enable row level security;
alter table is_rewards               enable row level security;

-- Helper: is the current user a facilitator?
create or replace function is_facilitator()
returns boolean language sql stable security definer as $$
  select exists(select 1 from is_profiles where id = auth.uid() and role = 'facilitator');
$$;

do $$ begin
  -- Profiles: everyone authenticated can read all profiles (needed for class rosters/reports);
  -- users can only update their own row.
  if not exists (select 1 from pg_policies where tablename='is_profiles' and policyname='is_profiles_select') then
    create policy "is_profiles_select" on is_profiles for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='is_profiles' and policyname='is_profiles_update') then
    create policy "is_profiles_update" on is_profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
  end if;

  -- Curricula / chapters / formats: readable by all authenticated, writable by facilitators only.
  if not exists (select 1 from pg_policies where tablename='is_curricula' and policyname='is_curricula_select') then
    create policy "is_curricula_select" on is_curricula for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='is_curricula' and policyname='is_curricula_write') then
    create policy "is_curricula_write" on is_curricula for all to authenticated using (is_facilitator()) with check (is_facilitator());
  end if;

  if not exists (select 1 from pg_policies where tablename='is_curriculum_chapters' and policyname='is_chapters_select') then
    create policy "is_chapters_select" on is_curriculum_chapters for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='is_curriculum_chapters' and policyname='is_chapters_write') then
    create policy "is_chapters_write" on is_curriculum_chapters for all to authenticated using (is_facilitator()) with check (is_facilitator());
  end if;

  if not exists (select 1 from pg_policies where tablename='is_lesson_plan_formats' and policyname='is_formats_select') then
    create policy "is_formats_select" on is_lesson_plan_formats for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='is_lesson_plan_formats' and policyname='is_formats_write') then
    create policy "is_formats_write" on is_lesson_plan_formats for all to authenticated using (is_facilitator()) with check (is_facilitator());
  end if;

  if not exists (select 1 from pg_policies where tablename='is_lesson_plans' and policyname='is_plans_select') then
    create policy "is_plans_select" on is_lesson_plans for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='is_lesson_plans' and policyname='is_plans_write') then
    create policy "is_plans_write" on is_lesson_plans for all to authenticated using (is_facilitator()) with check (is_facilitator());
  end if;

  -- Student goals: students manage their own; facilitators can read/write all (to set up goals for students & report).
  if not exists (select 1 from pg_policies where tablename='is_student_goals' and policyname='is_goals_select') then
    create policy "is_goals_select" on is_student_goals for select to authenticated using (auth.uid() = student_id or is_facilitator());
  end if;
  if not exists (select 1 from pg_policies where tablename='is_student_goals' and policyname='is_goals_write') then
    create policy "is_goals_write" on is_student_goals for all to authenticated
      using (auth.uid() = student_id or is_facilitator())
      with check (auth.uid() = student_id or is_facilitator());
  end if;

  -- Reflections: students manage their own journal entries; facilitators can read all and write for any student.
  if not exists (select 1 from pg_policies where tablename='is_reflections' and policyname='is_reflections_select') then
    create policy "is_reflections_select" on is_reflections for select to authenticated using (auth.uid() = student_id or is_facilitator());
  end if;
  if not exists (select 1 from pg_policies where tablename='is_reflections' and policyname='is_reflections_write') then
    create policy "is_reflections_write" on is_reflections for all to authenticated
      using (auth.uid() = student_id or is_facilitator())
      with check (auth.uid() = author_id and (auth.uid() = student_id or is_facilitator()));
  end if;

  -- Reward definitions: readable by all, writable by facilitators.
  if not exists (select 1 from pg_policies where tablename='is_reward_definitions' and policyname='is_rewarddefs_select') then
    create policy "is_rewarddefs_select" on is_reward_definitions for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='is_reward_definitions' and policyname='is_rewarddefs_write') then
    create policy "is_rewarddefs_write" on is_reward_definitions for all to authenticated using (is_facilitator()) with check (is_facilitator());
  end if;

  -- Rewards: students read their own; facilitators read/award all; the system (client, acting as the
  -- student on auto-award, or as the facilitator on manual award) can insert.
  if not exists (select 1 from pg_policies where tablename='is_rewards' and policyname='is_rewards_select') then
    create policy "is_rewards_select" on is_rewards for select to authenticated using (auth.uid() = student_id or is_facilitator());
  end if;
  if not exists (select 1 from pg_policies where tablename='is_rewards' and policyname='is_rewards_insert') then
    create policy "is_rewards_insert" on is_rewards for insert to authenticated with check (auth.uid() = student_id or is_facilitator());
  end if;

end $$;

-- ============================================================
-- 12. TRIGGER — auto-create profile on signup
-- ============================================================
create or replace function is_handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.is_profiles (id, email, full_name, role, class_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(new.raw_user_meta_data->>'role', 'student'),
    coalesce(new.raw_user_meta_data->>'class_name', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists is_on_auth_user_created on auth.users;
create trigger is_on_auth_user_created
  after insert on auth.users
  for each row execute procedure is_handle_new_user();
