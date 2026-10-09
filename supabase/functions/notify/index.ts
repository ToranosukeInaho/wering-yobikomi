// プッシュ通知を送る Edge Function。
//   type: "count"   … カウント係が +1 した直後にアプリから呼ぶ
//   type: "counter" … マスターがカウント係を指名した直後にアプリから呼ぶ
//   type: "hint"    … pg_cron から呼ぶ（新しいヒントが出たらその日の全員へ）
// デプロイ: supabase functions deploy notify --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:wering@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "content-type": "application/json" } });

type Sub = { endpoint: string; p256dh: string; auth: string };
type Msg = { title: string; body: string; tag: string };

async function send(subs: Sub[] | null, msg: Msg) {
  if (!subs?.length) return 0;
  const payload = JSON.stringify(msg);
  const results = await Promise.allSettled(subs.map((s) =>
    webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 600 })
  ));
  // 期限切れの登録は消す
  const dead = subs.filter((_, i) => {
    const r = results[i];
    return r.status === "rejected" && [404, 410].includes((r.reason as { statusCode?: number })?.statusCode ?? 0);
  });
  if (dead.length) await sb.from("push_subs").delete().in("endpoint", dead.map((d) => d.endpoint));
  return results.filter((r) => r.status === "fulfilled").length;
}

function background(p: Promise<unknown>) {
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(p); else p.catch(() => {});
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad_json" }, 400); }

  if (body.type === "count") {
    const { data: info, error } = await sb.rpc("_claim_count_notify", {
      p_id: body.id, p_secret: body.secret, p_count: body.count_id,
    });
    if (error || !info) return json({ ok: false }, 400);
    const { data: subs } = await sb.rpc("_push_targets", {
      p_day: info.day, p_team: info.team_id, p_mode: info.hidden ? "team" : "others", p_member: null,
    });
    const msg: Msg = info.hidden
      ? { title: `${info.team_name} +1！`, body: "あなたのチームに1人追加！この調子！", tag: "count" }
      : { title: `${info.team_name} +1`, body: "ライバルが呼び込み中！負けるな！", tag: "count" };
    background(send(subs, msg));
    return json({ ok: true });
  }

  if (body.type === "counter") {
    const { data: target, error } = await sb.rpc("_counter_target", { p_id: body.id, p_secret: body.secret });
    if (error || !target) return json({ ok: false }, 400);
    const { data: subs } = await sb.rpc("_push_targets", { p_day: null, p_team: null, p_mode: "member", p_member: target });
    background(send(subs, { title: "カウント係になりました", body: "アプリの「カウント」から +1 を押してね", tag: "counter" }));
    return json({ ok: true });
  }

  if (body.type === "hint") {
    if (!CRON_SECRET || body.cron_secret !== CRON_SECRET) return json({ ok: false }, 403);
    const { data: due } = await sb.rpc("_due_hint_slots");
    let sent = 0;
    for (const d of (due ?? []) as { day: string; slot: number }[]) {
      const { data: subs } = await sb.rpc("_push_targets", { p_day: d.day, p_team: null, p_mode: "day", p_member: null });
      sent += await send(subs, { title: "新しいヒントが出ました", body: "アプリを開いて、自分のチームの順位を推理しよう", tag: "hint" });
    }
    return json({ ok: true, slots: due?.length ?? 0, sent });
  }

  return json({ ok: false, error: "unknown_type" }, 400);
});
