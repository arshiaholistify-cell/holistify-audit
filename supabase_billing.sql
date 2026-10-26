-- Billing the client schools, the admission-style enquiries from schools that
-- want an audit, and the follow-up queue that chases both.
--
-- Run this once in the Supabase SQL Editor.
--
-- ── Why the policies look like this ─────────────────────────────────────────
-- The anon key is published in the served HTML and is now inert: `schools`,
-- `audit_states` and `journey_records` carry only `authenticated` policies.
-- A new table with no policy of its own is therefore invisible to the app,
-- with no error to explain why — so these tables get theirs here.
--
-- But `authenticated` alone is NOT the right gate for this data. The existing
-- tables are open to any signed-in user because an auditor and a principal
-- both legitimately read the audit. These tables hold what every client school
-- is being charged: a principal of one school must not be able to read another
-- school's invoices, and an auditor has no business in any of it. So access is
-- restricted to the Holistify team, through a SECURITY DEFINER helper in the
-- same shape as the existing public.is_admin().

-- ── Who may see billing ─────────────────────────────────────────────────────
-- public.is_admin() already exists and covers holistify_admin + super_admin.
-- Billing is worked by the wider Holistify team, so this adds holistify_member.
--
-- SECURITY DEFINER so the profiles lookup inside the policy does not re-enter
-- RLS on profiles, which would recurse. Fixed search_path so the function
-- cannot be redirected by a caller's search_path. Both for the same reasons
-- is_admin() does it.
create or replace function public.is_holistify()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role in ('holistify_admin', 'holistify_member', 'super_admin')
  );
$$;

-- Supabase's default privileges grant EXECUTE on new functions to anon and
-- authenticated, so revoking from PUBLIC alone leaves those grants in place.
-- anon has no reason to call this; authenticated must keep it, because RLS
-- policy expressions run as the querying role.
revoke all on function public.is_holistify() from public;
revoke execute on function public.is_holistify() from anon;
grant execute on function public.is_holistify() to authenticated;

-- ── Billing contact on a client school ──────────────────────────────────────
-- The registry carries a principal and a contact email, which is who you talk
-- to about the audit. An invoice goes to whoever handles the money, and in a
-- school that is often somebody else.
alter table public.schools add column if not exists billing_name  text;
alter table public.schools add column if not exists billing_email text;
alter table public.schools add column if not exists billing_phone text;

-- The PAN and the postal address the invoice prints in its "To" block. Kept on
-- the school rather than typed per invoice, for the same reason the contact is.
alter table public.schools add column if not exists pan             text;
alter table public.schools add column if not exists billing_address text;

-- ── Invoices ────────────────────────────────────────────────────────────────
-- Two things deliberately NOT stored, the same as in the sibling app:
--   * "overdue" is never a status. It is computed from due_date and the
--     payments recorded, so a row cannot sit here claiming to be current a
--     month after it fell due.
--   * a balance is never stored. service_payments is the record; the balance
--     is derived by _blgTotals() in index.html, the one place that arithmetic
--     happens.
create table if not exists public.service_invoices (
  id           uuid primary key default gen_random_uuid(),
  invoice_no   text unique not null,
  school_id    text references public.schools(id) on delete set null,
  -- Copied onto the invoice rather than only joined: an invoice is a financial
  -- record of what was billed to whom, and has to stay readable after a school
  -- row is edited or removed.
  school_name  text not null,
  branch       text,                  -- campus, where the school has more than one
  billing_name  text,
  billing_email text,
  billing_phone text,
  service      text,                  -- "School Audit", "Transformation retainer"
  period       text,                  -- "Phase 1", "Apr–Jun 2026"
  description  text,
  amount       numeric(12,2) not null check (amount >= 0),
  discount     numeric(12,2) not null default 0 check (discount >= 0),
  tax_pct      numeric(5,2)  not null default 0 check (tax_pct >= 0),
  issued_on    date not null default current_date,
  due_date     date not null,
  status       text not null default 'open' check (status in ('open','paid','void')),
  po_ref       text,                  -- the school's purchase-order reference
  -- Copied onto the invoice for the same reason school_name is: an invoice is
  -- a record of what was billed to whom, and the PAN printed on the one that
  -- went out must not change when the school's registry row is corrected.
  client_pan     text,
  client_address text,
  notes        text,
  created_at   timestamptz default now(),
  updated_at   timestamptz default now(),
  created_by   text
);
create index if not exists service_invoices_due    on public.service_invoices (due_date) where status = 'open';
create index if not exists service_invoices_school on public.service_invoices (school_id);

