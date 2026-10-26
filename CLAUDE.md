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
There are three functions now, all there for the same reason — a secret that
cannot be in a page served to the public: `admin-accounts` (the service-role
key), `behaviour-prose` and `billing-followups` (the Anthropic key).
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

`DEFAULT_USERS` is now **empty**, and must stay that way. It used to seed four
demo accounts into `localStorage` on any browser that had none; three of their
passwords were in HaveIBeenPwned and the admin one granted the full admin UI, so
a fresh browser was handed four known credentials. The passwords are not
repeated in the source, because `index.html` is served to the public.

A browser with no local store therefore has no fallback accounts at all, which
is the correct state now that identity is Supabase Auth. Use **Import accounts**
if a local set is genuinely needed.

The `principal` and `staff` demo accounts were deleted from Supabase and
`consultant` was given a fresh generated password; only `admin`, `consultant`
and the seven auditors remain in `profiles`.

### Migration state — complete

Both `supabase_auth_migration.sql` and `supabase_auth_lockdown.sql` are applied.
`schools`, `audit_states` and `journey_records` now carry **only** the
`authenticated` policies; the three `anon_all_*` policies are dropped.

Verified after the lockdown: an anonymous request carrying the key from the
served page returns `[]` on all three tables and is refused (401, RLS) on write,
while `admin` and a plain non-admin account both still read everything.

**The anon key in `index.html` is now inert**, which is what the whole exercise
was for — but that also means anything new must be reachable by a signed-in
user, not by the anon role. A new table needs its own `authenticated` policy or
the app simply sees nothing, with no error to explain why.

To undo in an emergency, re-create the three policies
`for all to anon using (true) with check (true)`.

User Management shows where each account stands: the **Account** column reads
"Supabase Auth", "This browser only", or "Not checked", and the Supabase Auth
panel counts what is left.

"Not checked" is the important one. `_directory` is only populated when there is
a real Supabase session (`_authSessionActive`), and `getDirectory()` otherwise
falls back to the local accounts, none of which carry `_notMigrated`. Read
naively that looks like "everyone is migrated" — the one wrong answer this
column must never give, since it is what the lockdown decision rests on. So
`pendingMigrationCount()` returns `null` rather than `0`, and the table renders
"Not checked" rather than green.

Signing in through the localStorage fallback produces exactly that state, and
it is easy to land in: `authSignIn()` tries Supabase first and falls back
silently, so an admin whose local password differs from their Supabase one is
signed in but has no session. The panel now says so and says what to do, rather
than waiting for the migrate button to fail with a toast.

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

## Branches

A school's identity is `schoolKey(name)` — every localStorage key, the `schools`
row and the `audit_states` row all derive from it. **So a branch has to be part
of the name**, or two campuses of one school would share one key and silently
overwrite each other's audit.

The branch is therefore stored twice, deliberately: joined into `name`, which is
what everything keys on, and kept separately on the record as `branch` so the UI
and the reports can say "Shaheen School, Golekhana branch" rather than printing
the joined string. `joinBranch()` / `splitBranch()` are inverses around
`BRANCH_SEP`, and `_hubBase()` / `_hubBranchOf()` recover both from a record
written before the field existed.

**A school with no branch joins to exactly its own name**, so every audit saved
before this existed keeps the key it already had — `Iqra School` is still
`iqra_school`. That is the property to preserve in any change here; breaking it
orphans live Supabase rows with no error to explain where the data went.

Each branch is its own hub entry with its own audit, because that is what a
branch needs. The hub's duplicate check runs on the joined name, so a second
branch of the same school is allowed where a second entry of the same single
campus still is not. Cards show the school name with the branch beneath it, and
the grid sorts by school then branch so campuses of one school sit together.

`currentBranch()` / `currentBaseSchool()` read the topbar's joined value; the
topbar shows the branch as a chip rather than one long string, and the reports
print it as the **Campus** row of the School Information table and on the cover,
as the published format does.

## How a score is built, and where the weightage is shown

Two steps, and `_wtStats(domainId)` is the only place either is computed, so no
card, panel or report can disagree with another about them:

1. **A domain's percentage** is the average of the standards you have *scored*,
   out of 4. An unscored standard is **not a zero** — it is not counted yet.
   This is what `domainScore()` has always done; it was just never explained.
2. **The Quality Score out of 100** is each domain's percentage times that
   domain's weight. The seven weights sum to 100: **CPA carries 40**, the other
   six carry 10 each.

The pages used to print the percentage and the weight and leave the reader to
infer the rest. Two things follow from the arithmetic that nobody could guess
from a bare percentage, and both are now stated on screen:

- **One level, on one standard, is worth a knowable amount** — `25/scored` of
  the domain percentage, and `weight/(4 × scored)` of the Quality Score. That
  second figure is *inverse to the number of standards*, so among the six
  10-point domains it ranges from **0.36 pts** on External Development (7
  standards) to **0.069 pts** on Vision & Culture (36). CPA carries the most
  weight overall and is still only 0.13 pts a level, because its 40 points are
  spread across 75 standards. `_wtTotalPanel()` ranks this explicitly, because
  "where does an hour of work buy the most?" is not answerable from a weight
  column alone.
- **Scoring more standards can push the percentage down while pushing the
  points up**, since the denominator grows. One standard at Level 4 reads 100%.
  `_wtPanel()` says so wherever a domain has unscored standards left.

`_wtStats()` returns `earned` (points contributed now), `headroom` (points
still available here), `perLevelPct` / `perLevelPts`, and `steps` / `stepsPts`
(the level-steps still open on what is already scored, and what they are worth).

Where it appears:

| Place | What it shows |
|---|---|
| Audit page header | `worth 10 of the 100 points · 12 scored · 58% · contributing 5.8 pts` |
| Audit page, `_wtPanel()` | the five figures, then how to raise them, in this domain's own numbers |
| Overview metric card | the Quality Score, plus **points still available** |
| Overview domain card | `58% × 10 pts = 5.8 pts` and `0.21 pts / level` |
| Overview domain bars | each domain's contribution beside its percentage |
| Overview + Score Report | `_wtTotalPanel()` — every domain's weightage in one table, with a total row |
| SIP domain tile and detail | the same figures, so the plan and the audit agree |

## The SIP, read by domain

The plan is organised by **phase**, which is the right shape for "what do we do
this term" and the wrong shape for "what does the plan say about our
curriculum?" — whose answer was scattered across six collapsed phase cards.

So the same plan is also reachable by domain. `renderSipDomainNav()` draws a
tile per domain (score, contribution, a bar and an action count);
`showSipDomain(id)` opens one, and `renderSipDomainDetail()` shows that
domain's whole three-year thread in phase order, with its weightage explainer,
the standards scored Level 1–2 that the plan is built from (each with what the
next level reads like), and a button through to the audit page.

Three properties to preserve:

- **Nothing is recomputed.** `_sipDomainThread()` reads the same
  `sipData.phases` the phase cards read, down a column instead of across a row,
  so the two views cannot disagree and the focus/density filters apply to both.
- **The progress keys are the same.** `_sipActionHtml()` is the one action-card
  builder, and both views derive `globalIdx` identically — by counting actions
  across a phase's domain groups in order — so an action ticked in one view is
  ticked in the other. Rendering the domain view with its own index would
  silently split `sipProgress` in two.
- **One view at a time.** `showSipDomain()` hides `#sip-timeline-card` and
  `#sip-phases` while a domain is open, and `generateSIP()` rebuilds the nav
  and detail, so a regenerate cannot leave the tiles counting the previous
  plan's actions. Its zero-score branch now also clears `sipData`, which it
  used to leave stale.

A domain with no actions says *why* — nothing scored yet, already averaging
Level 3.5+, or excluded by the filter — rather than rendering an empty list.

`buildSipActions()` set `domainColor: dom.color`, but a DOMAIN carries `ic`,
not `color`. Every `color:${dg.color}` in the plan was rendering
`color:undefined`.

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

## School Records ↔ School Documents

A record marked compliant is a *claim*; the file in School Documents is the
*evidence*. The two modules held that pair apart, so an audit could record
"Attendance Registers — Compliant" with nothing behind it and no way to find
the document.

`recordsOverrides[id].docs` is a list of `{folder, name}` **references, never
copies**. School Documents stays the one place a file lives, so deleting it
there is not silently contradicted by a record still claiming it: `_recEvidence()`
resolves each reference against Documents as it stands now and marks a vanished
file `exists: false`, which the row shows as **missing**. That is the honest
answer and the one an auditor needs — a reference to a file that is gone
evidences nothing, so `_recHasEvidence()` ignores it.

- The records table has an **Evidence** column: a chip per file, opening
  Documents at that folder, plus **+ Attach**.
- `openRecordAttach()` lists every folder and file for the school being audited.
  `_recDocsKey()` resolves the same key `renderDocsPage()` does, so the Records
  page can read Documents without rendering it first.
- **Upload into a folder straight from the record**, which files it in Documents
  and attaches it in one step, rather than requiring a trip there and back.
- The compliance bar reports **Evidenced: n of m** beside the headline, and
  names the records marked compliant with nothing attached. A compliance figure
  that counts unevidenced claims overstates the school.
- The reverse link: a file in Documents shows the records it evidences, and
  deleting it names them in the confirm, so the person tidying up can see what
  they are about to break.
- `exportRecordsCSV()` carries an Evidence column, with `(MISSING)` against a
  reference that no longer resolves.

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
- **`.xlsx`** — Summary, Grade Averages, Skill Performance, Standards
  Attainment, Assessment Breakdown, Skill Levels (one row per rubric × grade ×
  skill × level, with the student names) and Student Scores (one row per
  student per assessment, and per rubric criterion).

  Two sheets both say "skill" and mean different things: **Skill Performance**
  is the `Subject · Skill` card grouping below, one row per card; **Skill
  Levels** is per rubric *criterion*, which is the finer-grained thing the
  rubric editor calls a criterion.

SheetJS is loaded from a CDN for reading uploads and is now used for writing
too. `downloadAssessmentBreakdownXlsx()` checks `typeof XLSX` first and points
at the CSV if the script did not load, rather than failing silently.

### Attainment bands carry their level

The four attainment bands are the same four levels the audit standards and the
rubrics are scored on, so each band carries its level: **Below is Level 1 and
Exceeding is Level 4**. `_attainmentLabel(pct)` returns `{label, level, css}`,
and the level is decided there because that is the only place the band is
decided — as the 80 / 60 / 35 thresholds are. `_bandLevel(pct)` and
`_BAND_LEVEL` give the same mapping from a percentage or from the short band
word `_band()` returns. No data returns `level: null`, never `0`.

In the exports the column is called **`Attainment Level`**, not `Level`. The
Skill Performance sheet already carries `Average Level` and `Level 1`…`Level 4`
meaning the *rubric's* own scale, so a bare `Level` there would be two different
things under one name — the same class of ambiguity as the two sheets that both
say "skill".

