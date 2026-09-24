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
