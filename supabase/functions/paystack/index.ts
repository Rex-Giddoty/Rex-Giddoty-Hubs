/* Rex-Giddoty Hubs — Paystack
 *
 * Three jobs, one function:
 *
 *   init     a signed-in customer asks to pay for an order they own. The amount
 *            is read from the order in the database, never from the request —
 *            a browser that could name its own price would be the whole story.
 *   verify   the customer comes back from the payment page. We ask Paystack
 *            what happened rather than believing the query string.
 *   webhook  Paystack tells us directly. Signed, and the only source that works
 *            when the customer closes the tab on the payment screen.
 *
 * The last two both settle, and settling is idempotent in SQL, so it does not
 * matter which arrives first or how many times.
 *
 * The secret key exists in this function's environment and nowhere else. It is
 * not in the repository, not in site_settings, and never sent to a browser.
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const SECRET = Deno.env.get('PAYSTACK_SECRET_KEY') ?? '';
const SITE = Deno.env.get('SITE_URL') ?? 'https://rexgiddotyhubs.shop';
const PS = 'https://api.paystack.co';

const admin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...cors },
  });

/* The shop and the Android app both call this from a page, so the browser asks
   permission first. */
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const ps = (path: string, init?: RequestInit) =>
  fetch(PS + path, {
    ...init,
    headers: {
      Authorization: `Bearer ${SECRET}`,
      'Content-Type': 'application/json',
      ...(init?.headers ?? {}),
    },
  });

/* ── who is asking ──
 * The webhook has no user, so this is only used by init and verify. A valid
 * token is not enough on its own: the order has to be theirs.
 */
async function caller(req: Request) {
  const auth = req.headers.get('Authorization') ?? '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user || data.user.is_anonymous) return null;
  return data.user;
}

/* Paystack signs the raw body with the secret key. Compared in constant time,
   because comparing signatures with === leaks how much of a guess was right. */
async function signatureOk(raw: string, sent: string | null) {
  if (!sent) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(SECRET),
    { name: 'HMAC', hash: 'SHA-512' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw));
  const mine = [...new Uint8Array(mac)].map(b => b.toString(16).padStart(2, '0')).join('');
  if (mine.length !== sent.length) return false;
  let diff = 0;
  for (let i = 0; i < mine.length; i++) diff |= mine.charCodeAt(i) ^ sent.charCodeAt(i);
  return diff === 0;
}

async function settle(d: Record<string, any>, eventId?: string) {
  const { data, error } = await admin.rpc('paystack_settle', {
    p_reference: d.reference,
    p_amount_minor: d.amount,          // Paystack counts in kobo; so do we
    p_currency: d.currency ?? 'NGN',
    p_event_id: eventId ?? null,
    p_payload: d,
  });
  if (error) throw new Error(error.message);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (!SECRET) return json({ error: 'paystack not configured' }, 503);

  const path = new URL(req.url).pathname;

  /* ── the webhook ── */
  if (path.endsWith('/webhook')) {
    const raw = await req.text();
    if (!await signatureOk(raw, req.headers.get('x-paystack-signature'))) {
      return new Response('bad signature', { status: 401 });
    }

    let body: Record<string, any> = {};
    try { body = JSON.parse(raw); } catch { /* answered 200 below regardless */ }

    if (body.event === 'charge.success' && body.data?.status === 'success') {
      try {
        await settle(body.data, String(body.data.id ?? body.data.reference));
      } catch (err) {
        /* A 500 makes Paystack retry, which is what we want for a database that
           was briefly unreachable — but not for a payload we will never accept. */
        console.error('settle failed', err);
        return new Response('retry', { status: 500 });
      }
    }
    /* Anything else is acknowledged and ignored, or Paystack retries it for
       days over an event we do not act on. */
    return new Response('ok', { status: 200 });
  }

  if (req.method !== 'POST') return json({ error: 'method' }, 405);

  const { action, order_id, reference } = await req.json().catch(() => ({} as any));

  /* ── starting a payment ── */
  if (action === 'init') {
    const user = await caller(req);
    if (!user) return json({ error: 'sign in first' }, 401);

    const { data: order } = await admin
      .from('orders')
      .select('id,order_number,total_minor,currency,email,payment_status,user_id')
      .eq('id', order_id)
      .maybeSingle();

    if (!order || order.user_id !== user.id) return json({ error: 'no such order' }, 404);
    if (order.payment_status === 'paid') return json({ error: 'already paid' }, 409);

    /* ── while the shop is on test keys ──
     * Paystack's test cards are published on their own website. A shop that is
     * reachable on the open internet and running a test key will happily mark
     * orders paid for anyone who has read the docs, with no money anywhere.
     * So on a test key only staff may start a payment. The guard lifts itself
     * the moment a live key is in place — there is nothing to remember to
     * switch off. */
    if (SECRET.startsWith('sk_test_')) {
      const { data: staff } = await admin
        .from('admin_users').select('id').eq('id', user.id).maybeSingle();
      if (!staff) {
        return json({ error: 'Card payment is not open yet. Please contact us to complete this order.' }, 503);
      }
    }

    /* Unique per attempt: Paystack refuses a reference it has seen, and a
       customer who abandons one payment must be able to start another. The
       database remembers every reference an order has been given. */
    const ref = `${order.order_number}-${crypto.randomUUID().slice(0, 8)}`;

    const res = await ps('/transaction/initialize', {
      method: 'POST',
      body: JSON.stringify({
        email: order.email ?? user.email,
        amount: order.total_minor,        // the order's amount, not the caller's
        currency: order.currency ?? 'NGN',
        reference: ref,
        callback_url: `${SITE}/order.html?n=${encodeURIComponent(order.order_number)}&ref=${encodeURIComponent(ref)}`,
        metadata: { order_id: order.id, order_number: order.order_number },
      }),
    });
    const out = await res.json();
    if (!res.ok || !out.status) {
      console.error('initialize failed', out);
      return json({ error: out.message ?? 'could not start the payment' }, 502);
    }

    const { error: attachErr } = await admin.rpc('paystack_attach_ref',
      { p_order: order.id, p_ref: ref });
    if (attachErr) return json({ error: attachErr.message }, 500);

    return json({
      reference: ref,
      access_code: out.data.access_code,
      authorization_url: out.data.authorization_url,
    });
  }

  /* ── the customer coming back ── */
  if (action === 'verify') {
    const user = await caller(req);
    if (!user) return json({ error: 'sign in first' }, 401);
    if (!reference) return json({ error: 'reference' }, 400);

    const res = await ps('/transaction/verify/' + encodeURIComponent(reference));
    const out = await res.json();
    if (!res.ok || !out.status) return json({ error: 'could not check that payment' }, 502);

    if (out.data.status !== 'success') {
      return json({ paid: false, status: out.data.status });
    }
    const result = await settle(out.data, String(out.data.id ?? reference));
    return json({ paid: !!result?.ok, ...result });
  }

  return json({ error: 'unknown action' }, 400);
});
