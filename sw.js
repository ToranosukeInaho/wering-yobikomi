// 通知を受け取って表示するだけのサービスワーカー
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (e) => {
  let d = { title: "wering", body: "", tag: "wering" };
  try { d = { ...d, ...e.data.json() }; } catch { /* 文字だけ届いたとき */ }
  e.waitUntil(self.registration.showNotification(d.title, {
    body: d.body,
    tag: d.tag,                       // 同じ種類の通知は1件に上書き（連打で鳴りっぱなしにしない）
    renotify: d.tag !== "count",
    icon: "icons/icon-192.png",
    badge: "icons/badge-96.png",
  }));
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  e.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of list) { if ("focus" in c) return c.focus(); }
    return self.clients.openWindow("./");
  })());
});
