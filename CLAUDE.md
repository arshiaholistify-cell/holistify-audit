# Holistify School Audit Platform

Static site for school audits and transformation tracking. Deployed on Vercel as
`holistify-audit`.

## Shape of the codebase

No framework, no dependencies. Three standalone HTML files plus a short build
script:

- `index.html` — the audit platform itself
- `transformation-dashboard.html` — Holistify Transformation Dashboard
- `mentor-dashboard.html` — a redirect stub pointing at the transformation
  dashboard; it has no content of its own
- `build.js` — substitutes Supabase credentials into `index.html`, then copies
  the remaining static files into `dist/`
- `vercel.json` — `npm run build`, output directory `dist`

```bash
npm run build   # node build.js → dist/
```

**Worth knowing:** only `index.html` carries the credential placeholders.
`build.js` finds everything else by scanning the repo root against an extension
allowlist (`.html`, `.css`, `.js`, images, fonts), so a new static file is served
without touching the build script — but a new *extension* needs adding to
`SERVED`. The allowlist is deliberately not a denylist: it is what keeps `.env`,
`*.sql`, `package.json` and `build.js` itself out of `dist/`.

The build fails rather than warns when `SUPABASE_URL` / `SUPABASE_ANON_KEY` are
missing, or when a placeholder survives substitution. Both would otherwise
produce a site that loads fine and silently never reaches Supabase; failing
leaves the last good deploy live instead of replacing it with a broken one.

## Deployment

Vercel is the only deploy target: a push to `main` builds `dist/` and publishes
it to `audit.holistify.ai`.

The repo also published to GitHub Pages via `.github/workflows/deploy.yml` until
that workflow was removed. The two targets injected the same credentials from
different places (Vercel environment variables vs. GitHub Actions secrets) and
served different file sets, so they drifted apart and disagreed about what was
broken. If you find a stale `arshiaholistify-cell.github.io/holistify-audit/`
still serving, it is that retired deploy, not this one.

## Environment

```
SUPABASE_URL
SUPABASE_ANON_KEY
```

Substituted into `__SUPABASE_URL__` and `__SUPABASE_ANON_KEY__` in `index.html`
at build time. Only the anon key is used here, and it ends up in the served HTML
— so keep anything sensitive behind RLS rather than in this client.

## Accounts and authentication

Identity is **Supabase Auth**; role and scope live in `public.profiles`, keyed
to `auth.users(id)`. Login IDs are not email addresses, so each maps to
`<login_id>@audit.holistify.ai`. That domain passes Supabase's address
validation — a `.local` one is rejected outright — and nothing is ever sent to
it, because accounts are created pre-confirmed.

Creating a user needs the service-role key, so it happens in the
`admin-accounts` edge function (`supabase/functions/`), never in the browser.
Supabase injects the key into the function runtime. Every action there requires
a signed-in caller holding an admin role in `profiles`; `verify_jwt` alone is
not enough, because the anon key is itself a valid JWT.

`authSignIn()` tries Supabase Auth first and falls back to the old
`localStorage` store (`holistify_users`, plaintext passwords) for anyone not yet
migrated. Two things to keep in mind when touching it:

- A failed *profile* fetch is not a failed login. Treating a dropped request as
  a missing profile signs a valid user out and makes a correct password look
  wrong, so `_loadProfileUser()` distinguishes "no row" from "request failed".
- `localStorage` is scoped to the origin, so the legacy accounts do not follow
  the site to another domain or device. User Management can export and import
  them, and `loadUsers()` still lowercases stored IDs, because `doLogin()`
  lowercases what is typed.

### Where account lists come from

Two different reads, deliberately:

- `getUsers()` is the **local credential store** (`localStorage`). The sign-in
  fallback, export/import and the migration use it, because profiles rows carry
  no password.
- `getDirectory()` is what every **list and count** in the UI shows. Once signed
  in through Supabase Auth it returns `public.profiles` — the same on every
  device — merged with any local account not yet migrated, flagged
  `_notMigrated`.