### Rubrics

`rubrics` holds the definitions; `rubricScores` holds the student responses,
**keyed by rubric id** (`{ rubricId: [{name, grade, scores, …}] }`). That key is
the thing to be careful with:

- `saveRubric()` keeps the existing id when editing. It used to mint a fresh
  `'rb_'+Date.now()` on every save, so editing a rubric orphaned every response
  recorded against it — the rubric came back empty and the old scores stayed in
  `rubricScores` forever, unreachable, because every list and export iterates
  `rubrics`.
- `deleteRubric()` removes the responses along with the rubric, for the same
  reason, and says how many are going in the confirm. `clearRubricResponses()`
  is the separate action that keeps the rubric and drops only its responses.

`renderRubricResponses()` calls `loadRubricScores()`, which re-reads
`rubricScores` from localStorage — so anything mutating it in memory must call
`saveRubricScores()` before a repaint, or the change is discarded.

#### Reading a score: `_rubricLevel()`

**A stored score is not necessarily a number**, and every read goes through
`_rubricLevel(raw, criterion, scale)` — never `parseFloat`/`parseInt` directly.
The manual scorer writes `"3"`, but a Google Form records the *descriptor the
teacher picked*. Some rubrics number their descriptors (`"2: Reads slowly with
frequent pauses"`) and some do not (`"Reads most gunitaksharas correctly but
slowly"`), so reading everything with `parseFloat` scored the unnumbered ones
`NaN || 0` — a whole rubric averaging 0.0 and counting as "Not scored" in
analytics and every export, with nothing on screen suggesting a problem. Three
of one school's eight rubrics, 961 real assessments, read as zero.

It resolves in order: a plain number; a leading level prefix (`"2. "`, `"1: "`,
`"3 - "`); an exact match against that criterion's own `descriptors`; then, for
a multi-select answer holding several descriptors comma-joined, the lowest level
ticked. Matching collapses whitespace and ignores case, because a descriptor
typed into the rubric editor keeps a trailing newline the form's copy of the
same sentence does not — that one character was the whole mismatch.

It returns `null`, never `0`, for blank or unresolvable. `null` means *not
scored*: `_rubricRespAvg()` leaves those criteria out of the average rather than
counting them as zeros, and callers skip the response instead of recording a 0%.

What it deliberately does **not** do is guess. A descriptor worded differently in
the form than in the rubric (`"Recognizes"` vs `"Recognises"`) stays unscored and
shows as `—`; fuzzy-matching it would put a wrong level on a child's screening
result. Fix the wording on one side instead.

### Importing scores

The Assessment page has two kinds of score and **one importer each**, reached
from the tab they belong to — the tabs are what say which kind you mean, so
nothing asks again:

| Tab | Button | Importer |
|---|---|---|
| Score-based | ⬆ Upload scores, and ⬆ Upload on each assessment card | `openScoreImport()` — marks out of a maximum |
| Rubric-based | ⬆ Import scores, and on each rubric card | `openGFormImport()` — levels 1–4 |

Both accept the same three sources and share `_sniffBytes()`,
`_sheetsWithRows()`, `_fetchImportSource()` and `_csvParse()`. Opened from a
card, the rubric or assessment is preselected; from the tab header the choice
stays open unless there is only one.

`openGFormImport()` was once labelled "📥 Google Form" and lived only in the
page header, so the Excel and Drive routes were unfindable and the rubric tab —
where anyone would look — had no import at all. The name was also a promise it
no longer kept.

**Marks import** (`openScoreImport`): the old `handleAssessmentUpload()` read
every file with `readAsText`, so an `.xlsx` — which its file input accepted —
parsed as binary rubbish; it split CSV on bare commas, so a name like
`"Khan, Ayesha"` broke the row; and it always invented a new assessment with
`maxMarks: 100` regardless of the file. The replacement maps columns with a
preview, **warns before importing** about marks that are not numbers, are above
the maximum, or are missing, skips the unusable ones, matches on roll number
then name so a re-import updates rather than duplicates, and infers a new
assessment's maximum from the data.

### Rubric score import

Rubric responses come in through `openGFormImport()`. Two paths, both ending in
`_gfiAccept()` → `_csvParse()` → `_buildGfiMapper()`:

- **Upload a file** — `.xlsx`/`.xlsm`/`.xls`/`.ods` or `.csv`. The reliable one,
  and what the panel recommends: no network, so publishing, sharing and CORS are
  all irrelevant. A workbook is converted sheet-by-sheet to CSV text with
  `XLSX.utils.sheet_to_csv()` and handed to the same parser, so column mapping,
  the preview and Replace/Add behave identically whichever file was picked.
  Sheets with no rows below their headings are skipped, and a book with more
  than one sheet of data gets a picker — which lives in **step 2**, beside the
  preview, because loading a file jumps straight there and a picker left on
  step 1 could never be reached. Without SheetJS (CDN blocked) it says so and
  points at CSV rather than failing silently.
- **A Google Drive link.** `_gfiDriveUrl()` turns any Drive share link
  (`/file/d/<id>/view`, `/open?id=`, `/uc?…id=`) into
  `drive.usercontent.google.com/download?id=…&export=download`. That host —
  unlike the classic `drive.google.com/uc`, which 403s and sends no CORS headers
  — answers a preflight with `access-control-allow-origin: *`, so a file shared
  **Anyone with the link** really can be read from the browser. A link to a
  *folder* is detected and explained rather than fetched.

  `_gfiDriveUrl()` parses the **hostname** rather than pattern-matching the URL.
  An earlier regex anchored on `(^|\.)` before `drive`, which never matched a
  real link, because the hostname follows `//` and not a dot.

- **A published Google Sheet URL.** `_gfiCsvUrl()` turns an ordinary
  `/edit#gid=` share link into a `gviz/tq?tqx=out:csv` export and a `pubhtml`
  link into `pub?output=csv`, because the share link is the one people have
  open and it returns HTML. It still only works for a sheet **published to the
  web** — a sheet that is merely shared by link cannot be read cross-origin,
  and `fetch()` rejects with a bare `TypeError` that hides whether it was CORS
  or the network. The error text says so and points at the upload instead of
  repeating "check the URL".

`_gfiFromBytes()` is the single entry point for file bytes, whoever produced
them — an upload or a Drive download. It **sniffs the format** (`PK` → xlsx/ods,
`D0 CF` → legacy xls, otherwise UTF-8 text) rather than trusting a filename,
because a Drive response has no reliable name and a `.csv` is sometimes really a
workbook. Google's virus-scan interstitial and a "not shared" page both arrive
as HTML and are reported as such rather than parsed as data.

`_csvParse()` is a real parser: CRLF, BOM, quoted fields containing commas or
newlines, doubled quotes, and duplicate headers made unique. The import used to
`split('\n')` then `split(',')`, which mangled exactly what a form collects —
any answer with a comma shifted every column after it, and any multi-line answer
broke the row in half. Use it for any new CSV reading; `handleClUpload()` still
hand-rolls its own and should move over.

Column headers and cell values are form content going into `innerHTML`, so they
go through `_escHtml()`.

The preview step offers **Replace** (the default) or **Add**. Replace exists
because the import is a pull, not a live link: responses keep arriving in Google
and the sheet has to be imported again, and a plain append turned the second
import of a 20-row sheet into 40 rows, silently skewing every average and
export. Replace drops rows with `source === 'google_form'` and keeps everything
else, so students scored in the app through `saveRubricScoresManual()`
(`source: 'manual'`) survive — they are not in the sheet, so treating the sheet
as the whole truth would delete that work without saying so. The radio's note
counts both before you choose.

### Bulk upload

**⬆⬆ Bulk upload** on the Score-based tab takes every workbook at once and asks
nothing it can read for itself. `openBulkImport()` → `bulkUploadFiles()` →
`_bulkIngest()` per file → `_bulkScanSheet()` per sheet, into one preview.

It extracts **five things: the student's name, roll number, grade, the mark
scored and what it was out of.** Entries are stored as
`{name, roll, grade, score}` and nothing else; remarks and section columns are
ignored.

**Most of these sheets carry only the name and the mark**, so what the file
does not say is taken from the roster — see **Roll numbers and grades from the
roster** below. The preview says which of the two is happening before anything
is imported.

**A `Sl. No` serial is never taken for a roll number.** The roll column is found
by its heading alone, because by value a roll is indistinguishable from the
serial in column A — and a serial renumbers whenever a student is added, so
taking one for an identity writes one child's marks onto another on the next
import. Re-import matches on roll where there is one and name otherwise, since
two children can share a name.

`_bulkGradeValue()` normalises whatever the office typed — `3`, `III`,
`Class V`, `5th`, `Grade 3`, `UKG` — onto the one label `GRADES_ORDER` uses,
or Grade Averages treats "3" and "Grade 3" as two cohorts. Per-row grade wins,
then the sheet name, then the file name; the preview says which, and the grade
is editable where none was found.

**A grade column needs its values to read as grades; its heading alone is never
enough.** "Class" is also what many sheets call the *section*, and filing a
child into Grade 2 because their section is B is worse than leaving them
ungraded. So a column headed grade/class/std is taken when **any** value
resolves, and a column without such a heading only when **every** filled value
does.

`_bulkScanSheet()` tries `_wideScan()` first, so a sheet of six skill columns
becomes six assessments exactly as the wide importer makes them; otherwise
`_bulkSimpleScan()` finds one name column and one marks column, choosing the
marks column **by its values** (mostly numeric) with a nudge for a heading
saying mark/score/obtained, never by heading alone.

The maximum is taken in the order worth trusting and the preview says which was
used: the column heading (`Oral Test - 15 Marks`), then a `Max Marks` / `Out of`
column, then **nothing**. A sheet that never states its maximum is left blank
and the import is refused until it is answered — the highest mark is only ever
a lower bound, and guessing from it silently inflates every percentage.

**A maximum corrected on one row is corrected on every row of the same
assessment.** The workbook that prompted this repeats each test once per grade,
so fixing the same wrong heading three times is three chances to fix it
differently; `_bulkSetMax()` applies by name and says how many rows it set, and
the preview marks those rows "all 3". Same reasoning as the wide importer
holding its maxima by column label.

Everything imports as `ASSESS_TYPE_SCREENING`, and re-uploading matches on name
and grade so a corrected workbook **updates** rather than doubling every average
built from it.

### Roll numbers and grades from the roster

A real workbook imported 2,900 marks with **not one roll number**, because the
sheets did not have a roll column — the office exports names and marks and
nothing else. The Roll No. and Grade columns of the score table read `—` all
the way down, and Grade Averages had nothing to group by.

The school's roster already holds both for all 308 of its students, on the
Students page. So `_fillFromRoster(entries, idx)` fills what the sheet did not
say, and `_rosterIndex()` builds the lookup:

- **Blanks only.** Whatever the sheet itself stated always wins — the sheet is
  the record of what was administered, the roster is a lookup.
