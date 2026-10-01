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

User Management shows where each account stands: the table has an **Account**
column reading "Supabase Auth" or "This browser only", and the Supabase Auth
panel counts what is left. `pendingMigrationCount()` returns `null`, not `0`,
before the directory has been fetched — `getDirectory()` falls back to the local
accounts with no `_notMigrated` flag on them, so a plain count would read zero
and claim the migration was finished. That number is what the lockdown decision
rests on, so it says "unknown" rather than guessing.

The modal is reached from the sidebar inside a school (👥 Users) and from the
**User Management** tile on the admin hub. The hub tile is the one that matters,
because accounts are managed from the hub, not from inside an audit.

Two things had to be fixed before it would show at all, and both are easy to
reintroduce:

- `#login-screen` was missing its closing `</div>`, so the parser made
  `#users-modal-overlay` a *child* of it. Once signed in the login screen is
  `display:none`, which hid the modal with it — the click worked and the
  overlay got its `.open` class, but nothing appeared. It was the only element
  affected; everything after it still parsed to `body`.
- Its `z-index` was 1000, below `#home-screen` (8000). It is now 10600, above
  the hub, `#section-page` (8500), `#school-dashboard-overlay` (9000),
  `.mgmt-modal-overlay` (10000) and `#creds-overlay` (10500).

A modal that can open over the admin hub needs a z-index above 8000. The
generic `.modal-overlay` (1000) is fine only because it is used inside the
audit shell, which the hub covers anyway.

## Teachers imported with numbers for names

An early staff import took a serial-number column as the name, so teachers were
created called "2", "3", "4". `handleStaffUpload()` and `syncStaffToTeachers()`
now guard with `_isInvalidName()`, but records created before that fix are still
stored, and the real names are in `staffData`, which imported correctly.

`repairTeacherNames()` (banner + button on Teacher Performance, shown only when
`teacherNameIssues()` finds any) renames in place wherever `_uniqueStaffMatch()`
finds exactly one teaching-staff member with that qualification, so the teacher
keeps its id and any scores. It deliberately **never guesses**: where two staff
share a qualification it removes the record only if it has no scores and lets
the staff sync re-add it correctly. A record that cannot be matched but *does*
have scores is left alone for a human to rename — putting the wrong name on
someone's appraisal is worse than leaving a number.

## What syncs, and how

Everything auto-saves. Any edit calls `queueSave()`, which debounces 300 ms and
then runs `saveAuditState()`: localStorage, then an upsert of the whole
`_buildAuditSnapshot()` payload into `audit_states` via `syncAuditStateToCloud()`.
There is no manual save.

`_buildAuditSnapshot()` / `_applyAuditSnapshot()` are the single definition of
what a school's state *is*. Add anything new to both.

The modules that persist under their own localStorage key — School Records,
attendance, timetable, school structure, PD, lesson and curriculum plans, org,
docs — used to stop at the browser: their save functions wrote a key and
returned. They now end with `queueSave()` as well, so they ride along in the
same row. The debounce means a burst of module saves still produces one upsert.

Two things to keep in mind:

- `orgData` and `docsData` hold **every** school keyed by `schoolKey`, so the
  snapshot carries only this school's slice (`orgNodes`, `docsEntry`). Storing
  the whole object in a per-school row would let one school's load overwrite
  another's.
- `_applyAuditSnapshot()` writes each restored module back to its own
  localStorage key. The `load*Data()` helpers run again whenever their page is
  opened and read from those keys, so without that write-through a stale local
  copy would overwrite what just came from the cloud.

`loadAuditStateFromCloud()` calls `_applyAuditSnapshot(d, sid)` rather than
restoring fields itself. It used to carry its own shorter copy of the restore,
and since `loadAuditStateForSchool()` tries the cloud first and returns on
success, everything the copy had not been taught about — checklist comments,
every per-module key above — was saved to Supabase and then silently dropped on
the way back. Keep the restore in one function.

The sidebar Save/Load session buttons were removed once this was true: a manual
file backup of state the server already holds is a second source of truth and
another thing to go stale.

## Checklists

`CHECKLISTS` holds the five Holistify checklists; `customChecklists` holds
user-created ones. `getAllChecklists()` merges them, and a key present in
**both** is an *edited built-in*: the custom copy wins, but keeps
`builtin: true`, so it offers "Reset to original" instead of Delete.

Each item carries a tick, an optional mapping to an audit standard, and an
optional **comment** — the auditor's evidence note, saved on every keystroke by
`setClComment()`. That handler deliberately does not re-render: redrawing the
list would destroy the textarea being typed into.

Three stores are keyed by **position** — `clChecked`, `clComments` and
`clLinks`, all `"<checklistKey>-<itemIndex>"`. That is the thing to be careful
about when touching the editor:

- Rows in the edit modal carry `_from`, the position they held when the modal
  opened. `saveChecklist()` passes them to `_clRemapItemState()`, which moves
  each item's tick and comment to its new index. Without it, deleting one row
  slides every comment below it onto the wrong item.
- Each saved item also carries `origIdx`, its position in the built-in original.
  That is what `resetChecklist()` uses to put ticks and comments back when the
  override is discarded; state recorded against an item that only existed in the
  edited copy has nowhere to go and is lost (the confirm says so).
- Reset deliberately drops `clLinks` for that key, so items fall back to
  `CL_MAPPINGS_DEFAULT`. For an override those defaults are *never* consulted —
  the item at a given position may no longer be the one they describe — which is
  why mappings are stored on the override's items.

Editing a built-in used to save only the mappings and throw the reworded text
away, and a rename wrote a bare string to `customChecklists['<key>_label']`,
which rendered as an empty checklist called "undefined". Those entries are still
in saved rows, so `_sanitizeCustomChecklists()` drops anything that is not
`{label, items: []}` on load.

Item text and comments are user input going into `innerHTML`, so they go through
`_escHtml()`. Nothing passes item text through an `onclick` attribute any more:
`openLinkModalForCl(key, idx)` looks the text up, which also removed a
`decodeURIComponent()` that threw `URIError` on any item containing a bare `%`
("…show 75%+ for all students" among the built-ins).

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