This distinction matters: `localStorage` is per-browser and per-origin, so an
admin signing in on a new device saw empty auditor and coach lists even though
the accounts existed. Lists must read the directory; anything touching
passwords must read the local store.

`refreshDirectory()` runs after sign-in, after session restore, and after any
account is created, deleted or migrated. A failed fetch keeps the previous list
rather than blanking it.

### Password rules

New passwords must be at least 8 characters, enforced in the app and again in
the edge function. **Migration deliberately keeps the old 6-character floor**,
because it carries passwords people already have — rejecting them would strand
those accounts rather than make anything safer.

`generatePassword()` draws from `crypto.getRandomValues`, not `Math.random()`;
these become real auditor and coach credentials.

Leaked-password protection is a project setting, not something this repo can
turn on — it lives in Auth → Providers → Email and needs the Pro plan. When it
is enabled, Supabase reports a breached password either as `data.weakPassword`
on an otherwise successful sign-in or as a weak-password error, and
`authSignIn()` handles both: it warns the user in the first case and, in the
second, says the password is breached rather than falling back to the local
store and implying the credentials were wrong.

Note that three of the `DEFAULT_USERS` seed passwords (`consult123`,
`school123`, `staff123`) appear in HaveIBeenPwned. Rotate or delete those
accounts before enabling the setting, or their holders will be pushed onto the
fallback path.

### Migration state

`supabase_auth_migration.sql` is applied and is deliberately additive: the old
`anon` policies still sit alongside the new `authenticated` ones, so unmigrated
users keep working. **The migration is not finished until
`supabase_auth_lockdown.sql` is run**, which drops those anon policies. Until
then the anon key in the served HTML still grants full read/write to every
table, which is the hole this work exists to close.

Run the lockdown only once every account appears in `profiles` and has signed
in through Auth at least once.

## Assessment exports

The Analytics tab offers two downloads, both built from `_assessAggregates()`
— the same aggregation the screen renders from, so an exported file can never
disagree with what is on display. The 80 / 60 / 35 banding thresholds live in
that function and in `_band()`, nowhere else.

- **`.csv`** — the Assessment Breakdown table alone, one row per assessment.
- **`.xlsx`** — Summary, Grade Averages, Subject Performance, Standards
  Attainment, Assessment Breakdown, Skill Levels (one row per rubric × grade ×
  skill × level, with the student names) and Student Scores (one row per
  student per assessment, and per rubric criterion).

SheetJS is loaded from a CDN for reading uploads and is now used for writing
too. `downloadAssessmentBreakdownXlsx()` checks `typeof XLSX` first and points
at the CSV if the script did not load, rather than failing silently.

### CSV helpers

Every CSV export in the file goes through these — do not hand-roll another:

- `_csvCell(v)` quotes only when the value needs it (comma, quote, newline,
  edge whitespace) and doubles embedded quotes, so numeric columns stay
  numeric in Excel.
- `_csvFrom(headers, rows)` takes arrays; `_csvRows(rows)` takes objects and
  derives the columns from the first.
- `_downloadCsv(filename, csv)` builds the link, clicks it and releases the
  object URL.

The thirteen exports previously built CSV by concatenation and split into two
failure modes: some broke the row outright on an embedded quote, and others
replaced `"` with `'`, silently altering what had been typed. Both are fixed;
a name like `Smith, John "JJ"` now round-trips exactly.

## Database

`supabase_schema.sql` defines three tables:

- `schools`
- `audit_states`
- `journey_records`

## Conventions

Everything is inline — styles, scripts, markup in the same file. Match the
surrounding style rather than introducing a bundler or a framework; the
simplicity is the point of this repo.

DOM lookups here have historically thrown on pages where an element is absent
(the demo-accounts panel, for one). Guard `getElementById` results before using
them rather than chaining straight onto the result.