- **Exact name match**, on `_rosterKey()` (lower-cased, whitespace collapsed).
  It never guesses: "Rushda Fatihma" is not matched to "Rushda Fatima",
  because putting one child's roll number on another child's marks is the same
  class of mistake as reading a serial column as a roll. On the live data 215
  of 275 names match; the other 60 stay blank and are counted.
- **A name two students share identifies nobody** and is dropped from the
  index.
- An assessment whose rows all end up in one grade is **filed under that
  grade**, so a file that never stated a grade still reaches Grade Averages
  and the grade filter. Same rule `_bulkRow()` applies in the preview.

All three importers call it (`bulkImport`, `siImport`, the wide path), and each
toast says how many values came from the roster rather than the file.

For data already imported, `_rosterBanner()` + `fillScoresFromRoster()` do it
in place — the banner appears on the Score-based tab only when `_rosterGaps()`
finds rows the roster can fill, and says how many it cannot. Same
banner-and-button shape as `repairTeacherNames()` and `relabelScreening()`, and
for the same reason. **No re-upload is needed**, which is the point: the
numbers were imported correctly, only the identity columns were missing.

Rubric responses are deliberately **not** included: they already carry a grade
and show no roll number.

### The same child, spelled two ways

A screening result is matched to a child **by name**, because the sheets carry
nothing else. So a form that spells a name differently from the marks sheet
creates a second child holding that one result, and the report prints a dash
where the skill should be.

On Iqra's live data that is most of the Kannada screening: the Kannada forms
spell `Mohammad`, the English forms and the bulk imports spell `Mohammed` or
`Md`, and **121 Kannada results** sit against children who appear nowhere else.
`Sumaiya` / `Sumaiyya` / `Summaiya` splits one child three ways in the
non-Kannada sources alone. In Grade 1 only 8 of 34 children had a complete
record.

`_nameBanner()` + `openNameMerge()` + `applyNameMerge()` are the
banner-and-button, on both Assessment tabs because a split child is usually
split *across* them. **Nothing merges on its own**: it proposes, the author
unticks anything that is genuinely two children and picks which spelling to
keep, and only then are names rewritten — same shape as `repairTeacherNames()`
and `relabelScreening()`, and for the same reason.

How a pair is proposed, and why each part is there:

- **`_nmCanon()`** lower-cases, drops punctuation, maps each word through
  `_NAME_ALIAS` and **sorts the words**. Sorting because the sheets do swap
  given and family names; within one grade the same words in a different order
  are one child.
- **`_NAME_ALIAS` is short and only for forms of one name** — the Muhammad
  family (`Md`, `Mohd`, `Mohammed`, `Muhammad` …) and `Fathima`/`Fatima`. `Md`
  and `Mohammed` are three edits apart and the same person, so no distance test
  would ever pair them. **`Syed`/`Syeda` is deliberately absent**: it is
  gender-marked, and collapsing it would propose merging a brother and a sister
  who share a second name.
- **`_nmNear()` compares word by word, never the flattened string.** This is
  the part that matters. Measuring the whole name, `Fathima Zahra` and
  `Zaina Fathima` are two edits apart — `fatima zahra` against `fatima zaina`
  — and the first cut proposed them as one child, because the word they share
  padded the length and hid that the word that matters changed completely. They
  are two girls in Grade 1. So each word must be identical or **one edit** from
  its partner, and at most two words may differ. One edit is a dropped letter
  or a typo (`Shaikh`/`Shaik`, `Rayan`/`Ryan`, `Umna`/`Yumna`); two edits
  inside a five-letter given name is a different name. Where the word *counts*
  differ the only case worth taking is a lost space (`Murtuja Sab` written
  `Murtujasab`), which is one edit on the flattened string, so that one is
  measured whole.
- **Groups never cross a grade.** Two children of one name in different grades
  are different children — the rule `_rptScreeningResults()` already keys on.
- Union-find, so `Md Saqib`, `Md Saquib`, `Mohammad Saquib` and
  `MOHAMMED SAQIB` form one group rather than overlapping pairs.
- The spelling proposed to keep is the roster's, then the one with the most
  results, then one that is **not SHOUTED** (the all-caps spellings come from
  the machine exports), then the longer one — `Mohammed` over `Md`.

`applyNameMerge()` rewrites `name` on the matching rows of `scoreEntries` and
`rubricScores` and saves both. A plan entry applies **only in the grade it was
proposed in**, so a name used in two grades is never rewritten in the grade
nobody reviewed. The scores themselves are never touched, and the confirm says
how many spellings and how many recorded results are about to change.

On Grade 1's real 41 spellings it proposes 11 groups covering 27 of them, and
leaves `Taimur Khan`, `Hassan Bin Sajid`, `Kaifa Maheen` and `Zohra` alone.

### The student data as a workbook

`downloadStudentsXlsx()` (**⬇ Excel (.xlsx)** on the Students page, beside the
CSV) is the roster and the screening data in one file. It exists because the two
are different lists of children and the distance between them is the question
it gets opened to answer: Iqra has **308 students on the roster, 303 distinct
names**, while its assessment data carries **660** — roughly twice the roster
in every grade, which is spellings, not extra children.

So the workbook does not just dump the roster. Six sheets:

| Sheet | What it holds |
|---|---|
| Students | the roster as it stands, plus what each child was screened on |
| Screening results | one row per child per skill — the unit the reports use |
| Screened students | one row per child, a column per skill |
| Coverage | the two counts, and how far they reconcile |
| Not screened | roster students with no screening result |
| Not in roster | screened names the roster does not hold |

It reads `_rptScreeningResults()` and `_rptStudentIndex()`, so the workbook and
the screening reports cannot disagree about who was screened or at what level
— duplicates are consolidated the same way, the lower level standing, and
grades go through `_rptGrade()`.

Four things decided here:

- **It reconciles; it never merges.** The Coverage sheet counts what matches and
  the two list sheets name what does not, and the "why" row points at
  **🧠 Review the names** on the Assessment page. Proposing a spelling match in
  a file nobody can correct would put one child's results against another's
  name — the same reasoning as `repairTeacherNames()` and `relabelScreening()`.
- **Names are exported exactly as stored**, not through `_rptName()`. The
  reports sentence-case for the reader; here the name is the key that matches a
  child to the roster, and re-casing it would hide the mismatch the Coverage
  sheet exists to show.
- **A roster child whose results were filed under two grades is one row on the
  Students sheet and two on Screened students.** A marks sheet carries no
  identity but name and grade, so the assessment data genuinely holds two
  children; the roster is the one list that knows better, so that sheet unions
  their skills and names the other grades in a **Grade in the sheets** column
  rather than averaging the split away.
- **A grade the sheets and the roster disagree about is reported, not
  resolved.** Which is right is the school's call about its own forms.

Roster lookups go by name alone, so a child is found whatever grade the sheet
filed them under, and a name two roster students share identifies nobody — the
rule `_rosterIndex()` already applies.

#### The roster writes its grades differently from the sheets

Iqra's roster stores grades as **bare numbers** — `1`, `2`, … `10` — while every
assessment sheet and Google Form says `Grade 1`. So `_rosterIndex()` now hands
out `_rptGrade(st.grade)` rather than the raw string, which fixes two things at
once:

- **A fill from the roster wrote a label nothing else uses.** `_fillFromRoster()`
  put `3` into a score row's grade, and Grade Averages then read "3" and
  "Grade 3" as two cohorts — the one thing `_bulkGradeValue()` exists to
  prevent. Every caller of the index fills grades, so normalising there fixes
  `bulkImport`, `siImport`, the wide path and `fillScoresFromRoster()` together.
- **The workbook compares grade to grade.** Without it, every row of the
  Students sheet would report a disagreement between `3` and `Grade 3`.

The **stored roster is not rewritten** — the Students page still shows and
filters what the school typed. A label `_rptGrade()` cannot resolve is kept
exactly as typed, so a typo stays visible rather than being filed under a guess.

### Headings: an underscore is a word character

`_hdrNorm()` normalises a heading by reading `_` as the space it stands for,
and all four header predicates (`_wideIsRollHdr`, `_wideIsNameHdr`,
`_wideIsGradeHdr`, `_wideIsSerialHdr`) go through it. **Cell values keep their
underscores** — a child's name is not ours to rewrite.

This is not cosmetic. `\b` is a word boundary and `_` is a word character, so
`/\broll\b/` **never matches `Roll_No`**. Every one of those predicates read
straight past an underscored heading, which is a shape every machine-exported
sheet uses: `Student_Name`, `Roll_No`, `Adm_No`, `Grade_Level`, `Sl_No`. The
cost was silent — no roll numbers, no grades, and a `Sl_No` column that was
not even recognised as a serial and so was a candidate for the marks column.

`_wideIsGradeHdr` stays **anchored**, and allows only a qualifier around the
word (`Student Grade`, `Grade Level`, `Class No`). A sheet with a numeric
column headed `Class Test` would otherwise lose it to the grade column.

### Wide skill-profiling sheets

A sheet with one row per student and one column per skill, each column stating
its own maximum in the heading (`Listening Skills - 20 Marks`), is detected on
load by `_wideScan()` and opens **step 3** of the marks importer rather than the
column mapper, which can only describe one marks column with one maximum. Each
skill column becomes its own assessment.

Everything about the layout is read, not assumed, because the parts that differ
between two of these sheets are the parts a guess gets wrong:

- **The heading row may not be the row naming the students.** `Name of the
  Students` is often merged down two rows, with merged band names beside it
  above and the skills below. Of the two candidate rows, whichever states more
  maxima wins.
- **Band names are carried rightwards** across the columns they were merged
  over and become the subject, so a column lands in Skill Performance as
  `Language Proficiency · Listening`.
- **The grade may exist only in the sheet's name.** `_wideGradeFromName()`
  reads "Grade 3", "Class V" and "G4"; one workbook is one test and one sheet is
  one grade. Without it every row imports ungraded.
- **A `Sl. No` column is a serial number, not an identity.** It renumbers
  itself whenever a student is added, so taking it for a roll number would
  write one child's marks onto another on the next import. `_wideIsSerialHdr()`
  columns are ignored; roll, admission and enrolment numbers are not.

**A heading does not make a skill column.** An ordinary marks file has `Marks`
and `Remarks` side by side, and reading `Remarks` as a second skill turned a
normal file into a wide one. A skill column must actually hold numbers — at
least one value parses and numbers are the majority of the filled cells. Two
numeric columns are still not enough (`Marks Obtained` beside `Total` is two),
so the layout is only accepted when **two or more columns state a maximum**, or
the columns sit under **merged band headings**. Anything else goes to the
ordinary mapper, which is where it belongs.

