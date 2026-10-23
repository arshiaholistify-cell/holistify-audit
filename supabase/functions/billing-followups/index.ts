// Drafts the wording of invoice reminders and enquiry follow-ups.
//
// Why this is a function and not browser code: `index.html` is served to the
// public, so an Anthropic API key placed there would be readable by anyone who
// views source. Supabase injects ANTHROPIC_API_KEY into this runtime instead,
// and the browser only ever calls the function. Same reasoning as
// `admin-accounts` and `behaviour-prose`.
//
// **The model never supplies a number.** It is handed figures the browser has
// already computed — the balance, the due date, the invoice number — as
// finished strings, and asked only for the sentence around them. The browser
// then checks the draft still carries each of those strings unaltered before
// it is queued (_blgVerify in index.html), and discards it for the plain
// template if not. A client school can see a blander reminder; never a wrong
// amount.
//
// **What is sent.** The school's name, who is being written to, the figures,
// and how firm to be. Not sent: the `notes` on an invoice or an enquiry, which
// is where commercial detail and candid internal comment live and which the
// wording does not need.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

const MODEL = 'claude-opus-5-5';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

type Item = {
  id: string;
  school: string;
  contact?: string;
  tone?: string;
  // invoice reminders
  invoiceNo?: string;
  balanceText?: string;
  dueDateText?: string;
  daysOverdue?: number;
  service?: string;
  period?: string;
  // enquiry follow-ups
  stage?: string;
  interest?: string;
  daysSince?: number;
  quotedText?: string;
};

const SHARED_RULES = `
Hard rules:
- Use ONLY the figures, dates, invoice numbers and names given to you, copied character for
  character. Never recalculate, re-round, reformat or convert a figure. Never invent a bank
  account, a payment link, a deadline, a discount or a contractual term.
- Never threaten. No legal action, no withdrawal of a report already delivered, no suspension
  of a school's access, no late-payment penalty — none of that has been agreed and none of it
  is yours to assert. The firmest thing available is to ask for a date and offer to talk.
- These are client schools in an ongoing relationship, not debtors. Courteous and professional
  throughout.
- British English. 2 to 4 sentences. Plain prose for an email: no markdown, no headings, no
  bullet points, no emoji.
- Address the person by the name given. Sign nothing — the sender's own name is added after.
- Output JSON only.`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) {
    return json({
      error: 'No ANTHROPIC_API_KEY is set for this project, so the wording cannot be drafted. ' +
             'Add it under Edge Functions → Secrets in the Supabase dashboard. ' +
             'The follow-ups still work — they use the plain templates instead.',
    }, 503);
  }

  // Signed in, and on the Holistify team. The anon key is itself a valid JWT,
  // so verify_jwt alone would not be a check — and this draft quotes what a
  // client school owes, which is not for a school's own staff to call up.
  const url = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const caller = createClient(url, anonKey, {
    global: { headers: { Authorization: req.headers.get('Authorization') || '' } },
    auth: { persistSession: false },
  });
  const { data: userData } = await caller.auth.getUser();
  if (!userData?.user) return json({ error: 'Not signed in.' }, 401);

  const { data: profile } = await caller
    .from('profiles').select('role').eq('id', userData.user.id).maybeSingle();
  const role = profile?.role || '';
  if (!['holistify_admin', 'holistify_member', 'super_admin'].includes(role)) {
    return json({ error: 'Only the Holistify team can draft billing follow-ups.' }, 403);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: 'Body must be JSON.' }, 400); }

  // A backstop on size, as in behaviour-prose: a later change on the client
  // must not be able to start pushing whole records through here unnoticed.
  if (JSON.stringify(body).length > 60000) {
    return json({ error: 'That payload is far larger than a set of follow-ups. Refusing it.' }, 400);
  }

  const kind = String(body.kind || 'invoice');
  const org = String(body.org || 'Holistify').slice(0, 120);
  const sender = String(body.sender || '').slice(0, 120);
  const items = (Array.isArray(body.items) ? body.items : []).slice(0, 25) as Item[];
  if (!items.length) return json({ error: 'No items were sent.' }, 400);

  const prompt = kind === 'enquiry'
    ? `You write follow-up emails for ${org}, which carries out school quality audits and runs
three-year transformation programmes with the schools it audits.

Each item is a school that enquired about the service. Write one short email each, doing what
"what_this_message_is_for" describes.

Do not state a price, a timetable, a start date or what the audit covers unless a figure for it
is given below — the ${org} team confirms those. Offer to arrange or confirm things rather than
asserting them.
${SHARED_RULES}

Items:
${JSON.stringify(items.map((i) => ({
  id: i.id,
  school: i.school,
  write_to: i.contact,
  interested_in: i.interest || null,
  amount_quoted: i.quotedText || null,
  days_since_last_contact: i.daysSince ?? null,
  what_this_message_is_for: i.tone,
})), null, 2)}

Return a JSON array: [{"id": "<the id>", "subject": "<email subject, under 70 characters>", "message": "<the email body>"}]`

    : `You write invoice reminder emails for ${org}, which carries out school quality audits and
runs transformation programmes. The recipients are the schools it works with${sender ? `, and the sender is ${sender}` : ''}.

For each item below write one short email. "how_to_pitch_it" tells you how firm to be — follow it
closely, because it reflects how overdue the invoice is.

Every message must include the amount_outstanding, the due_date and the invoice_number exactly as
written below.
${SHARED_RULES}

Items:
${JSON.stringify(items.map((i) => ({
  id: i.id,
  school: i.school,
  write_to: i.contact,
  service: i.service || null,
  period: i.period || null,
  invoice_number: i.invoiceNo,
  amount_outstanding: i.balanceText,
  due_date: i.dueDateText,
  days_overdue: i.daysOverdue ?? 0,
  how_to_pitch_it: i.tone,
})), null, 2)}

Return a JSON array: [{"id": "<the id>", "subject": "<email subject, under 70 characters>", "message": "<the email body>"}]`;

  let res: Response;
  try {
    res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: Math.min(16000, 500 * items.length + 1000),
        messages: [{ role: 'user', content: prompt }],
      }),
    });
  } catch (e) {
    return json({ error: 'Could not reach the model: ' + String(e) }, 502);
  }

  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    return json({
      error: `The model returned HTTP ${res.status}.` +
             (res.status === 401 ? ' The ANTHROPIC_API_KEY set for this project was rejected.' : ''),
      detail: detail.slice(0, 500),
    }, 502);
  }

  const out = await res.json();
  const text = (out?.content || []).map((c: { text?: string }) => c.text || '').join('').trim();
  const m = text.match(/\[[\s\S]*\]/);
  if (!m) return json({ error: 'The model did not return the expected JSON.', detail: text.slice(0, 500) }, 502);

  let parsed: unknown;
  try { parsed = JSON.parse(m[0]); }
  catch { return json({ error: 'The model returned JSON that would not parse.', detail: text.slice(0, 500) }, 502); }

  // Shape only. Whether a draft is USABLE is decided in the browser, which
  // holds the authoritative figures and does the checking — one place for that
  // decision rather than two that could disagree.
  const drafts = (Array.isArray(parsed) ? parsed : [])
    .filter((r): r is { id: string; subject?: string; message: string } =>
      Boolean(r && typeof (r as { id?: unknown }).id === 'string' &&
              typeof (r as { message?: unknown }).message === 'string'))
    .map((r) => ({
      id: r.id,
      subject: String(r.subject || '').trim().slice(0, 140),
      message: String(r.message).trim().slice(0, 4000),
    }))
    .slice(0, 25);

  return json({ drafts, model: MODEL, at: new Date().toISOString() });
});
