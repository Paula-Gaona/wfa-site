// WFA app helper (service worker). It's what lets the site install as an app (its own window and icon).
// Pages always load fresh from the network when online, so every deploy shows up right away; the last copy is
// only used if there's no connection. Logos and icons are kept for speed. Club data (Supabase) is never cached here.
const CACHE = 'wfa-v6';

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

// Push notifications (from supabase/push.ts) arrive here, even when the site and app are closed.
// If a WFA window is in use, the site shows the message itself (and plays the chime), so no pop-up is needed.
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil((async () => {
    const wins = (await self.clients.matchAll({ type: 'window', includeUncontrolled: true }))
      .filter((w) => new URL(w.url).origin === self.location.origin);
    if (wins.some((w) => w.focused)) return;
    try { if (self.navigator.setAppBadge) await self.navigator.setAppBadge(); } catch (err) { /* badges not supported */ }
    const url = d.url || '/';
    const chat = (url.split('#messages/')[1] || '');
    await self.registration.showNotification(d.title || 'Wolverine Finance Association', {
      body: d.body || '', icon: '/icon-192.png', badge: '/icon-48.png', tag: d.tag || String(Date.now()), data: { chat, url } });
  })());
});

// Clicking a notification: bring a WFA window forward and open what it's about (a chat, an event, ...).
// If none can be brought forward (or none is open), opens the site, which opens in the installed app if there is one.
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const data = e.notification.data || {}, chat = data.chat || '';
  const url = data.url ? new URL(data.url, self.location.origin).href : new URL('/#messages' + (chat ? '/' + chat : ''), self.location.origin).href;
  e.waitUntil((async () => {
    const wins = (await self.clients.matchAll({ type: 'window', includeUncontrolled: true }))
      .filter((w) => new URL(w.url).origin === self.location.origin);
    wins.forEach((w) => w.postMessage(chat || !data.url ? { openChat: chat } : { openUrl: url }));
    const win = wins.find((w) => w.focused) || wins.find((w) => w.visibilityState === 'visible') || wins[0];
    if (win) {
      try { if (await win.focus()) return; } catch (err) { /* couldn't bring it forward */ }
    }
    try { await self.clients.openWindow(url); } catch (err) { /* nothing more we can do */ }
  })());
});
