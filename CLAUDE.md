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