**The maximum in a heading is editable, and is the number these sheets get
wrong.** One real column read `Listening Skills - 20 Marks` where nothing
scored above 5 — taking the heading would have halved every percentage in it.
The preview says so against the highest mark actually scored and leaves the
choice to the author rather than picking a side. Maxima are held by column
label, not per sheet, so a correction made once applies to every sheet going in.
Marks above the maximum, values that are not numbers, and blanks are all counted
before importing; blanks stay unscored rather than becoming zeros.

Where every sheet in the workbook has the same columns, all of them import at
once, each taking its grade from its own name — 6 skills × 3 grades in one
pass. Re-importing matches on name and grade, so a sheet imported again after a
maximum was corrected **updates** rather than silently doubling every average
built from it; the preview says how many rows that affects.

### Skill Performance

Cards are grouped by the **skill being assessed**, labelled `Subject · Skill`
("English · Reading", "Maths · Number Sense"). A screening assessment measures
reading or number sense; grouping by whatever subject heading someone typed made
"English- Reading" and "Kannada Reading" look like unrelated subjects and hid
that they are the same skill in two languages.

`_skillKey(item)` builds the label:

- `_deriveSkill()` takes an explicit `item.skill` if set, else matches
  `_SKILLS` against **the subject first and only then the name**. Searching both
  as one blob let a stray word in the free-text name outrank the deliberate
  label — a rubric called "Oral Reading" under subject "English Reading" came
  out as *Speaking*, because "Oral" matches Speaking and Speaking is listed
  first. **Order in `_SKILLS` matters** — specific before general, so "Reading
  Comprehension" is Comprehension, not Reading. Nothing recognised returns
  `null`.
- `_subjectBase()` is what remains of the subject once the skill words are
  removed — the language or area. This is also what folds `"English- Reading"`
  and `"English-Reading"` into one card.

**`Algebra` is matched on `equation`, not on `expression`, and sits last.**
A school's instrument is named `Expressions and Equations`, which `equation`
catches. A bare `expression` would also catch "Oral Expression" and "Written
Expression" — those match Speaking and Writing above it, so the order saves
them — but nothing above it claims "reads facial expressions" in a behavioural
rubric, and that one would have come out as Algebra.

Deriving rather than requiring the field means rubrics that predate it land in
the right card untouched. The editor's Skill box offers `_SKILL_SUGGESTIONS`
plus whatever this school already uses, accepts free text, and `_updateSkillHint()`
shows live which card the rubric will land on — so a wrong guess is visible
before saving rather than discovered in the analytics.

Two things that used to go wrong silently, both still reported:

- **No skill derivable** — the rubric used to be skipped entirely: not shown,
  not counted, no hint anything was missing. Two of one school's Kannada
  rubrics were unlabelled, so 160 responses vanished from the panel and the
  figure read 3 points higher than the truth. They are bucketed as
  **"Unassigned"** (amber, dashed) and `agg.unassigned` names them underneath.
  They were always in the overall average and Grade Averages; only this panel
  dropped them.
- **The same thing named two ways** — `agg.subjectDupes` flags groups whose
  labels match once `_subjectNorm()` collapses case, whitespace and `-_/`, with
  what they would combine to.

It **flags, never merges**. Deciding that two differently-named cards are the
same is the author's call, not the chart's — silently combining them would be
the same class of bug as silently dropping them.

`subjectAvgMap` keeps its name for compatibility with the snapshot and exports;
its keys are skill labels.

#### The 1–4 view

`subjectLevelMap` carries the raw rubric levels beside the percentages, so a
card shows **`2.86 / 4`** and a bar of how many children sit on each level, not
just a percentage. A rubric is scored 1–4 and that is the number a teacher
recognises; an average alone cannot show that a cohort is split between level 1
and level 4. The xlsx export carries `Average Level`, `Out Of` and a `Level N`
count per level.

If two rubrics of **different scales** land under one skill the distribution
would be meaningless, so `scale` is set to `null` and the card falls back to the
percentage only.

### Assessment types, and Holistify screening

`ASSESS_TYPES` is the one definition of the type list, and both the assessment
modal and the rubric editor build their select from it. **Rubrics carry a type
too** — they had none, and on a real school's data eight of the nine screening
instruments *are* rubrics, so a type that only existed on score-based
assessments would have labelled almost nothing.

`ASSESS_TYPE_SCREENING` (`'Holistify Screening'`) is the reason the list exists.
A Holistify screening is not the same kind of thing as a school's own unit test:
screening is a standardised instrument administered the same way across every
school and reads as a baseline, while a unit test measures that school's own
curriculum. Averaging the two together produces a figure that describes
neither, which is what the Analytics scope selector prevents.

`_assessType(item)` resolves it, in the usual order:

1. a stored `item.type`;
2. otherwise **derived from the name** — `_looksLikeScreening()` wants both
   `/holistify/i` and `/screen|profil/i`, so "Holistify Screening
   Assessment/KR/3,4" types itself and the eight untyped rubrics needed no
   edits.

A stored type is **never** overwritten by a name that looks like a screening.
Where the two disagree — a record typed "Oral" before this type existed —
`_screeningMislabelled()` finds it and `_screeningBanner()` offers
`relabelScreening()`, a banner-and-button that appears only when there is
something to change. Same shape as `repairTeacherNames()`, and for the same
reason: reinterpreting stored data silently is worse than asking.

`_assessTypeChip()` draws the badge, **dashed when the type was derived** and
solid when it was chosen, so the two are distinguishable on the card.

Filters: a type filter on Score-based and on Rubric-based, built by
`_assessTypesInUse()` from the types actually present, so the filter can never
offer an empty result. The Analytics tab has a *scope* selector instead —
Everything / Holistify screening only / The school's own — which is passed to
`_assessAggregates(scope)`.

`_assessAggregates(scope)` takes `'all'` (the default, so every pre-existing
caller is unchanged), `'screening'` or `'own'`, and filters both `assessments`
and `rubrics`, including the `unassigned` pass. Two things follow from the rule
that an export can never disagree with the screen:

- both downloads read `_assessScope()`, the selector's current value, and the
  filename gains a `-screening` / `-own` suffix;
- the xlsx **Summary** sheet carries a `Covers` row, so a filtered file is not
  mistaken for the whole school.

A scope with nothing in it says so and names itself rather than rendering the
generic "add assessments and scores" empty state, which would read as *no data
at all*. `_assessBreakdownRows(scope)` also gained a `Type` column, and its
`Standard` column now resolves through `_assessStdLink()` rather than printing
the legacy free-text field.

The wide importer types its assessments `ASSESS_TYPE_SCREENING` when the
sheet's own title says Holistify, and `'Skill Profiling'` otherwise — the
"Holistify Skill Profiling Test" workbook is a screening instrument and belongs
in the same bucket as the screening rubrics.

### Linking assessments to audit standards

Student Attainment & Progress (`sa`) is where assessment evidence belongs: its
standards are written as bands of a whole cohort — "51–75% students understand
most information, follow instructions with minimal support" — which is exactly
what a set of marks produces.

`_assessStdLink(item)` is the single resolver, and the only thing that should
ever answer "which standard does this report against":

1. an explicit `item.link` of `{domain, stdIdx}` — the same shape a checklist
   item uses. `domain: '__none__'` means *deliberately unlinked* and stops the
   fallbacks;
2. the legacy free-text `item.standard`, where it names a real standard;
3. **derived from the skill**, via `_ASSESS_STD_DEFAULT`.

The derived default is keyed on the **skill, not the subject**, because these
standards are language-neutral: "Students demonstrate strong reading and
comprehension skills" is the same standard whether the assessment is English
Reading or Kannada Reading, and both must report against it. Deriving rather
than requiring the field is what makes everything linked without anyone
clicking through ninety standards; `derived: true` is carried through so the UI
draws it hollow and marked "auto" — a suggestion, not a decision. An explicit
link always wins, and a derived link is deliberately **not** frozen into the
record on edit, so renaming an assessment moves it to the right standard
instead of stranding it on the one its old name suggested.

`_assessStdChip()` is the chip on an assessment or rubric card;
`_assessItemsForStd(domainId, stdIdx)` is everything reporting against one
standard; `_buildStdInlineEvidence()` is the evidence block inside a standard's
rubric panel, and it now runs for **every** domain, not just `sa`.

What this replaced is worth knowing, because all three faults are easy to
reintroduce:

- Only score-based assessments could be linked, by picking the standard's own
  sentence into a free-text field. **Rubrics could not be linked at all**, so
  every rubric response was invisible to Standards Attainment.
- The audit page found its evidence by substring, matching any rubric whose
  name or subject contained a sub-domain's label. A "Listening & Writing"
  rubric matched under Listening *and* under Writing and was counted twice,
  while "Number Sense" never matched "Maths" at all.
- That same code read `r.subject.toLowerCase()` unguarded, so one rubric saved
  without a subject threw on the whole page.

`standardMap` in `_assessAggregates()` is keyed by `"<domain>-<stdIdx>"` rather
than by a sentence, so an assessment and a rubric reporting against the same
standard land in one row, and the Standards Attainment table and the xlsx sheet
both carry Domain and Sub-domain columns.

The picker (`_renderStdPicker`, `_stdPickerValue`, `_updateStdPickerHint`) is
shared by the assessment modal (`am-` prefix) and the rubric editor (`rb-`).
Its hint names the standard the item will report against *before* it is saved,
including when the link is left to derive itself — a wrong guess should be
visible in the editor, not discovered later in the analytics.

#### The evidence chip on a standard card

Every standard whose linked assessments carry results shows what they say,
right on the card it is scored on — `buildSaInlineChip(domainId, stdIdx)`,
drawn from `_saEvidenceStats()`, beside the CPA chip in the same renderer.
Linking an assessment to a standard was only half the connection: the numbers
existed in Analytics and the auditor scoring the standard still had to go and
look them up.

`_saEvidenceStats()` reads through `_assessItemsForStd()`, so the chip can
never disagree with what the standard's evidence panel lists, and it takes
rubric responses through `_rubricRespAvg()` / `_rubricLevel()`, so an
unresolvable descriptor stays unscored rather than counting as a zero.

It reports **two numbers, and they answer different questions**:

- `mean` — the average percentage across every result;
- `mastery` — the share of results at 60% or above, i.e. at Level 3 or better.

**The suggested level comes from mastery, not the mean**, because that is what
these standards are written in terms of: Level 3 reads "51–75% students …",
Level 4 "76–100%", so the thresholds are 76 / 51 / 26. A cohort averaging 60%
with everyone bunched at 60 is a different school from one averaging 60% with
half at 30 and half at 90 — same mean, 100% versus 50% mastery, Level 4 versus
Level 2. An average alone cannot tell them apart, which is the whole reason the
standards are phrased as a share of students.

Three properties to preserve:

- **It suggests; it never scores.** `applySaSuggested()` runs only from the
  button. An auditor's own score stands, and the chip then offers "use 2
  instead" rather than quietly replacing it — same reasoning as
  `relabelScreening()` and `repairTeacherNames()`.
