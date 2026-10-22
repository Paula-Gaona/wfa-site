// WFA app helper (service worker). It's what lets the site install as an app (its own window and icon).
// Pages always load fresh from the network when online, so every deploy shows up right away; the last copy is
// only used if there's no connection. Logos and icons are kept for speed. Club data (Supabase) is never cached here.
const CACHE = 'wfa-v3';

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));

self.addEventListener('fetch', (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then((r) => {
      if (r.ok) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put('/', copy)); }
      return r;
    }).catch(() => caches.match('/')));
    return;
  }
  if (/\.(png|svg|ico|webp|jpg)$/.test(url.pathname)) {
    e.respondWith(caches.match(req).then((hit) => {
      const net = fetch(req).then((r) => { if (r.ok) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); } return r; });
      return hit || net;
    }));
  }
});

// Clicking a message pop-up: bring a WFA window forward and open that chat. Prefers the window the person was last
// using; if none can be brought forward (or none is open), opens the site, which opens in the installed app if there is one.
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const chat = (e.notification.data || {}).chat || '';
  const url = new URL('/#messages' + (chat ? '/' + chat : ''), self.location.origin).href;
  e.waitUntil((async () => {
    const wins = (await self.clients.matchAll({ type: 'window', includeUncontrolled: true }))
      .filter((w) => new URL(w.url).origin === self.location.origin);
    const win = wins.find((w) => w.focused) || wins.find((w) => w.visibilityState === 'visible') || wins[0];
    if (win) {
      try {
        const focused = await win.focus();
        if (focused) { try { await focused.navigate(url); } catch (err) { focused.postMessage({ openChat: chat }); } return; }
      } catch (err) { /* couldn't bring it forward; open a window instead */ }
    }
    await self.clients.openWindow(url);
  })());
});
