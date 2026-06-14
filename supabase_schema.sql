-- Run this once in the Supabase SQL Editor (Database > SQL Editor > New query)

-- Schools registry
create table if not exists schools (
  id text primary key,
  name text not null,
  city text default '',
  board text default '',
  created_at timestamptz default now()
);

-- Audit state per school (full JSON blob)
create table if not exists audit_states (
  school_id text primary key references schools(id) on delete cascade,
  school_name text,
  data jsonb not null default '{}',
  updated_at timestamptz default now(),
  updated_by text
);

-- Journey records per school
create table if not exists journey_records (
  id text primary key,
  school_id text references schools(id) on delete cascade,
  date date,
  type text,
  summary text,
  agenda jsonb default '[]',
  created_at timestamptz default now()
);

-- Enable Row Level Security
alter table schools enable row level security;
alter table audit_states enable row level security;
alter table journey_records enable row level security;

-- Open policies for anon access (tighten later with Supabase Auth)
create policy "anon_all_schools" on schools for all to anon using (true) with check (true);
create policy "anon_all_audit" on audit_states for all to anon using (true) with check (true);
create policy "anon_all_journey" on journey_records for all to anon using (true) with check (true);