- **The suggestion is offered on `sa` only.** Elsewhere the standards are not
  cohort bands, so "76% of students" describes nothing the standard asks about.
  Every domain still gets the counts and the average, because linked evidence
  is worth seeing wherever it exists; `domainId === 'sa'` gates the rest.
- **No evidence, no chip.** A standard with nothing linked returns `null` and
  renders nothing, rather than a 0% that reads as a measured failure.

On Iqra's live data this reads Reading 734 results, avg 49%, 32% at Level 3+ →
Level 2, and Speaking 343 results, avg 54%, 35% → Level 2.

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

## Formal reports

The four documents Holistify issues are generated from this audit's own data,
from a **Formal Reports** tab on the Score Report page (beside Score Report and
Stakeholder Reports):

| Report | Source | Page |
|---|---|---|
| School Audit Report Summary | `scores`, `notes`, `DOMAINS`, `PLAN` | A4 portrait |
| Teachers Performance Report | `teachers`, `teacherScores`, `TP_DOMAINS` | A4 landscape |
| Individual Teacher Report | one teacher's `teacherScores` | A4 landscape |
| Students' Screening Report Summary | `assessments`, `rubrics` and their scores | A4 portrait |

`_rptOpen()` writes the document into a new window with `_RPT_CSS` and a print
toolbar; the browser's **Print → Save as PDF** produces the file. That keeps the
text real — selectable, searchable, accessible — where a canvas-to-image
exporter would flatten it to a picture, and it adds no dependency to a repo that
deliberately has none. A blocked pop-up is reported, because a print window that
silently does nothing is the usual failure here.

**Nothing is written in that the data does not support.** Key Strengths and Key
Concerns quote the standards actually scored, with the evidence notes typed
against them; recommendations come from the `PLAN` entries for that domain, so
the report and the 3-year roadmap cannot contradict each other; the screening
prose is generated from the level counts, so it cannot drift from its own table.
Where a section of the published format has no source in this app at all — the
behavioural screening is a separate psychologist-run instrument — the report
**says so in place of the section** rather than leaving a gap that reads as
"nothing found".

Three things that were wrong and are easy to reintroduce:

- **`subs` on a DOMAIN is the sub-domain count; `sub` on a standard is a much
  finer label.** Counting distinct `sub` strings reported 172 sub-domains for a
  framework that has 26, because Student Attainment alone has 19 of them for 19
  standards. `_rptDomainStats()` uses `d.subs`.
- **The distribution table and its bars use different denominators** — the table
  counts every standard, so its rows plus "not assessed" reach 100%; the bars
  count only the assessed ones. Both are right, and both are now labelled,
  because side by side and unlabelled they read as a contradiction.
- **`_rptLevelBars(counts, total, labels)` takes its wording.** The audit rates a
  standard "Satisfactory"; a screening rates a child "Basic understanding but
  frequent errors". `_RPT_SCREEN_LEVELS` is the screening wording, used by its
  framework table, every skill table and the bars, so the three cannot drift.

The branch of the school being audited fills the **Campus** line the published
format has; see **Branches** above for how it is stored. A school with one
campus prints no campus row at all.

### Editing a report before it goes out

The report window's toolbar carries **✎ Edit text** beside Print. It toggles
`contenteditable` on `.wrap`, so an auditor can correct a sentence — a name
spelled two ways, a finding that needs a word changing for this school —
before the PDF goes out, without a round trip through the audit page.

Four things decided here:

- **It is transient, and says so.** The edit changes the document on screen and
  therefore the PDF printed from it; nothing is written back to `scores`,
  `notes` or `audit_states`, and regenerating starts from the data again. The
  hint swaps to say exactly that the moment editing is switched on, because an
  edit that *looks* saved and is not would be worse than no editing at all —
  the same reasoning that removed the sidebar's Save/Load session buttons.
- **Revert restores the text as generated.** `_rptOrig` is captured once, on
  first entering edit mode, so Revert goes back to what the data produced
  rather than to the last time the toggle was pressed. It confirms first,
  because it discards the auditor's work.
- **The editing chrome never prints.** The dashed outline and the toolbar are
  both inside `@media print { display:none / outline:0 }`, and the
  spellchecker's squiggles do not print either.
- **The toolbar is what shows the mode**, turning amber with an `EDITING` chip.
  The outline is drawn around the whole document and scrolls out of sight; the
  toolbar is fixed, so it is the one place the mode is visible wherever the
  reader is in the file.

`_RPT_EDIT_JS` is written into the report window, not the app — it is a
separate document. `_RPT_HINT_PRINT` / `_RPT_HINT_EDIT` are shared between the
markup and that script through `JSON.stringify`, so the two hints are defined
once.

### A recommendation is read after the audit, not before it

`PLAN` serves two documents in two different tenses, and the same sentence is
right in one and circular in the other:

- On the **Transformation Journey** page (`renderPlan()`) the audit is still
  ahead, so *"Audit all infrastructure and safety compliance — conduct a full
  infrastructure audit against the 22 standards"* is a real first action.
- In a **report compiled from that audit** it is circular. The document in the
  reader's hand is the audit, and telling the school to go and carry one out
  reads as though nothing had been done.

So `_rptPlanEntry(x)` is the one place a PLAN entry becomes its report form,
and both report consumers go through it — Section 6 Recommendations via
`_rptRecommendations()`, and the Section 7 three-year roadmap, which reads
`PLAN` directly and was printing the full infrastructure audit as a Year 1
"Key action". `renderPlan()` deliberately does **not**.

Two mechanisms:

- **`rpt` on a PLAN entry is its title in a report**, where its own `title` is
  written for the plan. Only `p6` carries one today
  (`Close the infrastructure and safety compliance gaps`). A lookup keyed on
  the title sentence would have been the fragility this file has already been
  bitten by — see `standardMap`, re-keyed away from sentences.
- **`_rptIsReaudit(bullet)` drops a `do` bullet**, and needs *both* of two
  things to be true, neither of them the mere presence of the word "audit":
  1. the bullet's **opening instruction** is to carry out an audit
     (`_RPT_REAUDIT`), so *"Establish nutritional standards for canteen menus
     and audit termly"* is about the standards and stays;
  2. it is a **one-off** (`_RPT_RECURRING` does not match). A recurring
     control is not this report coming round again: *"Run regular cleanliness
     audits with student participation"* and *"Audit teaching hours and TSR at
     the start of each academic year"* happen every term or every year and no
     audit report replaces them.

  That leaves exactly the scope-wide one-offs — `p4`, `p6` and `p23`, each
  asking for an audit of the very thing the reader is holding the scores for.
  *"Conduct stakeholder confidence surveys annually"* is caught by neither
  test, and should not be: a survey of parents and staff is not what this
  audit did.

An entry whose every bullet is dropped leaves the Recommendations rather than
printing a titled finding with nothing under it, and the next plan entry for
the domain takes the slot. The roadmap keeps it either way, because there it
names a priority. No entry is in that state today.

### Behavioural screening

The behavioural screening Holistify runs is **not a rubric**. It is a
questionnaire the student answers about themselves — *"Do you feel alone at
school?"*, *"What time do you sleep?"*, *"What do you want to become?"* — and
the issued report is built from the **distribution of answers per question**:
"38.0% feel alone at school", "the most common wake-up is 5:00 AM", "Kannada is
the most frequently mentioned difficult subject". None of those is a level, so
none of it fits the 1–4 model.

So answers are stored **verbatim, as the form recorded them**, in
`behaviourSurveys` / `behaviourResponses`, and every figure is counted at
render time by `_bhvQuestionStats()`. Nothing is scored on the way in, because
there is no scale to score onto. Both stores go through `_buildAuditSnapshot()`
and `_applyAuditSnapshot()`, and the restore writes back to the module's own
localStorage key like every other module.

**The restore is length-guarded**, as `staffData` and `studentsData` are, and
for the same reason: all three are imported lists and `[]` is truthy. A
snapshot can legitimately carry an empty one — `queueSave()` fires from any
edit, and `behaviourSurveys` is only populated once `loadAssessmentData()` has
run, so scoring a standard straight after a page load builds a snapshot with
nothing in it. Restoring that would set the globals to empty *and write the
emptiness through to localStorage*, destroying an import that existed only in
that browser. The cost is that deleting every survey does not propagate from
the cloud, which is the safer of the two errors.

**The 🧠 Behaviour tab** on the Assessment page imports the Google Form
export through the same three routes and the same parser as the rubric
importer — a form export is a form export. Step 2 guesses the name and class
columns, offers **every other column as a question**, and unticks the ones that
obviously are not (timestamp, email, serial). Re-importing a screening of the
same name **replaces** its responses rather than appending, and **keeps the
tagging** each question already had, so pulling a fortnight's extra responses
does not throw that work away.

**A blank answer is not counted** — not in the numerator and not in the
denominator. A question half the cohort skipped reports the share among those
who answered and says how many that was, rather than reading as though the
rest had all said no.

#### What the author supplies, and what the data supplies

The counts need no configuration: every question appears in the report with
its distribution and its most common answer the moment it is imported. What
the author adds in **Tag the questions** is what the number *means*:

- the **group** it belongs under, one of `_BHV_CATS` (the five headings the
  issued report organises Key Findings by);
- which answers are the **concern** — "Yes" to being bullied, "No" to feeling
  you belong. Only questions with a concern answer reach the Concerns table;
  the rest are reported by their most common answer;
- the **psychological implication**, printed verbatim in the Concerns table.
  Where none is given the report prints the observation and says the
  implication is not stated. That column is a psychologist's reading, not
  something countable, and inventing one would be the plainest possible breach
  of "nothing is written in that the data does not support".

A question with more than ~24 distinct answers is treated as free text and
offered no concern tick, because ticking individual answers of an open
question is not a measurement.

#### Drafting the narrative

The tables are counted; the paragraphs around them are what a psychologist
writes, and `behaviour-prose` (`supabase/functions/`) drafts them.

**It is an edge function because `index.html` is served to the public.** An
Anthropic key placed in the page would be readable by anyone who views source
— the same reasoning that puts the service-role key in `admin-accounts`.
Supabase injects `ANTHROPIC_API_KEY` into the function runtime; the browser
only ever calls the function, and the function requires a signed-in caller,
because the anon key is itself a valid JWT and `verify_jwt` alone is not a
check.

**Only aggregates leave the browser.** `_bhvProsePayload()` sends the figures
the report has already counted — per question: its text, its heading, how many
answered, the most common answer, the concern share — plus the school, the
grade span and the totals. **No child's name and no individual response is
sent.** The prose describes a cohort, so nothing finer is needed, and putting
identifiable answers about children's wellbeing through a third party for no
gain would be indefensible. The function re-checks the payload size as a
backstop, so a later change on the client cannot start leaking responses
through it unnoticed.

**The model never supplies a number.** It is given the figures and asked to
write about them; every table stays counted from the responses, so the prose
cannot drift from the data beside it. The prompt forbids inventing or
re-rounding a figure, comparing the school to any benchmark it has no data
for, and naming or implying any clinical condition.

