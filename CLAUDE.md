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

### Migration state

`supabase_auth_migration.sql` is applied and is deliberately additive: the old
`anon` policies still sit alongside the new `authenticated` ones, so unmigrated
users keep working. **The migration is not finished until
`supabase_auth_lockdown.sql` is run**, which drops those anon policies. Until
then the anon key in the served HTML still grants full read/write to every
table, which is the hole this work exists to close.

Run the lockdown only once every account appears in `profiles` and has signed
in through Auth at least once.

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
