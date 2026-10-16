/* Uygulama olarak yüklenebilmek için arka plan dosyası. Önbellek tutmaz: fiyatlar ve sayfalar her zaman
   sunucudan gelir, eski sürüm görme sorunu olmaz. İleride telefon bildirimleri de buradan gösterilecek. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
