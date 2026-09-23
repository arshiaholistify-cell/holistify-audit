const fs = require('fs');
let html = fs.readFileSync('index.html', 'utf8');
html = html.replace(/__SUPABASE_URL__/g, process.env.SUPABASE_URL || '');
html = html.replace(/__SUPABASE_ANON_KEY__/g, process.env.SUPABASE_ANON_KEY || '');
fs.mkdirSync('dist', { recursive: true });
fs.writeFileSync('dist/index.html', html);
console.log('Build complete → dist/index.html');
