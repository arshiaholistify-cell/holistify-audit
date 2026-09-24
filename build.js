const fs = require('fs');

if (!process.env.SUPABASE_URL || !process.env.SUPABASE_ANON_KEY) {
  console.warn('WARNING: SUPABASE_URL / SUPABASE_ANON_KEY not set — the built site will have empty credentials and will not load or save any data.');
}

let html = fs.readFileSync('index.html', 'utf8');
html = html.replace(/__SUPABASE_URL__/g, process.env.SUPABASE_URL || '');
html = html.replace(/__SUPABASE_ANON_KEY__/g, process.env.SUPABASE_ANON_KEY || '');
fs.mkdirSync('dist', { recursive: true });
fs.writeFileSync('dist/index.html', html);

// Everything else the site serves. These have no credential placeholders, so
// they are copied as-is; without this they 404 on the deployed site even
// though they work on GitHub Pages (which publishes the whole repo).
const STATIC = ['transformation-dashboard.html', 'mentor-dashboard.html', 'holistify-logo.png'];
STATIC.forEach(function (file) {
  fs.copyFileSync(file, 'dist/' + file);
});

console.log('Build complete → dist/index.html + ' + STATIC.length + ' static files');
