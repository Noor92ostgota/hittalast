// hittalast.se Service Worker — robust version
// Strategi: network-first för HTML, cache-first för statiska assets, INGEN cache av API-anrop.
// Designad för att aldrig hänga sig även vid nätverksfel eller race conditions mellan flikar.

const CACHE_VERSION = 'v3-2026-06-09';
const CACHE_NAME = `hittalast-${CACHE_VERSION}`;
const STATIC_ASSETS = ['/index.html', '/logo.png', '/manifest.json'];

// INSTALL — pre-cacha statiska assets, men HÄNG ALDRIG om enskilda failar
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) =>
        // Promise.allSettled: enskilda fel stoppar inte hela installationen
        Promise.allSettled(
          STATIC_ASSETS.map((url) =>
            cache.add(url).catch((err) => {
              console.warn('[SW] Kunde inte pre-cacha:', url, err.message);
            })
          )
        )
      )
      .then(() => self.skipWaiting())
      .catch((err) => {
        console.error('[SW] Install-fel (forsätter ändå):', err);
        return self.skipWaiting();
      })
  );
});

// ACTIVATE — rensa gamla caches + ta över omedelbart
self.addEventListener('activate', (event) => {
  event.waitUntil(
    Promise.all([
      caches.keys().then((keys) =>
        Promise.all(
          keys
            .filter((k) => k.startsWith('hittalast-') && k !== CACHE_NAME)
            .map((k) => caches.delete(k))
        )
      ),
      self.clients.claim()
    ])
  );
});

// FETCH — robust hantering med fallbacks som ALDRIG kastar
self.addEventListener('fetch', (event) => {
  const req = event.request;

  // Hantera bara GET — POST/PUT/DELETE/etc går direkt till nätet
  if (req.method !== 'GET') return;

  let url;
  try {
    url = new URL(req.url);
  } catch {
    return; // Ogiltig URL — låt browsern hantera
  }

  // Cross-origin (Supabase API, Resend, GitHub etc) — låt browsern hantera direkt
  if (url.origin !== self.location.origin) return;

  // Hoppa över skript som inte är HTTP/HTTPS
  if (!url.protocol.startsWith('http')) return;

  // NAVIGATION (HTML-sidor): network-first med cache-fallback
  if (req.mode === 'navigate' || url.pathname.endsWith('.html') || url.pathname === '/') {
    event.respondWith(
      fetch(req)
        .then((resp) => {
          // Cacha bara lyckade svar — i bakgrunden, blockerar aldrig
          if (resp && resp.ok && resp.type === 'basic') {
            const respClone = resp.clone();
            caches.open(CACHE_NAME)
              .then((cache) => cache.put(req, respClone))
              .catch(() => {}); // Race conditions ignoreras tyst
          }
          return resp;
        })
        .catch(() =>
          // Offline-fallback: använd cachad version eller fallback till /index.html
          caches.match(req).then((cached) =>
            cached || caches.match('/index.html') ||
            new Response('Offline', { status: 503, statusText: 'Offline' })
          )
        )
    );
    return;
  }

  // STATISKA ASSETS (bilder, ikoner, manifest): cache-first
  if (url.pathname.match(/\.(png|jpg|jpeg|gif|svg|webp|ico|json|css|woff2?|ttf)$/i)) {
    event.respondWith(
      caches.match(req)
        .then((cached) => {
          if (cached) return cached;
          return fetch(req)
            .then((resp) => {
              if (resp && resp.ok && resp.type === 'basic') {
                const respClone = resp.clone();
                caches.open(CACHE_NAME)
                  .then((cache) => cache.put(req, respClone))
                  .catch(() => {});
              }
              return resp;
            })
            .catch(() => caches.match(req)); // Sista försök från cache
        })
        .catch(() => fetch(req)) // Om cache.match failar, gå direkt till nätet
    );
    return;
  }

  // ALLT ANNAT — låt browsern hantera direkt (inga konstigheter)
});

// MESSAGE — för manuell uppdatering av SW från klienten
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
