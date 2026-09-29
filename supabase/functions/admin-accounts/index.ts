// Admin-only account management for the Holistify audit platform.
//
// Creating a Supabase Auth user needs the service-role key, which must never
// reach the browser, so it happens here. Supabase injects SUPABASE_URL,
// SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY into the function runtime;
// none of them are checked into the repo.
//
// Every action requires the caller to be signed in AND to hold an admin role
// in public.profiles. verify_jwt is on as well, but that alone is not enough:
// the anon key is itself a valid JWT, so the role check below is what actually
// gates this function.
//
// Login IDs are not email addresses. Each maps to <login_id>@audit.holistify.ai
// — a domain that passes Supabase's address validation. Nothing is ever sent
// to it: users are created with email_confirm so no confirmation mail goes out.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

const EMAIL_DOMAIN = 'audit.holistify.ai';
const ADMIN_ROLES = ['holistify_admin', 'super_admin'];

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

const emailFor = (loginId: string) =>
  `${String(loginId).trim().toLowerCase().replace(/\s/g, '')}@${EMAIL_DOMAIN}`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const url = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  // ── Who is calling? ───────────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization') || '';
  const caller = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData } = await caller.auth.getUser();
  const user = userData?.user;
  if (!user) return json({ error: 'Not signed in.' }, 401);

  const { data: profile } = await admin
    .from('profiles').select('role').eq('id', user.id).maybeSingle();
  if (!profile || !ADMIN_ROLES.includes(profile.role)) {
    return json({ error: 'Admin role required.' }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Body must be JSON.' }, 400);
  }
  const action = String(body.action || '');

  // ── Create one account ────────────────────────────────────────────────────
  // New accounts must meet the 8-character minimum the app now enforces.
  // Migration keeps the old 6-character floor, because it carries passwords
  // people already have: rejecting them would strand those accounts rather
  // than make anything safer. They get rotated through the normal change flow.
  async function createAccount(acc: Record<string, unknown>, minLength: number) {
    const loginId = String(acc.id ?? '').trim().toLowerCase().replace(/\s/g, '');
    const password = String(acc.pwd ?? '');
    if (!loginId) return { id: acc.id, ok: false, reason: 'missing id' };
    if (password.length < minLength) {
      return { id: loginId, ok: false, reason: `password shorter than ${minLength} characters` };
    }

    const { data: existing } = await admin
      .from('profiles').select('id').eq('login_id', loginId).maybeSingle();
    if (existing) return { id: loginId, ok: true, skipped: true, reason: 'already migrated' };

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email: emailFor(loginId),
      password,
      email_confirm: true,                 // no confirmation mail is sent
      user_metadata: { login_id: loginId },
    });
    if (createErr || !created?.user) {
      return { id: loginId, ok: false, reason: createErr?.message || 'could not create user' };
    }

    const { error: profileErr } = await admin.from('profiles').insert({
      id: created.user.id,
      login_id: loginId,
      name: String(acc.name ?? loginId),
      role: String(acc.role ?? 'school_staff'),
      school: String(acc.school ?? ''),
      assigned_schools: acc.assignedSchools ?? [],
      page_access: acc.pageAccess ?? null,
      holistify_team: Boolean(acc.holistifyTeam),
    });
    if (profileErr) {
      // Do not leave an auth user with no profile behind.
      await admin.auth.admin.deleteUser(created.user.id);
      return { id: loginId, ok: false, reason: profileErr.message };
    }
    return { id: loginId, ok: true, created: true };
  }

  if (action === 'migrate' || action === 'create') {
    const accounts = Array.isArray(body.accounts)
      ? body.accounts
      : (body.account ? [body.account] : []);
    if (!accounts.length) return json({ error: 'No accounts supplied.' }, 400);
    if (accounts.length > 200) return json({ error: 'Too many accounts in one call.' }, 400);

    const minLength = action === 'create' ? 8 : 6;
    const results = [];
    for (const acc of accounts) results.push(await createAccount(acc as Record<string, unknown>, minLength));
    return json({
      results,
      created: results.filter((r) => r.created).length,
      skipped: results.filter((r) => r.skipped).length,
      failed: results.filter((r) => !r.ok).length,
    });
  }

  // ── Reset someone else's password ─────────────────────────────────────────
  if (action === 'set_password') {
    const loginId = String(body.id ?? '').trim().toLowerCase();
    const password = String(body.password ?? '');
    if (password.length < 8) return json({ error: 'Password must be at least 8 characters.' }, 400);
    const { data: target } = await admin
      .from('profiles').select('id').eq('login_id', loginId).maybeSingle();
    if (!target) return json({ error: 'No such account.' }, 404);
    const { error } = await admin.auth.admin.updateUserById(target.id, { password });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  // ── Delete an account ─────────────────────────────────────────────────────
  if (action === 'delete') {
    const loginId = String(body.id ?? '').trim().toLowerCase();
    const { data: target } = await admin
      .from('profiles').select('id, role').eq('login_id', loginId).maybeSingle();
    if (!target) return json({ ok: true, skipped: 'no such account' });
    if (target.id === user.id) return json({ error: 'You cannot delete your own account.' }, 400);
    const { error } = await admin.auth.admin.deleteUser(target.id);  // profile cascades
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  return json({ error: `Unknown action "${action}".` }, 400);
});
