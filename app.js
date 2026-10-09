/* wering 呼び込みランキング戦 — 画面とSupabaseのやりとり（ビルド不要の素のJS） */
(() => {
  "use strict";
  const CFG = window.WERING || {};
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const store = {
    get: (k) => { try { return localStorage.getItem("wering." + k); } catch { return null; } },
    set: (k, v) => { try { v == null ? localStorage.removeItem("wering." + k) : localStorage.setItem("wering." + k, v); } catch { /* 保存できない端末 */ } },
  };

  const DAYS = ["11/3", "11/4"];
  const S = {
    id: store.get("id"), secret: store.get("secret"), me: null,
    day: todayDay(), tab: "rank",
    board: null, hints: [], teams: { "11/3": [], "11/4": [] }, recent: [],
    members: [], hist: [], settings: null,
    pending: null, pushOn: false, logoTaps: 0, showKey: false, tick: 0,
  };

  // ---------- 共通 ----------
  function todayDay() {
    const d = new Date(Date.now() + 9 * 3600e3); // JST
    return d.getUTCMonth() === 10 && d.getUTCDate() === 4 ? "11/4" : "11/3";
  }
  const hhmm = (iso) => { const d = new Date(iso); return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"); };
  const auth = () => ({ p_id: S.id, p_secret: S.secret });

  const ERR = {
    not_registered: "登録が見つかりません。もう一度名前を入れてください。",
    not_counter: "いまはカウント係ではありません。",
    not_master: "マスター専用の操作です。",
    no_team: "チームが見つかりません。",
  };
  function status(msg) { const el = $("status"); el.textContent = msg || ""; el.hidden = !msg; }

  async function api(fn, args = {}) {
    const headers = { apikey: CFG.SUPABASE_KEY, "Content-Type": "application/json" };
    if (String(CFG.SUPABASE_KEY || "").startsWith("eyJ")) headers.Authorization = "Bearer " + CFG.SUPABASE_KEY;
    let res;
    try {
      res = await fetch(CFG.SUPABASE_URL + "/rest/v1/rpc/" + fn, { method: "POST", headers, body: JSON.stringify(args) });
    } catch {
      throw Object.assign(new Error("電波が弱いかも。もう一度試してください。"), { code: "network" });
    }
    const text = await res.text();
    const data = text ? JSON.parse(text) : null;
    if (!res.ok) {
      const key = (data && data.message) || "";
      throw Object.assign(new Error(ERR[key] || "うまくいきませんでした（" + (key || res.status) + "）"), { code: key });
    }
    return data;
  }
  function notify(body) {
    fetch(CFG.SUPABASE_URL + "/functions/v1/notify", {
      method: "POST",
      headers: { apikey: CFG.SUPABASE_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ ...body, id: S.id, secret: S.secret }),
    }).catch(() => {});
  }
  function fail(e) {
    if (e && e.code === "not_registered") { resetIdentity(); return; }
    status(e && e.message ? e.message : "うまくいきませんでした。");
  }

  let toastTimer = null, undoId = null;
  function toast(text, countId) {
    $("toast-text").textContent = text; undoId = countId || null;
    $("toast-undo").hidden = !countId; $("toast").hidden = false;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { $("toast").hidden = true; }, 4000);
  }
  $("toast-undo").addEventListener("click", () => { if (undoId) undoCount(undoId); $("toast").hidden = true; });

  // ---------- 起動 ----------
  const standalone = matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
  if (new URLSearchParams(location.search).has("web")) store.set("web", "1"); // PCで確認する用の抜け道
  const webOK = store.get("web") === "1";

  function show(screen) {
    ["s-install", "s-register", "s-main"].forEach((s) => { $(s).hidden = s !== screen; });
    $("nav").hidden = screen !== "s-main";
  }

  function resetIdentity() {
    store.set("id", null); store.set("secret", null); S.id = S.secret = null; S.me = null;
    show("s-register"); status("登録が見つかりませんでした。もう一度名前を入れてください。");
  }

  function initInstall() {
    show("s-install");
    const ua = navigator.userAgent;
    $("install-line").hidden = !/ Line\//i.test(ua);
    const android = /Android/i.test(ua);
    $("install-ios").hidden = android; $("install-android").hidden = !android;
    let deferred = null;
    addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); deferred = e; $("install-btn").hidden = false; });
    $("install-btn").addEventListener("click", async () => { if (deferred) { deferred.prompt(); deferred = null; } });
  }

  $("reg-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const name = $("reg-name").value.trim(); if (!name) return;
    const bytes = crypto.getRandomValues(new Uint8Array(24));
    const secret = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    try {
      const id = await api("register", { p_name: name, p_secret: secret });
      S.id = id; S.secret = secret; store.set("id", id); store.set("secret", secret);
      status(""); start();
    } catch (e) { fail(e); }
  });

  async function start() {
    show("s-main");
    if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js").catch(() => {});
    await loadMe();
    if (!S.me) return;
    syncPush();
    await refresh();
    setInterval(() => { if (!document.hidden) refresh(); }, 10000);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
  }

  async function loadMe() {
    try { S.me = await api("me", auth()); status(""); } catch (e) { fail(e); }
    renderNav();
  }

  async function refresh() {
    S.tick++;
    try {
      if (S.tick % 3 === 0) await loadMe();
      const [board, teams] = await Promise.all([
        api("get_board", { p_day: S.day, ...auth() }),
        api("list_teams", { p_day: S.day }),
      ]);
      S.board = board; S.teams[S.day] = teams;
      const myDay = S.me && S.me.team_day === S.day;
      S.hints = board.hidden && myDay ? await api("get_hints", { ...auth(), p_day: S.day }) : [];
      if (S.me && (S.me.is_counter || S.me.is_master)) S.recent = await api("history", { ...auth(), p_day: S.day, p_limit: 10 });
      if (S.me && S.me.is_master && S.tab === "master") await loadMaster();
      status("");
    } catch (e) { fail(e); }
    renderAll();
  }

  async function loadMaster() {
    const [members, hist, settings] = await Promise.all([
      api("list_members", auth()),
      api("history", { ...auth(), p_day: S.day, p_limit: 5000 }),
      api("get_settings", auth()),
    ]);
    S.members = members; S.hist = hist; S.settings = settings;
  }

  // ---------- 通知 ----------
  function b64ToBytes(b64) {
    const pad = "=".repeat((4 - (b64.length % 4)) % 4);
    const raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(raw, (c) => c.charCodeAt(0));
  }
  const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  async function syncPush() {
    if (!pushSupported() || Notification.permission !== "granted") { S.pushOn = false; return; }
    try { await subscribe(); } catch { S.pushOn = false; }
  }
  async function subscribe() {
    const reg = await navigator.serviceWorker.ready;
    let sub = await reg.pushManager.getSubscription();
    if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(CFG.VAPID_PUBLIC_KEY) });
    const j = sub.toJSON();
    await api("save_push", { ...auth(), p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth });
    S.pushOn = true;
  }
  async function enablePush() {
    if (!pushSupported()) { status("この端末・開き方では通知が使えません。ホーム画面のアイコンから開いてください。"); return; }
    const perm = await Notification.requestPermission();
    if (perm !== "granted") { status("通知が許可されませんでした。設定アプリの通知からweringをONにしてください。"); return; }
    try { await subscribe(); status(""); toast("通知ON！"); } catch (e) { fail(e); }
    renderAll();
  }

  // ---------- 操作 ----------
  async function addCount(teamId) {
    try {
      const id = await api("add_count", { ...auth(), p_team: teamId });
      const t = S.teams[S.day].find((x) => x.id === teamId);
      toast((t ? t.name : "") + " +1", id);
      notify({ type: "count", count_id: id });
      refresh();
    } catch (e) { fail(e); loadMe().then(renderAll); }
  }
  async function undoCount(id) {
    try { await api("undo_count", { ...auth(), p_count: Number(id) }); toast("取り消しました"); refresh(); } catch (e) { fail(e); }
  }
  async function pickTeam(teamId) {
    try { await api("set_my_team", { ...auth(), p_team: teamId }); await loadMe(); toast("チームを登録しました"); refresh(); } catch (e) { fail(e); }
  }
  async function masterDo(fn, args, msg) {
    try { await api(fn, { ...auth(), ...args }); if (msg) toast(msg); S.pending = null; await loadMe(); await refresh(); } catch (e) { fail(e); }
  }

  // ---------- 画面 ----------
  function renderNav() {
    const tabs = [["rank", "ランキング"]];
    if (S.me && (S.me.is_counter || S.me.is_master)) tabs.push(["count", "カウント"]);
    tabs.push(["me", "マイページ"]);
    if (S.me && S.me.is_master) tabs.push(["master", "マスター"]);
    if (!tabs.some(([k]) => k === S.tab)) S.tab = "rank";
    $("nav").innerHTML = tabs.map(([k, l]) => `<button data-tab="${k}" aria-pressed="${k === S.tab}">${l}</button>`).join("");
  }

  const editing = (el) => el.contains(document.activeElement) && /INPUT|SELECT/.test(document.activeElement.tagName);

  function renderAll() {
    document.querySelectorAll("[data-day]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.day === S.day)));
    renderNav();
    ["rank", "count", "me", "master"].forEach((v) => { $("v-" + v).hidden = S.tab !== v; });
    const views = { rank: renderRank, count: renderCount, me: renderMe, master: renderMaster };
    for (const [k, fn] of Object.entries(views)) {
      const el = $("v-" + k);
      if (k === S.tab && editing(el)) continue; // 入力中は書き換えない
      el.innerHTML = S.me ? fn() : "";
      el.style.cssText = "display:grid;gap:12px";
      if (S.tab !== k) el.hidden = true;
    }
  }

  const empty = (t, s) => `<div class="empty"><b>${t}</b>${s || ""}</div>`;

  function teamPicker(label) {
    const teams = S.teams[S.day];
    if (!teams.length) return empty(S.day + "のチームはまだありません", "とらがチームを作るまで待ってね");
    const cur = S.me.team_day === S.day ? S.me.team_id : null;
    return `<div class="box"><h2 class="h">${label}</h2><div class="pick">${teams.map((t) =>
      `<button data-act="pick" data-id="${esc(t.id)}" aria-pressed="${t.id === cur}">${esc(t.name)}</button>`).join("")}</div></div>`;
  }

  function prizesBox(b) {
    const p = (b.prizes || []).map((x, i) => x ? `<div>${["🥇", "🥈", "🥉"][i]} ${i + 1}位：<b>${esc(x)}</b></div>` : "").join("");
    return p ? `<div class="prizes">${p}</div>` : "";
  }

  function renderRank() {
    const b = S.board;
    if (!b) return empty("読み込み中…");
    const mine = S.me.team_day === S.day ? S.me.team_id : null;
    const master = S.me.is_master;
    let h = "";
    if (!mine && S.teams[S.day].length) h += teamPicker(S.day + "の自分のチームを選んでね");
    if (pushSupported() && !S.pushOn && Notification.permission !== "denied")
      h += `<div class="box"><h2 class="h">通知をONにしよう</h2><p class="small">ライバルのカウントやヒントが届きます。</p><button class="go" data-act="push">通知をONにする</button></div>`;
    if (!b.teams.length) return h + empty(S.day + "のチームはまだありません", "とらがチームを作るまで待ってね");

    if (b.revealed) h += `<div class="result">🎉 ${esc(S.day)} 結果発表！ 🎉</div>`;
    const hideAt = hhmm(b.hide_at);

    if (b.hidden && !master) {
      h += `<div class="secret"><b>順位は非公開！</b><span>${hideAt}から結果発表まで、ヒントだけが届きます</span></div>`;
      if (mine) {
        h += S.hints.length
          ? S.hints.slice().reverse().map((x, i) => `<div class="hint${i === 0 ? " new" : ""}"><time>${hhmm(x.at)}</time><p>${esc(x.text)}</p></div>`).join("")
          : empty("最初のヒントを待とう", "30分後に1つ目のヒントが出ます");
      }
      h += b.teams.map((t) => `<div class="t q${t.id === mine ? " mine" : ""}"><div class="r">?</div><div class="n">${esc(t.name)}${t.id === mine ? "<small>あなたのチーム</small>" : ""}</div><div class="c">???</div></div>`).join("");
      return h + prizesBox(b);
    }

    if (b.hidden && master) h += `<div class="bar"><span>みんなには<b>非公開中</b>（マスターだけ見えています）</span></div>`;
    else if (!b.revealed) h += `<p class="small">${hideAt}から順位は非公開になります</p>`;
    const top = b.teams.length ? b.teams[0].score : 0;
    h += b.teams.map((t) => {
      const first = t.rank === 1 && t.score > 0;
      const sub = t.id === mine ? "あなたのチーム" : first ? "現在トップ！" : top > t.score ? `1位まであと${top - t.score}人` : "";
      return `<div class="t${first ? " first" : ""}${t.id === mine ? " mine" : ""}"><div class="r">${t.rank}</div><div class="n">${esc(t.name)}${sub ? `<small>${sub}</small>` : ""}</div><div class="c">${t.score}<span>人</span></div></div>`;
    }).join("");
    h += prizesBox(b);
    h += `<div class="total"><span>${esc(S.day)}の合計</span><b>${b.total}人</b></div>`;
    return h;
  }

  function counterBar() {
    const me = S.me;
    return `<div class="bar"><span>カウント係：<b>${esc(me.is_counter ? "あなた" : (me.counter_name || "未設定"))}</b></span>${me.is_counter ? '<span class="tagme">押せます</span>' : ""}</div>`;
  }

  function renderCount() {
    const me = S.me;
    let h = counterBar();
    const teams = S.teams[S.day];
    const score = (id) => { const t = S.board && S.board.teams.find((x) => x.id === id); return t && t.score != null ? t.score : ""; };
    if (me.is_counter) {
      h += `<p class="small">呼んできた人から申告を受けたら、そのチームの「+1」。間違えたら下で取り消し。</p>`;
      h += teams.length ? teams.map((t) => `<button class="plus" data-act="plus" data-id="${esc(t.id)}"><span class="n">${esc(t.name)}</span><span class="c">${score(t.id)}</span><span class="p">+1</span></button>`).join("")
        : empty(S.day + "のチームはまだありません");
    } else {
      h += `<p class="small">カウント係は${esc(me.counter_name || "未設定")}です。交代は「マスター」タブから。</p>`;
    }
    const recent = S.recent.filter((c) => !c.deleted);
    if (recent.length) {
      h += `<div class="box"><h2 class="h">さっきのカウント</h2><ul class="list">${recent.map((c) =>
        `<li><time>${hhmm(c.at)}</time><span class="what">${esc(c.team_name)} +1</span><button class="btn" data-act="undo" data-id="${c.id}">取り消し</button></li>`).join("")}</ul></div>`;
    }
    return h;
  }

  function renderMe() {
    const me = S.me;
    let h = `<div class="box"><h2 class="h">${esc(me.name)}${me.is_master ? '<span class="tagme">マスター</span>' : ""}${me.is_counter ? '<span class="tagme">カウント係</span>' : ""}</h2>
      <p class="small">${esc(S.day)}のチーム：${me.team_day === S.day ? esc(me.team_name) : "未選択"}</p></div>`;
    h += teamPicker(S.day + "のチームを変える");
    if (!pushSupported()) h += `<div class="box"><h2 class="h">通知</h2><p class="small">この開き方では通知が使えません。ホーム画面のアイコンから開いてください。</p></div>`;
    else if (S.pushOn) h += `<div class="box"><h2 class="h">通知：ON</h2><p class="small">止めたいときは、設定アプリの通知からweringをOFFに。</p></div>`;
    else h += `<div class="box"><h2 class="h">通知：OFF</h2><button class="go" data-act="push">通知をONにする</button></div>`;
    if (S.showKey && !me.is_master) {
      h += `<form class="box" data-form="key" autocomplete="off"><h2 class="h">マスター合言葉</h2><input id="key-input" type="password"><button class="go" type="submit">送る</button></form>`;
    }
    return h;
  }

  function renderMaster() {
    if (!S.settings) return empty("読み込み中…");
    const day = S.day, teams = S.teams[day], st = S.settings;
    let h = counterBar();

    // チーム
    h += `<div class="box"><h2 class="h">${esc(day)}のチーム（${teams.length}）</h2><ul class="list">${teams.map((t) =>
      `<li><input id="rn-${esc(t.id)}" value="${esc(t.name)}" maxlength="20" style="flex:1;min-width:0"><button class="btn" data-act="rename" data-id="${esc(t.id)}">保存</button></li>`).join("") || '<li class="small">まだありません</li>'}</ul>
      <form data-form="team" class="row" autocomplete="off"><input id="team-new" maxlength="20" placeholder="例：とらチーム"><button class="btn blue" type="submit">追加</button></form></div>`;

    // メンバー
    const opts = (m) => {
      const inDay = m.team_day === day;
      let o = `<option value="">${inDay || !m.team_id ? "—（未所属）" : "—"}</option>`;
      if (m.team_id && !inDay) o = `<option value="" selected>${esc(m.team_day)}：${esc(m.team_name)}</option>` + `<option value="">—（未所属）</option>`;
      return o + teams.map((t) => `<option value="${esc(t.id)}"${inDay && t.id === m.team_id ? " selected" : ""}>${esc(t.name)}</option>`).join("");
    };
    h += `<div class="box"><h2 class="h">メンバー（${S.members.length}人）</h2><p class="small">チームを選ぶとすぐ移動します。「係にする」でその人の端末にカウント権限と通知が飛びます。</p><ul class="list">${S.members.map((m) =>
      `<li><span class="what">${esc(m.name)} ${m.is_counter ? '<span class="chip on">係</span>' : ""} ${m.push ? '<span class="chip">通知</span>' : ""}</span>
        <select data-act="move" data-id="${esc(m.id)}" style="width:auto;max-width:44%;padding:6px 8px;font-size:14px">${opts(m)}</select>
        ${m.is_counter ? "" : S.pending === "c:" + m.id
          ? `<button class="btn red" data-act="counter-yes" data-id="${esc(m.id)}">本当に？</button><button class="btn" data-act="cancel">やめる</button>`
          : `<button class="btn" data-act="counter" data-id="${esc(m.id)}">係にする</button>`}</li>`).join("")}</ul></div>`;

    // 時間帯別
    const live = S.hist.filter((c) => !c.deleted);
    const hours = [10, 11, 12, 13, 14, 15, 16];
    const cell = (tid, hr) => live.filter((c) => c.team_id === tid && new Date(c.at).getHours() === hr).length;
    h += `<div class="box"><h2 class="h">時間帯別カウント</h2><div class="scroll"><table><tr><th>チーム</th>${hours.map((x) => `<th>${x}時</th>`).join("")}<th>計</th></tr>${teams.map((t) =>
      `<tr><td>${esc(t.name)}</td>${hours.map((x) => `<td>${cell(t.id, x) || ""}</td>`).join("")}<td><b>${live.filter((c) => c.team_id === t.id).length}</b></td></tr>`).join("")}</table></div></div>`;

    // 履歴
    h += `<div class="box"><h2 class="h">履歴（${S.hist.length}件）</h2><ul class="list" style="max-height:340px;overflow:auto">${S.hist.map((c) =>
      `<li><time>${hhmm(c.at)}</time><span class="what${c.deleted ? " del" : ""}">${esc(c.team_name)} +1 <span class="small">（${esc(c.by_name || "?")}）</span></span>${c.deleted ? "" : `<button class="btn" data-act="undo" data-id="${c.id}">取消</button>`}</li>`).join("") || '<li class="small">まだありません</li>'}</ul></div>`;

    // 景品
    const pz = st.prizes || ["", "", ""];
    h += `<form class="box" data-form="prizes" autocomplete="off"><h2 class="h">景品</h2>${[0, 1, 2].map((i) =>
      `<label>${i + 1}位<input id="pz-${i}" maxlength="30" value="${esc(pz[i] || "")}" placeholder="${["例：ギフトカード1,000円", "例：カップ麺", "例：ジュース"][i]}"></label>`).join("")}<button class="go" type="submit">保存</button></form>`;

    // 結果発表
    const rev = (st.revealed || []).includes(day);
    h += `<div class="box"><h2 class="h">${esc(day)}の結果発表</h2>${rev
      ? `<p class="small">公開中です。</p><button class="btn" data-act="reveal-off">非公開に戻す</button>`
      : S.pending === "reveal" ? `<button class="go red" data-act="reveal-yes">本当に全員に公開する</button><button class="btn" data-act="cancel">やめる</button>`
      : `<button class="go red" data-act="reveal">結果発表する（全員に順位を公開）</button>`}</div>`;

    // リハーサル
    h += `<div class="box"><h2 class="h">リハーサル</h2><p class="small">${st.force_at ? `テスト中：${hhmm(st.force_at)}から非公開・ヒント${st.slot_minutes}分ごと` : "本番設定（12:30から非公開・ヒント30分ごと）"}</p>
      <div class="row"><select id="slot-min" style="flex:1"><option value="1">ヒント1分ごと</option><option value="5">ヒント5分ごと</option><option value="30">ヒント30分ごと</option></select><button class="btn red" data-act="test-on">今から隠す</button></div>
      <button class="btn" data-act="test-off">本番設定に戻す</button></div>`;
    return h;
  }

  // ---------- イベント ----------
  document.addEventListener("click", (e) => {
    const day = e.target.closest("[data-day]");
    if (day) { S.day = day.dataset.day; S.board = null; S.pending = null; renderAll(); refresh(); return; }
    const tab = e.target.closest("[data-tab]");
    if (tab) { S.tab = tab.dataset.tab; S.pending = null; renderAll(); scrollTo(0, 0); if (S.tab === "master" || S.tab === "count") refresh(); return; }
    const b = e.target.closest("[data-act]");
    if (!b || b.tagName === "SELECT") return;
    const id = b.dataset.id;
    switch (b.dataset.act) {
      case "plus": addCount(id); break;
      case "undo": undoCount(id); break;
      case "pick": pickTeam(id); break;
      case "push": enablePush(); break;
      case "rename": { const v = $("rn-" + id).value.trim(); if (v) masterDo("rename_team", { p_team: id, p_name: v }, "名前を変えました"); break; }
      case "counter": S.pending = "c:" + id; renderAll(); break;
      case "counter-yes": masterDo("set_counter", { p_member: id }, "カウント係を指名しました").then(() => notify({ type: "counter" })); break;
      case "cancel": S.pending = null; renderAll(); break;
      case "reveal": S.pending = "reveal"; renderAll(); break;
      case "reveal-yes": masterDo("set_reveal", { p_day: S.day, p_on: true }, "結果発表しました！"); break;
      case "reveal-off": masterDo("set_reveal", { p_day: S.day, p_on: false }, "非公開に戻しました"); break;
      case "test-on": masterDo("set_test", { p_force: true, p_slot_minutes: Number($("slot-min").value) }, "今から非公開にしました"); break;
      case "test-off": masterDo("set_test", { p_force: false, p_slot_minutes: 30 }, "本番設定に戻しました"); break;
    }
  });
  document.addEventListener("change", (e) => {
    const s = e.target.closest('select[data-act="move"]');
    if (s && s.value) masterDo("move_member", { p_member: s.dataset.id, p_team: s.value }, "移動しました");
    else if (s) masterDo("move_member", { p_member: s.dataset.id, p_team: null }, "未所属にしました");
  });
  document.addEventListener("submit", async (e) => {
    const f = e.target.closest("[data-form]"); if (!f) return;
    e.preventDefault();
    if (f.dataset.form === "team") {
      const v = $("team-new").value.trim(); if (!v) return;
      $("team-new").blur(); await masterDo("add_team", { p_day: S.day, p_name: v }, v + " を追加しました");
    } else if (f.dataset.form === "prizes") {
      document.activeElement.blur();
      await masterDo("set_prizes", { p_prizes: [0, 1, 2].map((i) => $("pz-" + i).value.trim()) }, "景品を保存しました");
    } else if (f.dataset.form === "key") {
      try {
        const ok = await api("claim_master", { ...auth(), p_key: $("key-input").value });
        if (!ok) { status("合言葉がちがいます。"); return; }
        S.showKey = false; status(""); await loadMe(); toast("マスターになりました"); S.tab = "master"; refresh();
      } catch (err) { fail(err); }
    }
  });
  // ロゴを5回タップ → マイページにマスター合言葉の欄
  $("logo").addEventListener("click", () => {
    if (++S.logoTaps >= 5 && S.me && !S.me.is_master) { S.logoTaps = 0; S.showKey = true; S.tab = "me"; renderAll(); }
  });

  // ---------- 開始 ----------
  if (!CFG.SUPABASE_URL || /xxxx/.test(CFG.SUPABASE_URL)) { status("config.js にSupabaseのURLとキーを入れてください。"); return; }
  if (!standalone && !webOK) initInstall();
  else if (!S.id || !S.secret) show("s-register");
  else start();
})();
