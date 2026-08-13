/* Rex-Giddoty Hubs — native push, for the Android app
 *
 * The sibling of ../push. That one speaks Web Push to a browser, which posts
 * the notification and stamps the site's origin under it — an anti-spoofing
 * rule, and not something a site may switch off. This one speaks Firebase
 * Cloud Messaging to the app, which posts the notification itself: the app's
 * name, the app's icon, and nothing else attached.
 *
 * Called only by the database, which holds the shared key in private.app_secrets
 * — a table with no grants and no policies, so nothing carrying the public anon
 * key can read it.
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const SHARED = Deno.env.get('PUSH_SHARED_KEY')!;
/* The whole service-account JSON as Firebase downloads it. Kept in one secret
   rather than picked apart into three: the private key is multi-line PEM and
   survives the round trip far better inside JSON than as a bare env var. */
const SA = JSON.parse(Deno.env.get('FCM_SERVICE_ACCOUNT') ?? '{}');

const admin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

const b64url = (bytes: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/* ── the access token ──
 * FCM v1 wants a Google OAuth token, and the only way to one is a JWT signed
 * with the service account's RSA key. Held between invocations while the
 * container lives: they last an hour, and minting one costs a round trip to
 * Google before any notification can be sent.
 */
let cached: { token: string; expires: number } | null = null;

async function accessToken(): Promise<string> {
  if (cached && cached.expires > Date.now() + 60_000) return cached.token;

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: SA.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };

  const enc = new TextEncoder();
  const unsigned =
    b64url(enc.encode(JSON.stringify(header))) + '.' +
    b64url(enc.encode(JSON.stringify(claims)));

  /* The PEM arrives with literal \n inside the JSON string on some paths and
     real newlines on others, so both are normalised before the base64 body is
     pulled out of it. */
  const pem = String(SA.private_key ?? '').replace(/\\n/g, '\n');
  const der = Uint8Array.from(
    atob(pem.replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, '')),
    (c) => c.charCodeAt(0),
  );

  const key = await crypto.subtle.importKey(
    'pkcs8', der,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false, ['sign'],
  );
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, enc.encode(unsigned));
  const jwt = unsigned + '.' + b64url(sig);

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  const json = await res.json();
  if (!json.access_token) throw new Error('oauth: ' + JSON.stringify(json));

  cached = { token: json.access_token, expires: Date.now() + (json.expires_in ?? 3600) * 1000 };
  return cached.token;
}

Deno.serve(async (req) => {
  /* The function is reachable from the internet, so the caller has to prove it
     is the database and not somebody who guessed the URL. */
  if (req.headers.get('Authorization') !== `Bearer ${SHARED}`) {
    return new Response('no', { status: 401 });
  }
  if (!SA.client_email || !SA.private_key || !SA.project_id) {
    return new Response('fcm not configured', { status: 503 });
  }

  const { user_id, title, body, url } = await req.json().catch(() => ({}));
  if (!user_id || !title) return new Response('bad request', { status: 400 });

  const { data: rows } = await admin
    .from('device_tokens')
    .select('id,token')
    .eq('user_id', user_id);

  if (!rows?.length) return Response.json({ sent: 0 });

  const bearer = await accessToken();
  const endpoint =
    `https://fcm.googleapis.com/v1/projects/${SA.project_id}/messages:send`;

  let sent = 0;
  const dead: string[] = [];

  await Promise.all(rows.map(async (r) => {
    const message = {
      token: r.token,
      /* A notification block rather than data alone: with it, Android draws and
         posts the banner even when the app is not running, which is the whole
         point. The url rides in data, where the tap handler reads it. */
      notification: { title, body: body ?? '' },
      data: { url: url ?? '/' },
      android: {
        priority: 'HIGH',
        notification: {
          /* Matching the web side: several updates to one order replace each
             other rather than stacking. */
          tag: url ?? 'rg',
          default_sound: true,
        },
      },
    };

    const res = await fetch(endpoint, {
      method: 'POST',
      headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ message }),
    });

    if (res.ok) { sent++; return; }

    /* UNREGISTERED means the app was uninstalled or its token rotated;
       INVALID_ARGUMENT on a token means it was never ours. Either way, keeping
       the row means trying again for ever. */
    const text = await res.text();
    if (res.status === 404 || /UNREGISTERED|INVALID_ARGUMENT/.test(text)) dead.push(r.id);
    else console.error('fcm', res.status, text);
  }));

  if (dead.length) await admin.from('device_tokens').delete().in('id', dead);

  return Response.json({ sent, dropped: dead.length });
});
