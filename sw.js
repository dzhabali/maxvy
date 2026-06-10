/* Ваджра-трекер — service worker для оффлайн-режима (PWA).
 *
 * Стратегия:
 *  - app-shell (HTML, manifest, иконки) + 3 скрипта Firebase с gstatic → кэшируем,
 *    отдаём по принципу stale-while-revalidate: мгновенно из кэша, фоном обновляем.
 *    Это даёт открытие приложения без сети (в т.ч. после перезапуска/блокировки телефона).
 *  - запросы к Firebase API (firestore / auth / googleapis) НЕ перехватываем —
 *    оффлайн их обслуживает сам Firestore через IndexedDB-persistence
 *    (очередь записей + чтение из кэша, синхронизация при возврате в сеть).
 *
 * Версию кэша поднимать при изменении состава precache.
 */
const CACHE = 'vajra-v6';

// gstatic-скрипты Firebase кэшируем как opaque (no-cors) — этого достаточно для <script src>.
const FIREBASE_LIBS = [
  'https://www.gstatic.com/firebasejs/10.12.4/firebase-app-compat.js',
  'https://www.gstatic.com/firebasejs/10.12.4/firebase-auth-compat.js',
  'https://www.gstatic.com/firebasejs/10.12.4/firebase-firestore-compat.js'
];

// Same-origin app-shell (относительные пути — работают и на Firebase Hosting, и на GitHub Pages).
const SHELL = [
  './',
  './vajra-tracker.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './icon-180.png'
];

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // app-shell — обычным запросом
    await cache.addAll(SHELL).catch(() => {});
    // Firebase-библиотеки — no-cors (opaque), по одной, чтобы один сбой не валил весь install
    await Promise.all(FIREBASE_LIBS.map(async url => {
      try { await cache.put(url, await fetch(new Request(url, { mode: 'no-cors' }))); } catch (e) {}
    }));
    self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

// Хосты Firebase/Google API — их не трогаем, всегда идём в сеть (оффлайн рулит сам Firestore SDK).
function isFirebaseApi(url) {
  return /(^|\.)googleapis\.com$/.test(url.hostname)
      || /(^|\.)firebaseio\.com$/.test(url.hostname)
      || /(^|\.)firebaseinstallations\.googleapis\.com$/.test(url.hostname)
      || /identitytoolkit/.test(url.hostname)
      || /firestore/.test(url.hostname);
}

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Firebase API — не перехватываем
  if (isFirebaseApi(url)) return;

  const isShell = url.origin === self.location.origin;
  const isFirebaseLib = FIREBASE_LIBS.includes(url.href);

  if (!isShell && !isFirebaseLib) return; // прочее (аналитика, шрифты и т.п.) — как есть

  // stale-while-revalidate
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req, { ignoreSearch: false });
    const network = fetch(req).then(resp => {
      // кэшируем только валидные/opaque ответы
      if (resp && (resp.ok || resp.type === 'opaque')) {
        cache.put(req, resp.clone()).catch(() => {});
      }
      return resp;
    }).catch(() => null);

    // Если кэша нет (первый заход) — ждём сеть, но не дольше 6с, иначе fallback на app-shell.
    // (Сеть всё равно докэширует ответ в .then выше, когда придёт.)
    const timed = new Promise(r => setTimeout(() => r(null), 6000));
    return cached || (await Promise.race([network, timed])) || cache.match('./vajra-tracker.html');
  })());
});
