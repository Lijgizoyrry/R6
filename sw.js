// R6 Playbook — service worker
// • Coquille de l'app en cache : ouverture instantanée, même hors ligne.
// • Pages : réseau d'abord (les mises à jour GitHub/Vercel arrivent tout de suite), cache en secours.
// • supabase-js (CDN) : cache d'abord, il ne change pas.
// • Supabase et YouTube ne passent jamais par ce cache.

const VERSION = 'r6pb-v1';
const SHELL = ['./', './config.js', './manifest.webmanifest', './icon-192.png', './icon-512.png', './apple-touch-icon.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(VERSION)
      .then((cache) => cache.addAll(SHELL))
      .catch(() => {})
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('r6pb-') && k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

function timeout(ms) {
  return new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), ms));
}

async function networkFirst(request, cacheKey, ms = 3500) {
  const cache = await caches.open(VERSION);
  try {
    const response = await Promise.race([fetch(request), timeout(ms)]);
    if (response && response.ok && !response.redirected) cache.put(cacheKey || request, response.clone());
    return response;
  } catch (err) {
    const hit = await cache.match(cacheKey || request, { ignoreSearch: true });
    if (hit) return hit;
    throw err;
  }
}

async function cacheFirst(request) {
  const cache = await caches.open(VERSION);
  const hit = await cache.match(request);
  if (hit) return hit;
  const response = await fetch(request);
  if (response && response.ok) cache.put(request, response.clone());
  return response;
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(VERSION);
  const hit = await cache.match(request);
  const network = fetch(request)
    .then((response) => { if (response && response.ok && !response.redirected) cache.put(request, response.clone()); return response; })
    .catch(() => hit);
  return hit || network;
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);

  if (url.origin === self.location.origin) {
    if (request.mode === 'navigate') { event.respondWith(networkFirst(request, './')); return; }
    if (url.pathname.endsWith('/config.js') || url.pathname.endsWith('/sw.js')) { event.respondWith(networkFirst(request)); return; }
    event.respondWith(staleWhileRevalidate(request));
    return;
  }

  if (url.hostname === 'cdn.jsdelivr.net' || url.hostname === 'esm.sh') {
    event.respondWith(cacheFirst(request));
  }
});