**Nothing is used until it is accepted.** The draft opens in a review modal,
editable, with Draft again / Discard / Accept. Only on Accept is it stored as
`survey.prose`, and only then does the report open with it — 5.1 takes the
summary, 5.5 takes the interpretation. Removing it falls back to the sentences
generated from the counts. A paragraph about children's wellbeing going out
over the school's name should have been read by someone at the school.

Without the key the function answers **503 with the remedy named**, rather
than failing obscurely; without a session, 401.

#### The report

`buildBehaviourReport()` follows the issued document section for section: 5.1
Executive Summary, 5.2 Introduction & Methodology, 5.3 Assessment Methodology
(framework, data collection, ethics), 5.4 Key Findings grouped under the five
headings with the **Concise Table** and the **Concerns** table, 5.5 Summary of
High-Risk Recurring Behaviours with its intervention focus, and the closing
note on subjectivity.

The issued document numbers two different sections 5.3. That is a slip in the
original rather than a feature of the format, so Key Findings is **5.4** here
and everything after it shifts by one.

Where a school also runs a **rated** behavioural instrument (a rubric typed
`ASSESS_TYPE_BEHAVIOUR`), its areas appear as a *Rated areas* table inside the
same report rather than in a second document — `_rptBehaviourIndex()` still
resolves those, and a report that silently dropped one of the two sources
would understate the screening.

### Behavioural screening (rated instruments)

Section 5 of the issued audit report is the **Behavioural Report**, and this
app used to hold nothing to put in it — the section said so in place of the
content, which was the honest answer while it was true.

`ASSESS_TYPE_BEHAVIOUR` (`'Behavioural Screening'`) makes it a third kind of
instrument beside the academic screening and the school's own tests. A
behavioural instrument is an **ordinary rubric or marks assessment carrying
that type**, so it is created, imported, mapped, saved and synced by everything
that already exists; what it needs of its own is a resolver and a report.

- `_looksLikeBehaviour()` derives the type from the name or subject
  (`behaviour`, `psychosocial`, `socio-emotional`, `SEL`, `wellbeing`), so an
  instrument imported before the type existed labels itself. A **stored type
  always wins**, and `bhv.js` asserts that none of Iqra's existing instruments
  is reclassified by it.
- **It is excluded from the academic screening reports at every scope**, not
  just outside `'screening'`. `_rptScreeningResults()` drops it outright:
  those reports average a child across the skills they sat and print one
  overall level, and folding "manages frustration" in with "reads fluently"
  produces a number describing neither. Analytics gains a
  `behaviour` scope of its own, and `'own'` excludes it too — a behavioural
  screening is not the school's own test either.

`_rptBehaviourIndex()` is its resolver, and the unit is different from the
academic one: an academic screening measures a **skill**, a behavioural one an
**area of behaviour** — which for a rubric is its *criterion*, the finest
thing the editor records. So it reads **per criterion** rather than through
`_skillKey()`, which would collapse a whole instrument onto one card. A
marks-based instrument has no criteria, so there the assessment itself is the
area. Everything else matches the academic resolver: the grade goes through
`_rptGrade()`, a child is `name|grade`, and where an area is recorded twice the
lower level stands.

#### A self-report, and reverse-worded items

A behavioural instrument is often **answered by the child**, not by an adult
rating them, and that brings in the one thing that silently inverts a result.

A self-report asks *"I get on well with others"* and *"I lose my temper when
things go wrong"* on the same `Always … Never` scale, and the top answer means
the opposite on each. Read straight, a child answering **Never** to losing
their temper — the best answer there is — scored **Level 1, an area of
concern**, and a child answering **Always** scored **Level 4, secure**. The
levels were exactly inverted, the averages built on them were wrong, and
nothing on screen said so.

So a criterion carries **`reverse`**, ticked in the rubric editor
("the *last* option is the concern, not the first"), and `_rubricLevel()`
flips it: `(scale + 1) - level`. It is done **there**, where a stored answer
becomes a level, so the behaviour report, `_rubricRespAvg()`, analytics and
every export get the same answer and none of them needs to know.

Two things it deliberately does **not** flip, both already levels rather than
positions in the descriptor list:

- a **plain number** — that is what the manual scorer writes, and it is the
  level someone already decided;
- a descriptor the author **numbered themselves** (`"2: Sometimes"`).

And the **multi-select** rule inverts with it: forward it takes the lowest
position ticked, because under-crediting is the safer error; reversed it takes
the **highest**, because that is the position that flips to the lowest level.
Taking the lowest there would have credited the child with the best level in
the list.

#### Who answered

`respondent` on a behavioural instrument (`student` / `staff` / `parent`, or
blank) records who filled it in, and the report's Methodology says so. A child
reporting that they lose their temper is not the same evidence as a teacher
reporting it, and the report used to assert flatly that the rating was done
"by the adults who work with the children" — wrong half the time once
self-reports exist. **Blank claims nothing**, rather than guessing.

Where a child answered for themselves the report adds that this is worth
having and is not an observation: a child may not report a difficulty an adult
can see, or may report one an adult has missed. The Methodology section also
**names every reverse-scored statement**, so a reader who checks one against
the raw form can see why the level reads as it does.

`_RPT_BEHAV_LEVELS` is the report's own wording for the four levels, as
`_RPT_SCREEN_LEVELS` is for the academic one — "area of concern" through
"secure", not "significant difficulty" through "strong mastery". One document
never spells the scale two ways.

`buildBehaviourReport()` is **cohort-level, no names**, as the issued Screening
Report Summary is: a behavioural finding against a named child is a different
document with a different readership, and this one is written to be circulated.
Its six sections are Executive Summary, Assessment Methodology, Summary of the
Data, Area by Area (**ordered worst-first**, which is the order a school reads
it in), Behaviour by Grade, and Interpretation and Next Steps.

Two things it always says, because these documents travel and a behavioural
one travels furthest: that **a screening is not a diagnosis** — it records
what was observed on the day, in the listed areas alone, identifies where
support is worth putting in, names no condition and replaces no psychologist
— and that a pattern across many areas, rather than one low area, is the
point at which a psychologist should be asked to look.

Section 5 of the audit summary now prints the real figures where behaviour data
exists — the cohort line, an area table ordered worst-first, the level bars,
and a pointer to the full report — and keeps its stated absence where it does
not. A stated absence beats an empty frame that reads as "nothing found".

### Student-level screening reports

The issued Screening Report Summary is cohort-level by design: percentages, no
names. "32% of students are at Level 1" is the right sentence for a board and
the wrong one for a staffroom, because it is not a list anyone can teach to.
Two reports sit beside it:

| Report | What it is |
|---|---|
| Students' Screening Report — Student Details | where the cohort sits, a **grade × level matrix** and the same matrix **per skill**, then **one grid per grade** with every skill down the side, its four levels across and the children listed in each cell, and a roster of one row per student |
| Student Screening Profile | one child in full — level per skill, what that level means, the mark behind it, and which skills need support |

#### One result per child per skill

`_rptScreeningResults(scope)` is where **every** screening report resolves its
results, and it returns one row per `(child, skill)`. `_rptScreeningSkills()`
counts those rows; `_rptStudentIndex()` groups the same rows by child. So the
summary, the grids and the names cannot disagree — `stu.js` and `dup.js` both
assert they reconcile.

They did disagree, because a school splits one instrument by grade band:
`.../KR/1,2`, `/3,4` and `/5-10` are three rubrics measuring one skill, and a
child who lands in two bands was screened twice in the same thing. On Iqra's
live data that is **242 duplicate responses** — 164 in Kannada · Reading (106
children, one of them in nine responses), 55 in English · Speaking, 23 in
English · Reading. Three things read it three different ways:

- the summary counted every response, so **444 Kannada results for 280
  children**;
- the student grids kept one per child and skill, so they showed 280;
- a child's overall level averaged every *response* rather than every *skill*,
  so three low Kannada rows pulled that child down three times over. `st.n` is
  now the number of skills, which is what the overall level has always claimed
  to average.

**Where a child has the same skill twice, the lower level stands** — the rule
the grids already applied, because a screening reports what a child could not
yet do. It is decided in one place now rather than three.

`dropped` and `dupes` carry how many were consolidated and under which skills,
and `_rptDupeNote(scope)` turns them into the sentence both reports print — on
the summary's Assessment Methodology page and the student report's first page.
A total smaller than the number of rows in the sheets has to explain itself, or
a reader reconciling the two finds the report short and cannot see why. A
school with no duplicates prints nothing.

**What this does not do is decide which sitting was the *right* one.** On the
live data the three skills fail differently: 47 of English Speaking's 51 are
byte-identical answer sets (a sheet imported twice — discarding one loses
nothing), while **all 106 Kannada duplicates have different answers**, because
the `/5-10` sheet carries 110 rows for children in Grades 1–4 who cannot have
sat a Grade 5–10 paper. For those, "the lower level stands" may take the
wrong-band result and understate the child. Deciding that is the school's call
about its own forms, not the chart's — the same reasoning as
`relabelScreening()` and `repairTeacherNames()`. The note names the skills so
it is visible rather than silent.

Analytics (`_assessAggregates()`) still counts **every response**, deliberately:
its unit is a result, not a child, and it covers the school's own tests as well
as screening. Only the screening reports consolidate.

#### One grade label, however it was typed

A grade is whatever the sheet or the form happened to say, and on Iqra's live
data **every grade from 1 to 10 appears both ways** — `Grade 2` and a bare `2`
— in the bulk imports *and* in the Google Forms behind the rubrics. 22
distinct labels for 12 grades.

That is not cosmetic, because a student is keyed `name|grade`. The same child
arrived as a "Grade 2" person holding their Number Sense and Writing results
and a "2" person holding their Kannada and English ones: **977 students where
there are 694**, each carrying half their skills, and a grade × level table
with a `Grade 1` row and a bare `1` row beneath every real grade. The bare rows
were also unreachable from the report's grade picker, which filters
`GRADES_ORDER` and so never offered them.

`_rptGrade(raw)` normalises through `_bulkGradeValue()` — the same function the
importers already use, so `3`, `III`, `Class V`, `5th`, `Grade 3` and `UKG` all
land on the one label `GRADES_ORDER` uses. It is applied in `put()` inside
`_rptScreeningResults()`, which is the single point every screening result
passes through, so the student key, the grade × level table, the per-grade
grids, the roster and the picker all agree by construction.

**A label it cannot resolve is kept exactly as typed, never blanked.** Iqra has
22 responses under `Gradeb 10` — a typo. Filing those into Grade 10 would be
guessing at a child's grade from a misspelling; leaving them as `Gradeb 10`
puts a visible row in the table that someone can go and fix, which is the same
choice `repairTeacherNames()` makes. `_rptStudentGrades()` already sorts
anything outside `GRADES_ORDER` last.

