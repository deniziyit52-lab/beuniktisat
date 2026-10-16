/* Uygulama olarak yüklenebilmek ve telefon bildirimlerini göstermek için arka plan dosyası. Önbellek tutmaz:
   fiyatlar ve sayfalar her zaman sunucudan gelir, eski sürüm görme sorunu olmaz. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

// Sunucudan gelen bildirim: { title, body, url }
self.addEventListener("push", (event) => {
    let data = {};
    try { data = event.data ? event.data.json() : {}; } catch (e) { data = { body: event.data ? event.data.text() : "" }; }
    event.waitUntil(self.registration.showNotification(data.title || "ZBEÜ Borsa", {
        body: data.body || "",
        icon: "/icons/icon-192.png",
        badge: "/icons/icon-192.png",
        lang: "tr",
        data: { url: data.url || "/" },
    }));
});

// Bildirime dokununca site açılır (açıksa o pencereye geçilir).
self.addEventListener("notificationclick", (event) => {
    event.notification.close();
    const url = new URL((event.notification.data && event.notification.data.url) || "/", self.location.origin).href;
    event.waitUntil((async () => {
        const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
        for (const c of all) {
            if (new URL(c.url).origin === self.location.origin) {
                await c.focus();
                return;
            }
        }
        await self.clients.openWindow(url);
    })());
});
