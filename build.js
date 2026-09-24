const fs = require('fs');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;

// Fail rather than warn. Empty credentials build a site that loads normally and
// then silently never reaches Supabase, because _sbClient() bails on a URL
// without 'supabase.co' in it. Failing here keeps the last good deploy live.
if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error('ERROR: SUPABASE_URL / SUPABASE_ANON_KEY are not set — refusing to build.');
  console.error('Set both in the Vercel project environment variables, or in a local .env.');
  process.exit(1);
}

fs.rmSync('dist', { recursive: true, force: true });
fs.mkdirSync('dist', { recursive: true });

let html = fs.readFileSync('index.html', 'utf8');
html = html.replace(/__SUPABASE_URL__/g, SUPABASE_URL);
html = html.replace(/__SUPABASE_ANON_KEY__/g, SUPABASE_ANON_KEY);

if (/__SUPABASE_[A-Z_]*__/.test(html)) {
  console.error('ERROR: unsubstituted placeholder left in index.html — refusing to build.');
  process.exit(1);
}

fs.writeFileSync('dist/index.html', html);

// Everything else the site serves, discovered rather than listed, so a new file
// is served without anyone remembering to update this script. An allowlist of
// extensions (not a denylist) keeps .env, *.sql, package.json and this script
// out of dist/. Only index.html carries credential placeholders; the rest are
// copied verbatim.
const SERVED = /\.(html|css|js|png|jpe?g|gif|svg|ico|webmanifest|woff2?)$/i;
const NOT_SERVED = new Set(['build.js', 'index.html']);

const staticFiles = fs.readdirSync('.', { withFileTypes: true })
  .filter(function (entry) { return entry.isFile(); })
  .map(function (entry) { return entry.name; })
  .filter(function (name) { return SERVED.test(name) && !NOT_SERVED.has(name); })
  .sort();

staticFiles.forEach(function (file) {
  fs.copyFileSync(file, 'dist/' + file);
});

console.log('Build complete → dist/');
console.log('  index.html (credentials substituted)');
staticFiles.forEach(function (file) { console.log('  ' + file); });