-- ── The issuer's own details ────────────────────────────────────────────────
-- Everything the printed invoice says about Holistify rather than about the
-- school: the entity name, address and PAN, the bank account to pay into, who
-- signs, and the footer.
--
-- These live here and NOT in index.html, which is served to the public and
-- committed to a public repository. None of it is a secret the way a key is —
-- it is printed on every invoice Holistify sends — but the schools being
-- billed are a narrower audience than the open internet, and an account number
-- sitting in a public repo invites fraud attempts.
--
-- One row, enforced by the check: there is one issuer, and a second row would
-- be a second answer to "what does our invoice say".
create table if not exists public.billing_settings (
  id              integer primary key default 1 check (id = 1),
  issuer_name     text not null default 'Holistify ED – Initiatives Foundation',
  issuer_short    text not null default 'Holistify',
  issuer_address  text,
  issuer_pan      text,
  -- The series the paper invoices already use. _blgNextInvoiceNo() continues
  -- it; the number is also editable per invoice, so a fresh install can be
  -- started at the next number by hand rather than colliding at 0001.
  invoice_prefix  text not null default 'HSTP',
  bank_company    text,
  bank_name       text,
  bank_account    text,
  bank_ifsc       text,
  bank_branch     text,
  signatory_name  text,
  signatory_title text,
  signatory_org   text,
  signatory_place text,
  signature_url   text,               -- optional image; the name prints either way
  footer_address  text,
  footer_contact  text,
  updated_at      timestamptz default now(),
  updated_by      text
);

-- Fill it in the SQL Editor, not here: the real values must not be committed.
-- A missing row is not an error — the documents fall back to plain labels
-- rather than refusing to print — so an invoice raised before this is run says
-- "Holistify" and carries no bank block.
--
--   insert into public.billing_settings (id, issuer_address, issuer_pan,
--     bank_company, bank_name, bank_account, bank_ifsc, bank_branch,
--     signatory_name, signatory_title, signatory_org, signatory_place,
--     footer_address, footer_contact)
--   values (1, '…', '…', '…', '…', '…', '…', '…', '…', '…', '…', '…', '…', '…')
--   on conflict (id) do update set issuer_address = excluded.issuer_address, …;

-- ── Payments ────────────────────────────────────────────────────────────────
-- Schools pay audit fees in instalments, so this is a ledger, not a flag.
create table if not exists public.service_payments (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.service_invoices(id) on delete cascade,
  amount      numeric(12,2) not null check (amount > 0),
  paid_on     date not null default current_date,
  method      text,                   -- neft | upi | cheque | cash | card
  reference   text,                   -- UTR, cheque number
  recorded_by text,
  note        text,
  created_at  timestamptz default now()
);
create index if not exists service_payments_invoice on public.service_payments (invoice_id);

