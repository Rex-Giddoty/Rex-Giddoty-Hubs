/* Rex-Giddoty Hubs — service worker
 *
 * The one rule that matters in a shop: never serve a cached price. Everything
 * that decides what a customer pays or what is in stock comes from Supabase
 * over the network, and those requests are not touched here at all. What is
 * cached is the shell — the stylesheet, the script, the logo — so a page opens
 * instantly and still has something to show on a bad signal.
 *
 * Bump CACHE when the shell changes; the old one is deleted on activate.
 */
const CACHE = 'rg-shell-v13';

const SHELL = [
  '/',
  '/offline.html',
  '/assets/site.css',
  '/assets/site.js',
  '/supabase.js',
  '/assets/logo.png',
  '/assets/logo-mark.png',
  '/assets/icon-192.png',
  '/manifest.webmanifest',
];

self.addEventListener('install', e => {
  /* addAll fails the whole install if one file 404s, so they go in one at a
     time: a missing icon should not cost the shop its offline page. */
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await Promise.all(SHELL.map(url => cache.add(url).catch(() => {})));
    self.skipWaiting();
  })());
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

/* Staff work in a browser, and their console has its own session and its own
   freshness needs. It is left entirely alone.

   Its stylesheet counts as part of it. That file lives under /assets like the
   shop's, so it used to fall through to the shell rule below — which answers
   from cache first and only refreshes afterwards. Right for a storefront,
   wrong here: it made every change to the console appear one visit late, so a
   change that had plainly shipped looked like it had not. */
const isOps = url => /^\/ops(-|\.)/.test(url.pathname)
                  || url.pathname === '/assets/ops.css';

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  /* Anything that is not this site — Supabase, the fonts CDN, the supabase-js
     bundle — is left to the network. Prices, stock and orders are in that
     first group and must never come from a cache. */
  if (url.origin !== self.location.origin) return;

  /* Staff pages are never stored — but a navigation still needs an answer when
     there is no network, or Chrome will not treat the console as installable.
     Network first, nothing kept, the shared offline page if it fails. */
  if (isOps(url)) {
    if (req.mode === 'navigate') {
      e.respondWith(
        fetch(req).catch(() => caches.match('/offline.html')
          .then(r => r || new Response('Offline', { status: 503 }))));
    }
    return;
  }

  /* A page: try the network so the catalogue is current, fall back to the copy
     we have, and only then to the offline page. */
  if (req.mode === 'navigate') {
    e.respondWith((async () => {
      try {
        const fresh = await fetch(req);
        const cache = await caches.open(CACHE);
        cache.put(req, fresh.clone());
        return fresh;
      } catch (_) {
        return (await caches.match(req))
            || (await caches.match('/offline.html'))
            || Response.error();
      }
    })());
    return;
  }

  /* The shell: answer from cache at once, and refresh it in the background so
     the next load has the new one. */
  if (/\.(css|js|png|jpg|jpeg|webp|avif|svg|webmanifest)$/i.test(url.pathname)) {
    e.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(req);
      const net = fetch(req).then(res => {
        if (res && res.ok) cache.put(req, res.clone());
        return res;
      }).catch(() => hit);
      return hit || net;
    })());
  }
});

/* ── push ──
 * The payload is built by the edge function and carries only what the banner
 * shows: a title, a line, and where tapping it should land.
 */
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) {}
  const title = d.title || 'Rex-Giddoty Hubs';
  e.waitUntil((async () => {
    await self.registration.showNotification(title, {
      body: d.body || '',
      icon: '/assets/icon-192.png',
      badge: '/assets/icon-192.png',
      data: { url: d.url || '/' },
      /* One tag per kind, so three status changes on one order replace each other
         rather than stacking three banners on the lock screen. */
      tag: d.url || 'rg',
      renotify: true,
    });
    /* Any tab that is open gets told, so it can ring the shop's own double bell.
       Android draws the banner itself and sounds the channel's tone, which a
       website is not permitted to change — so this is the only place a sound of
       ours can come from. */
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) c.postMessage({ type: 'rg-push' });
  })());
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil((async () => {
    /* If the shop is already open somewhere, go to it rather than opening a
       second copy of the app. */
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if (new URL(c.url).origin === self.location.origin) {
        await c.focus();
        if ('navigate' in c) await c.navigate(url);
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