One case does still guess, inherited from `_bulkGradeValue()`: a multi-select
answer reading `Grade 1, Grade 2` resolves to `Grade 1`. There is one such
response.

**A label it cannot resolve is also a label someone can fix**, so
`_gradeBanner()` + `openGradeFix()` + `applyGradeFix()` are the
banner-and-button for it, on both Assessment tabs because the live typo was
typed into the forms. It is the same shape as `openNameMerge()` and for the
same reason: keeping `Gradeb 10` is right, and leaving the school no way to
correct it is not.

`_glPropose(raw)` reads a label the way a person does — ignoring the
punctuation and the letters that are not part of a grade — and proposes a
grade only when **exactly one** number 1–12 is left, so `Gradeb 10` proposes
`Grade 10` and `9 or 10` proposes nothing and has to be answered. The proposal
is preselected in a dropdown of every grade plus *Leave it as it is*; nothing
moves until the button is pressed.

Two things it is careful about:

- **`all` is not a mistyped grade.** It is an assessment saying it spans the
  school, and `_bulkGradeValue()` cannot resolve it either, so it would
  otherwise head the list.
- **It refiles the label wherever it was typed** — a score row, a rubric
  response, and an assessment's or rubric's own `grade` — and the toast
  separates the two counts. A row with **no** grade of its own is left blank
  rather than filled, because it reads under its assessment's grade, which is
  the fallback `_rptScreeningResults()` applies.

Things decided here that are easy to get wrong:

- **A student is `name|grade`**, lower-cased and whitespace-collapsed. Two
  children in different grades may share a name and are different children;
  two in the same grade who share one are, as far as a marks sheet can tell,
  the same child — the sheets carry no roll number, so inventing a distinction
  the data cannot support would be worse than merging. The picker's option
  values are those same keys, so the list and the report cannot drift.
- **No roll number appears in these documents.** The sheets they are built
  from have no roll column, so a roll could only come from the roster by exact
  name match — which put a number against the children whose spelling matched
  and a dash against the rest, reading as though the blank ones were a
  different kind of record. The name and the grade identify a child here; the
  Students page is where roll numbers live.
- **Where a sheet screens one skill twice, the lower level stands.** A
  screening reports what a child could not yet do.
- A child's **overall level** is the rounded average of the skills they were
  screened on — the same rule a domain score uses — not a mark total.

**The names go in a grid, not in a sentence.** The first cut printed each
level's students as one semicolon-separated run; on real data that was a
paragraph of 417 names, which is a wall rather than a list.

Section 3 is now the shape the school already keeps this in by hand — a
spreadsheet with **a sheet per class**, each skill split into its four levels,
the children listed down the column. So: one table per grade, the skill down
the side, `Level 1`…`Level 4` across, and the names stacked one below the
other in each cell. Reading "who in my class needs reading support" is then one
cell rather than a search.

- **Every skill screened in a grade is in that grade's one table.** The skills
  were briefly chunked two at a time *across* the top (`CHUNK = 2`), which gave
  each pair a table of its own — so `Kannada · Reading` printed separately
  from the English and Maths skills beside it, reading as a different exercise
  rather than one more column of the same screening.
- **The skill goes down the side because A4 portrait is tall, not wide.**
  Eight skills × four levels across is 32 columns of ~5mm, which is nothing;
  down the side it is four level columns of ~34mm. That is also why the
  chunking existed — it was protecting a ~21mm column, where `MOHIUDDIN` at
  14mm had broken mid-word as `MOHIUDDI / N`. At 34mm the problem is gone.
  The cells still wrap on `overflow-wrap`, not `word-break`, so a name breaks
  between its words and only splits one if it cannot fit a line alone.
- **A skill nobody in the grade was screened on is left out of that grade's
  table**, rather than printing four empty columns.
- **Each grade starts a new page**, as each class is its own sheet in the
  original. Rows may break across a page (`page-break-inside:auto`), because a
  level column of sixty names is taller than a page and the alternative is a
  blank one.

**Names are printed in sentence case, and only printed that way.**
`_rptName()` re-cases a word only when that word is **entirely upper or
entirely lower case** — the sheets arrive with `AARHAN PASHA` on one row and
`Arfa firdous` on the next, and side by side in a document about children both
look careless. A word that already mixes cases was spelled that way on purpose,
so `McDonald` and `DeSouza` are left exactly as written where a blanket
lower-case-then-capitalise would flatten them to `Mcdonald`.

It is presentation only: **the stored name is never rewritten**, because it is
the key that matches a child to the roster and reconciles this report with the
summary.

Section 2 keeps the compact grade × level matrix — each child counted once at
their overall level — as the summary that sits above the grids.
`_rptStudentGrades()` orders the grades as `GRADES_ORDER` does and puts
anything ungraded last rather than dropping it.

**It then repeats that table once per skill**, because a child's overall level
is an average across the skills they sat and an average hides what a school
acts on: a cohort reading at Level 3 and writing at Level 1 comes out "Level 2"
in both. Each per-skill table counts only the children screened on that skill,
which is why its `Screened` column differs from the others and from the overall
matrix, and why a grade appears in it only where it was screened on that skill.

The roster report **says on its first page that it names identifiable
children** and points at the summary as the version for wider circulation. The
individual profile closes by saying screening measures what a child could do on
the day, on these skills alone, and is a starting point for teaching rather
than a judgement. Keep both: these documents travel.

### Matching the issued documents

The reports Holistify issues by hand were read back into this repo and the
generators were aligned to them. Three things came out of that reading and are
easy to lose again:

**The font is Avenir Book.** The newest issued document (the Students'
Screening Report Summary, a .docx) sets every run in it; the older PDFs were
produced elsewhere and carry Tw Cen MT and Candara, which is drift, not the
house face. Avenir is a licensed Linotype typeface: it cannot be bundled here
and is not on Google Fonts. `_RPT_FONT` therefore names it first and falls
through `Avenir Next` and `Avenir` to **Nunito Sans**, the closest geometric
humanist sans that can actually be served. So a report printed on a Mac — where
the team produce them — is genuinely in Avenir; elsewhere it is a close match
rather than Times.

`_RPT_FONT_LINK` loads Nunito Sans with `rel="preload" … onload` rather than a
plain stylesheet link. A render-blocking font request held the whole report
back on a slow or filtered connection, which is the wrong trade for a fallback
that only matters where Avenir is absent.

**Each domain and stakeholder section opens with an overview paragraph** that
describes what is being evaluated, before any of this school's numbers.
`_RPT_DOMAIN_OVERVIEW` and `_RPT_STAKEHOLDER_OVERVIEW` hold that text verbatim
from the issued format. It is the same in every school's report, which is why
it is fixed text rather than generated — and why a report produced here and one
produced by hand read as one document.

**The sections and their order are the issued ones.** Per domain: Domain
Overview, 1. Domain Statistics, 2. Performance Distribution, 3. Interpretation,
4. Key Strengths, 5. Key Concerns, 6. Recommendations, 7. Final Interpretation.
Per stakeholder, the same shape ending in 6. Strategic Recommendations and
7. Stakeholder Conclusion. The screening report follows its own document:
1. Executive Summary, 2. Assessment Methodology, 3. Summary of the Data,
4. Summary of High-Risk Recurring Academic Behaviours, 5. Overall Risk
Interpretation.

Smaller things that the issued documents do and this now does:

- The Domain Statistics row is **`School Quality Score (out of 10)`** — the
  domain's weighted contribution, not its percentage. CPA reads `(out of 40)`.
- **Levels run 1 → 4** in every table and bar. They used to run 4 → 1.
- Strengths, concerns and recommendations are **named findings** — a title on
  its own line, then the sentence — through `_rptFinding()`, not bullet lists.
- Stakeholders are named in full (`_RPT_STAKEHOLDER_LABEL`): "Management &
  Leadership", not "Management".
- `Level 1 – Needs Improvement`, with an **en dash** and the rating
  title-cased. `R_LABELS` keeps the app's own sentence case for the screen, and
  `_rptLv()` is the report's copy, so one document never spells a rating two
  ways. Every `R_LABELS[...]` read inside the report builders goes through it.
- A running head prints on every page, and the cover carries the published
  tagline and an `Audit Dates:` label.

**Where the app and the issued report genuinely differ, and should:** section
2.2 of the issued report totals raw points (`375 / 736`) and reports that
percentage as the School Quality Score, while section 3 reports each domain
`out of 10` or `out of 40`, which is the weighted model. Those are two
different calculations, and on the Golekhana data they happen to agree at 51.
This app's `totalScore()` is the weighted one throughout, and 2.2 carries the
raw Score Obtained and Percentage columns beside it, so both figures are on the
page and neither is hidden.

## Billing the client schools

Holistify invoicing the schools it audits, the enquiries from schools that want
an audit, and the queue that chases both. Reached from **💰 Billing &
Enquiries** on the admin hub, which opens `openSectionPage('billing')` —
the existing full-screen section page, not a modal, because billing is a
workspace. `supabase_billing.sql` is the schema;
`supabase/functions/billing-followups/` drafts the wording.

This is the *other* direction of money from the sibling app, which bills
parents for a child's fees. Here the payer is a school and the contact is
whoever handles its accounts, so none of the parent-facing shape transfers —
but the arithmetic does, deliberately, and the thresholds are the one thing
that had to change.

The split everything rests on:

- **Code does the money.** `_blgTotals()`, `_blgState()` and
  `_blgNextInvoiceNo()` are the only places a balance, a days-overdue, an
  escalation stage or an invoice number is computed, so no table, reminder or
  printed invoice can disagree with another about what a school owes.
- **The model only writes the sentence.** The figures go to the edge function
  as finished strings, and `_blgVerify()` checks the draft carries each of
  them back *unaltered* before it is queued.

### Four properties to preserve

- **`_blgVerify()` is not optional.** A draft that does not carry the balance,
  the due date and the invoice number back verbatim is discarded, as is one
  reaching for anything that has not been agreed with the school
  (`_BLG_FORBIDDEN` — legal action, a late-payment fee, interest, suspending
  access, withholding a report, terminating the agreement). The plain template
  is used instead and the run report names which drafts fell back and why. A
  client can see a blander reminder; never a wrong amount, and never a threat
  Holistify has no contractual basis to make.
- **Tax is charged on the discounted figure**, which is the order it is
  actually levied in: gross → discount → taxable → tax → net. Getting that
  backwards overstates every discounted invoice.
- **Overdue is never stored, and neither is a balance.** `service_payments` is
  the record; `_blgState()` derives everything from it.
  `service_invoices.status` is kept in step by `_blgRefreshStatus()` as a
  **cache** for the partial index, and `_blgState()` ignores it except for
  `void` — so a stale status cannot contradict the ledger.
- **One pending draft per invoice per stage**, enforced by a partial unique
  index as well as in `runBillingFollowUps()`. Running it each morning for a
  week would otherwise leave seven identical unsent reminders for one school.
  Marking an enquiry follow-up sent also bumps `updated_at` and clears
  `next_action_on`, or the cadence would redraft it tomorrow.