-- ── Enquiries from schools wanting an audit ─────────────────────────────────
create table if not exists public.service_enquiries (
  id             uuid primary key default gen_random_uuid(),
  school_name    text not null,
  city           text,
  board          text,
  contact_name   text not null,
  designation    text,                -- Principal, Trustee, Correspondent
  email          text,
  phone          text,
  interest       text,                -- audit | transformation | both | undecided
  source         text,                -- referral | website | event | call | existing client
  stage          text not null default 'new'
                 check (stage in ('new','contacted','proposal_sent','negotiating','won','lost')),
  quoted_amount  numeric(12,2),
  next_action_on date,
  owner          text,                -- the Holistify person carrying it
  lost_reason    text,
  notes          text,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
create index if not exists service_enquiries_stage on public.service_enquiries (stage, next_action_on);

-- Every touch, so whoever picks an enquiry up can see how it got here rather
-- than inferring it from one overwritten notes field.
create table if not exists public.service_enquiry_events (
  id          uuid primary key default gen_random_uuid(),
  enquiry_id  uuid not null references public.service_enquiries(id) on delete cascade,
  kind        text not null,          -- note | call | meeting | proposal | message_sent | stage_change
  detail      text,
  created_by  text,
  created_at  timestamptz default now()
);
create index if not exists service_enquiry_events_enq
  on public.service_enquiry_events (enquiry_id, created_at desc);

-- ── The follow-up queue ─────────────────────────────────────────────────────
-- Nothing is sent from the agent. A drafted message lands here and a person
-- approves it, then sends it from their own mail client or WhatsApp — this is
-- a static site with no server to send from, so the send is always a human
-- clicking a link. The queue is what makes that an approval step rather than
-- a pile of unreviewed drafts.
create table if not exists public.followup_outbox (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('invoice_reminder','enquiry_follow_up')),
  invoice_id  uuid references public.service_invoices(id) on delete cascade,
  enquiry_id  uuid references public.service_enquiries(id) on delete cascade,
  to_name     text,
  to_email    text,
  to_phone    text,
  subject     text,
  stage       text,                   -- due_soon | reminder | overdue | firm | final, or the enquiry stage
  body        text not null,
  status      text not null default 'draft'
              check (status in ('draft','approved','sent','skipped')),
  drafted_by  text,                   -- claude | template | human
  approved_by text,
  sent_via    text,                   -- email | whatsapp
  sent_at     timestamptz,
  created_at  timestamptz default now()
);
create index if not exists followup_outbox_status on public.followup_outbox (status, created_at desc);

-- One pending draft per invoice per escalation stage. The run is meant to be
-- done regularly; without this, running it each morning for a week leaves
-- seven identical unsent reminders for one school. A stage can be drafted
-- again once the earlier one has been sent.
create unique index if not exists followup_outbox_one_pending_invoice
  on public.followup_outbox (invoice_id, stage)
  where invoice_id is not null and status in ('draft','approved');

create unique index if not exists followup_outbox_one_pending_enquiry
  on public.followup_outbox (enquiry_id, stage)
  where enquiry_id is not null and status in ('draft','approved');

-- ── Row Level Security ──────────────────────────────────────────────────────
alter table public.service_invoices       enable row level security;
alter table public.service_payments       enable row level security;
alter table public.service_enquiries      enable row level security;
alter table public.service_enquiry_events enable row level security;
alter table public.followup_outbox        enable row level security;
alter table public.billing_settings       enable row level security;

-- No anon policies anywhere. The published anon key must stay inert, and
-- commercial data is the last thing that should have an exception made for it.
drop policy if exists hol_service_invoices on public.service_invoices;
create policy hol_service_invoices on public.service_invoices
  for all to authenticated using (public.is_holistify()) with check (public.is_holistify());

drop policy if exists hol_service_payments on public.service_payments;
create policy hol_service_payments on public.service_payments
  for all to authenticated using (public.is_holistify()) with check (public.is_holistify());

drop policy if exists hol_service_enquiries on public.service_enquiries;
create policy hol_service_enquiries on public.service_enquiries
  for all to authenticated using (public.is_holistify()) with check (public.is_holistify());

drop policy if exists hol_service_enquiry_events on public.service_enquiry_events;
create policy hol_service_enquiry_events on public.service_enquiry_events
  for all to authenticated using (public.is_holistify()) with check (public.is_holistify());

drop policy if exists hol_followup_outbox on public.followup_outbox;
create policy hol_followup_outbox on public.followup_outbox
  for all to authenticated using (public.is_holistify()) with check (public.is_holistify());

drop policy if exists hol_billing_settings on public.billing_settings;
create policy hol_billing_settings on public.billing_settings
  for all to authenticated using (public.is_holistify()) with check (public.is_holistify());

-- Check afterwards: a signed-in school principal should get [] from each of
-- these, and a Holistify admin should get rows.
--   select * from public.service_invoices;
