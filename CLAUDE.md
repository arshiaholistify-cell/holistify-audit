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

**Worth knowing:** only `index.html` carries the credential placeholders;
everything else is copied verbatim from the `STATIC` list in `build.js`. **Add
new static files to that list**, or they will 404 on the deployed site — they
will still work on GitHub Pages, which publishes the whole repo, so this failure
shows up only on `audit.holistify.ai`.

## Two deploy targets

The repo is published twice, from the same `main`:

- **Vercel** → `audit.holistify.ai`, the real site. Builds via `build.js` and
  serves `dist/`, injecting credentials from Vercel's environment variables.
- **GitHub Pages** → `arshiaholistify-cell.github.io/holistify-audit/`, via
  `.github/workflows/deploy.yml`. Publishes the repo root, injecting
  credentials from GitHub Actions secrets.

They inject the same two credentials from *different* places, so a variable set
in one and missing in the other is the usual reason one target works while the
other is broken. Check both when only one is failing.

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