### The escalation thresholds are longer than the parent-facing ones

`_BLG_STAGES` runs due_soon (7 days before) → reminder (day 1) → overdue
(day 11) → firm (day 31) → needs a conversation (day 61). The sibling app
chases a parent from day 1 / 8 / 22 / 46.

That difference is the point, not drift. A school pays through a trust or a
correspondent on a monthly finance cycle, so a fortnight's silence is a cycle
rather than a problem, and chasing a client institution on a parent's timetable
reads as not understanding how they pay. Both sets live in exactly one place in
their own app, so either can be retuned without hunting for a second copy.

### Nothing sends itself, because there is nothing here to send with

This is a static site with no server. A drafted message is approved and then
sent **by a person**, from their own mail client (`_blgMailto`) or WhatsApp
(`_blgWaLink`) — both links prefill and neither sends. That is a smaller
promise than the sibling app's auto-send option, and an honest one; adding real
sending would mean an email provider and a second secret in an edge function.

Approval is still a real step: a message cannot be marked sent from `draft`,
and editing the wording drops the approval, because somebody approved the old
sentence.

### Billing keeps no local copy

Every other module here auto-saves to `localStorage` and rides along in the
audit snapshot. Billing deliberately does not: a list of what every client
school owes should not sit in whichever browser an admin last used, and it
would be a second source of truth about money — the same reasoning that
removed the sidebar's Save/Load session buttons.

So billing needs a **real Supabase session**, not the `localStorage` fallback.
That state is easy to land in, because `authSignIn()` falls back silently, so
`renderBillingPage()` checks `_authSessionActive` and says what to do rather
than rendering an empty page that reads as "no invoices" — the same wrong
answer `pendingMigrationCount()` returns `null` to avoid giving.

### Access is narrower than the audit's

The existing tables are open to any signed-in user, because an auditor and a
principal both legitimately read the audit. These are not: a principal of one
school must not read another school's invoices, and an auditor has no business
in any of it. `supabase_billing.sql` adds `public.is_holistify()` —
`is_admin()` plus `holistify_member`, same SECURITY DEFINER shape, same
`revoke`/`grant` hygiene for the same reasons — and every policy is
`for all to authenticated using (public.is_holistify())`.

**No `anon` policy anywhere.** The published anon key must stay inert, and
commercial data is the last thing to make an exception for. The edge function
re-checks the role server-side too, because the anon key is itself a valid JWT
and `verify_jwt` alone is not a check.

### Three documents, one invoice

An invoice **asks** for money, a receipt **acknowledges** it, and a reminder
asks again for what is still outstanding. One page used to do all three — the
invoice listed its payments, so it doubled as the receipt — which is fine for a
file copy and wrong for anything sent out. A school that has paid in full
should not receive a document headed "Invoice" with a due date on it, and a
school that has not should not have to infer the chase from a reprint.

| Document | Builder | Shown when |
|---|---|---|
| Invoice | `openInvoiceDocument()` | always, from the invoice number |
| Receipt | `openReceiptDocument(id, paymentId?)` | something has been received |
| Reminder | `openReminderDocument()` | not void, and a balance remains |

All three read `inv.totals` — one `_blgTotals()` — so no two can disagree about
what is owed. The receipt and the reminder also share `_blgDocParties()` and
`_blgDocRow()`; the invoice has its own layout, because it is the one of the
three that matches a document Holistify already issues by hand (below).
`doc.mjs` asserts they print the same total and the same balance.

Each writes out **its own** figure in words: the invoice the total asked for,
the receipt what was received, the reminder what is still owed.

**Nothing new is stored.** A receipt number is derived: `<invoice_no>/R<n>`,
from `_blgPaymentsInOrder()`.

- **Ordered by `created_at`, not `paid_on`.** A receipt number has to be stable
  once it is issued, and `paid_on` is editable backdating — recording a cheque
  today that cleared last month would renumber every receipt issued since.
  `created_at` is append-only, which is also how a paper receipt book works.
- **A receipt states the position at its own moment**, not today: it reports
  what had been received up to and including that payment, so a later payment
  cannot change what an already-issued receipt says.
- Called with no payment id it issues the **latest**, which is the case that
  happens — a payment has just been recorded. Every payment is listed
  underneath with its number, and the invoice names them too, so an older one
  can be asked for and reprinted by id.

**The sum is written out in words** (`_blgWords()`, Indian numbering — crore,
lakh, thousand, hundred), on all three documents. Figures on a printed page can
be altered and words cannot, which is the whole reason the convention exists.

#### The invoice is the issued document

The invoice Holistify already sends was read back into the repo and
`openInvoiceDocument()` was laid out to match it, so a school receiving one
generated here and one typed by hand cannot tell them apart: the bordered
header band with the mark and the entity name, the issuer block beside
`PAN / Invoice No / Invoice For / Due`, the `To :` block, the
`SL No | Description | Unit Price | Amount | Total Amount` grid, the sum in
words, the bank table, the signatory, the footer.

It carries its own `_BLG_INV_CSS` rather than `_RPT_CSS`'s tables, which are
the report's green on a tinted header row — this document rules everything in
plain black, as the original does. `_blgInvDate()` writes `1st October, 2026`,
which is how the issued invoice states the period it covers; **Invoice For** is
`inv.period`, falling back to the issue date where the invoice names none.

- **The grid is the issued five-column one although an invoice here carries one
  line.** SL No 1 is the whole of it, and a second line can be added later
  without the document changing shape.
- **Discount and tax rows appear only where they apply**, so an invoice with
  neither reads exactly like the paper one.
- **The payments already credited are listed by receipt number**, so an older
  receipt can be asked for and reprinted by id. The invoice *names* them; it
  does not acknowledge them — that is `openReceiptDocument()`.

#### The issuer's own details are not in this file

`billing_settings` is a one-row table (`id = 1`, enforced by a check) holding
everything the invoice says about Holistify rather than about the school: the
entity name, address and PAN, the bank account to pay into, who signs, and the
footer. `_blgLoad()` reads it alongside the invoices and `_blgSet(key)` returns
one value or `''`, so a document never prints `undefined`.

**It is a table and not a constant because `index.html` is served to the public
and committed to a public repository.** None of it is a secret the way a key is
— it is printed on every invoice Holistify sends — but the schools being billed
are a narrower audience than the open internet, and an account number sitting
in a public repo invites fraud attempts. A missing row is not an error: the
documents fall back to plain labels rather than refusing to print.

The school's own `pan` and `billing_address` are kept on `schools` and
**copied onto the invoice** as `client_pan` / `client_address`, for the same
reason `school_name` is: the PAN printed on an invoice that went out must not
change when the registry row is later corrected. `_blgPrefillBilling()` fills
them in from the school and never overwrites what has been typed.

#### The invoice number continues the hand-written series

`_blgNextInvoiceNo()` derives `HSTP0027` from the numbers already issued —
`invoice_prefix` is a setting, because the series is the issuer's — rather than
the `HOL/<FY>/` scheme it used to invent. An invoice number appears in the
school's books as well as Holistify's, so a second scheme would put two records
under one identity.

Which is also why **the number is editable in the modal**. A fresh install
derives `0001` and would collide with the paper series, so the first invoice is
typed as the next real number and every one after it follows from that. Left
blank it continues the series; typed, it wins. The unique index is the backstop,
and `saveInvoice()` names a duplicate rather than letting Postgres' message
through.

**The reminder states and never threatens**, for the same reason
`_BLG_FORBIDDEN` governs the drafted messages: nothing about legal action, late
fees, interest or withholding a report has been agreed with the school, so no
document generated here may imply it. It leads with the balance and how late it
is, lists the payments already credited — so "but we paid in April" is answered
on the page rather than in a reply three days later — and offers the two outs a
real chase offers: tell us where it has reached, or tell us what needs
correcting and we will reissue.

Neither can be sent empty: a receipt with no payment behind it is refused, and
so is a reminder on a settled or voided invoice, each pointing at the document
that *is* appropriate.

### Smaller things decided here

- **An issued invoice is voided, never deleted.** Voiding keeps the record and
  stops it being chased, and `_blgNextInvoiceNo()` derives the next number from
  the numbers already issued rather than from a count — so a voided number is
  never handed to a later invoice, which would put two records under one
  identity in the books.
- **The printed invoice goes through `_rptOpen()`**, like every other document
  here. Because it is HTML in a browser window rather than a PDF library, `₹`
  renders and there is no ASCII fallback to keep in step — the one place this
  repo's no-dependency reporting is less work than the alternative, not more.
- **The invoice stores the school and its campus separately**, through
  `splitBranch()`, so it bills "Shaheen School, Golekhana branch" rather than
  the joined key string. See **Branches**.
- **The billing contact is saved back onto the school**, so it is typed once
  per client rather than once per invoice, and `_blgPrefillBilling()` never
  overwrites what has already been typed into the form.
- **The money fields are checked in `saveInvoice()`, not left to Postgres.**
  `tax_pct` is `numeric(5,2)` and `amount` / `discount` are `numeric(12,2)`, so
  a figure past those bounds came back as a bare **"numeric field overflow"** —
  a message naming neither the field nor the fix. The box that gets this wrong
  is **Tax %**: typing the tax *amount* into it (1000 for ₹1,000 of GST) reads
  as 1000% and overflows. The ceiling is **100, not the column's 999.99**,
  because no one invoices a rate above 100% and naming the real bound is more
  use than naming the storage one. A discount larger than the amount is
  refused too — `_blgTotals()` clamps it on the way out, so storing it would
  leave the row and the printed invoice disagreeing.
- **An overpayment is recorded but reported**, so a transposed figure
  (₹1,50,000 keyed for ₹15,000) is visible as it is entered rather than
  discovered when a refund is asked for.
- **No email address means no draft.** Rather than queue an unsendable message,
  those are counted and named so somebody can add the address.
- Exports go through `_csvRows()` / `_downloadCsv()`, like every other export
  here.

## Database

`supabase_schema.sql` defines three tables:

- `schools`
- `audit_states`
- `journey_records`

`supabase_billing.sql` adds six more, for billing the client schools, plus
`public.is_holistify()` and the billing contact columns on `schools`:

- `service_invoices`
- `service_payments`
- `service_enquiries`
- `service_enquiry_events`
- `followup_outbox`
- `billing_settings` — one row, the issuer's own details for the printed
  documents; see **Billing the client schools**

Unlike the three above, these are restricted to the Holistify team rather than
open to every signed-in user — see **Billing the client schools**.

## Conventions

Everything is inline — styles, scripts, markup in the same file. Match the
surrounding style rather than introducing a bundler or a framework; the
simplicity is the point of this repo.

DOM lookups here have historically thrown on pages where an element is absent
(the demo-accounts panel, for one). Guard `getElementById` results before using
them rather than chaining straight onto the result.
