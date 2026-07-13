// v5 · Kill-switch service worker
// Tidigare cachade vi index.html vilket gjorde att användare fastnade
// på gamla versioner. Nu avregistrerar SW sig själv och rensar caches.

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    // Rensa ALLA caches
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map(k => caches.delete(k)));
    } catch (e) {}
    // Avregistrera sig själv
    try {
      await self.registration.unregister();
    } catch (e) {}
    // Ladda om alla öppna flikar så de hämtar färska filer
    try {
      const clients = await self.clients.matchAll({ type: 'window' });
      clients.forEach(client => client.navigate(client.url));
    } catch (e) {}
  })());
});

// Inga fetch-event listeners — låt allt gå direkt till nätet
