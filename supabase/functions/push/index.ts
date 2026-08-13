/* Rex-Giddoty Hubs — the one thing SQL cannot do
 *
 * Web Push needs a VAPID token signed with ES256 and a payload encrypted with
 * ECDH + HKDF + AES-GCM against each subscriber's own key. Postgres has none of
 * that, so the triggers call here.
 *
 * Called only by the database, which holds the shared key in private.app_secrets
 * — a table with no grants and no policies, so nothing carrying the public anon
 * key can read it.
 */
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'jsr:@supabase/supabase-js@2';

const PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY')!;
const PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY')!;
const SHARED = Deno.env.get('PUSH_SHARED_KEY')!;
const SUBJECT = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:rexgiddotyhubs@gmail.com';

webpush.setVapidDetails(SUBJECT, PUBLIC_KEY, PRIVATE_KEY);

const admin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

Deno.serve(async (req) => {
  /* The function is reachable from the internet, so the caller has to prove it
     is the database and not somebody who guessed the URL. */
  if (req.headers.get('Authorization') !== `Bearer ${SHARED}`) {
    return new Response('no', { status: 401 });
  }

  const { user_id, title, body, url } = await req.json().catch(() => ({}));
  if (!user_id || !title) return new Response('bad request', { status: 400 });

  const { data: subs } = await admin
    .from('push_subscriptions')
    .select('id,endpoint,p256dh,auth')
    .eq('user_id', user_id);

  if (!subs?.length) return Response.json({ sent: 0 });

  const payload = JSON.stringify({ title, body: body ?? '', url: url ?? '/' });
  let sent = 0;
  const dead: string[] = [];

  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload,
        { TTL: 60 * 60 * 24 },
      );
      sent++;
    } catch (err) {
      /* 404 and 410 mean the browser threw the subscription away — the app was
         uninstalled, or notifications were turned off. Keeping it would mean
         trying again for ever. */
      const code = (err as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) dead.push(s.id);
    }
  }));

  if (dead.length) await admin.from('push_subscriptions').delete().in('id', dead);
  if (sent) {
    await admin.from('push_subscriptions')
      .update({ last_ok_at: new Date().toISOString() })
      .eq('user_id', user_id);
  }

  return Response.json({ sent, dropped: dead.length });
});
