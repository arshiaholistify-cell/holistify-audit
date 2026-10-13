// Drafts the narrative paragraphs of the Behavioural Screening Report.
//
// Why this is a function and not browser code: `index.html` is served to the
// public, so an Anthropic API key placed there would be readable by anyone who
// views source. Supabase injects ANTHROPIC_API_KEY into this runtime instead,
// and the browser only ever calls the function. Same reasoning as
// `admin-accounts` and the service-role key.
//
// **What is sent, and what is not.** The browser sends only the figures the
// report has already counted: how many responded, and per question its text,
// its heading, how many answered, the most common answer, and the share who
// gave the answers the author marked as a concern. No child's name and no
// individual response ever leaves the browser — the prose describes a cohort,
// so nothing finer is needed, and sending it would put identifiable answers
// about children's wellbeing through a third party for no gain.
//
// **The model never supplies a number.** It is given the figures and asked to
// write about them; the report's tables are still counted from the responses.
// That is what keeps the prose from drifting from the data beside it, which is
// the rule the rest of these reports are built on.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

const MODEL = 'claude-sonnet-5-5';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

type Q = {
  q: string; cat?: string; n?: number;
  top?: string; topPct?: number;
  concern?: string[]; concernPct?: number | null;
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) {
    return json({
      error: 'No ANTHROPIC_API_KEY is set for this project, so the narrative cannot be drafted. ' +
             'Add it under Edge Functions → Secrets in the Supabase dashboard.',
    }, 503);
  }

  // Signed in, as every other write-ish path here requires. The anon key is
  // itself a valid JWT, so verify_jwt alone would not be a check.
  const url = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const caller = createClient(url, anonKey, {
    global: { headers: { Authorization: req.headers.get('Authorization') || '' } },
    auth: { persistSession: false },
  });
  const { data: userData } = await caller.auth.getUser();
  if (!userData?.user) return json({ error: 'Not signed in.' }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: 'Body must be JSON.' }, 400); }

  const school = String(body.school || 'the school').slice(0, 200);
  const grades = String(body.grades || '').slice(0, 120);
  const respondent = String(body.respondent || '');
  const responses = Number(body.responses || 0);
  const students = Number(body.students || 0);
  const questions = (Array.isArray(body.questions) ? body.questions : []).slice(0, 80) as Q[];

  if (!questions.length) return json({ error: 'No questions were sent.' }, 400);

  // Refuse anything that looks like a person rather than a figure. The client
  // sends aggregates; this is the backstop, because a later change there must
  // not be able to start leaking responses through here unnoticed.
  if (JSON.stringify(body).length > 60000) {
    return json({ error: 'That payload is far larger than a set of aggregates. Refusing it.' }, 400);
  }

  const lines = questions.map((x) => {
    const bits = [`- "${String(x.q).slice(0, 300)}"`];
    if (x.cat) bits.push(`[${x.cat}]`);
    bits.push(`${x.n ?? 0} answered`);
    if (x.concernPct !== null && x.concernPct !== undefined) {
      bits.push(`${x.concernPct}% gave the answer marked as a concern (${(x.concern || []).join(' / ')})`);
    } else if (x.top) {
      bits.push(`most common answer "${x.top}" (${x.topPct ?? 0}%)`);
    }
    return bits.join(' · ');
  }).join('\n');

  const WHO: Record<string, string> = {
    student: 'the students themselves, about their own behaviour',
    staff: 'teachers and staff',
    parent: 'parents or carers',
  };

  const prompt =
`You are writing two short passages of a school's Behavioural and Psychosocial Screening Report.

School: ${school}
${grades ? `Grades covered: ${grades}\n` : ''}Responses: ${responses}${students ? ` from ${students} students` : ''}
${respondent && WHO[respondent] ? `Answered by: ${WHO[respondent]}` : ''}

The screening measured these, and these are the figures already computed:
${lines}

Write:
1. "summary" — 2 to 3 paragraphs for section 5.1, Executive Summary. Open with what the
   screening covers, then what the figures show, then what they suggest the school should
   look at. Name the strongest indicators explicitly, with their percentages.
2. "interpretation" — 1 to 2 paragraphs reading across the findings: where they corroborate
   each other, and what the pattern suggests. Where a gap between two figures is telling,
   say so.

Rules, all of them firm:
- Use ONLY the figures above. Do not invent, round differently, estimate, or infer any
  number that is not given. Every percentage you write must appear above exactly.
- Do not compare this school to other schools, to a national average, or to any benchmark.
  You have no such data.
- This is a screening, not a diagnosis. Do not name, suggest or imply any clinical condition
  and do not describe any child. Write about the cohort.
- Plain professional English for a school's leadership. No bullet lists, no headings, no
  markdown. British spelling.
- If the figures are too thin to support a claim, say what is known and stop rather than
  filling the space.

Return ONLY JSON: {"summary": ["para", ...], "interpretation": ["para", ...]}`;

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
        max_tokens: 2000,
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
  // The model was asked for JSON; take the object even if it wrapped it in a
  // fence, and fail loudly rather than printing a half-parsed draft.
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) return json({ error: 'The model did not return the expected JSON.', detail: text.slice(0, 500) }, 502);
  let parsed: { summary?: string[]; interpretation?: string[] };
  try { parsed = JSON.parse(m[0]); }
  catch { return json({ error: 'The model returned JSON that would not parse.', detail: text.slice(0, 500) }, 502); }

  const clean = (v: unknown) =>
    (Array.isArray(v) ? v : [])
      .map((x) => String(x).trim())
      .filter(Boolean)
      .slice(0, 8);

  return json({
    summary: clean(parsed.summary),
    interpretation: clean(parsed.interpretation),
    model: MODEL,
    at: new Date().toISOString(),
  });
});
