# wering 呼び込みランキング戦

IVY Festa 2026（11/3・11/4）のチーズハットグ屋台で使う、呼び込み数のチーム対抗ランキングアプリ。

- 画面：GitHub Pages（ビルドなし。`index.html` / `app.js` / `sw.js`）
- データ：Supabase（新規プロジェクト。終わったら消してOK）
- 通知：Web Push（Supabase Edge Function `notify`）
- 参加者はログインなし。リンクを開いて「ホーム画面に追加」したアイコンから使う（PWA）

---

## セットアップ（30分くらい）

### 1. Supabase プロジェクトを作る
1. https://supabase.com で **New project**（リージョンは Tokyo）
2. **SQL Editor** に `supabase/schema.sql` を全部貼る
3. 一番下の `ここを自分だけの合言葉に変える` を自分の合言葉に書き換えて **Run**
   - 注意：このファイルはもう一度Runしても壊れないが、そのたびに合言葉はこの行の値に上書きされる
4. **Project Settings → API Keys** で次の2つを控える
   - Project URL（`https://xxxx.supabase.co`）
   - anon キー（または publishable キー）。**service_role キーは絶対にアプリに入れない**

### 2. 通知用の鍵（VAPID）を作る
```bash
npx web-push generate-vapid-keys
```
Public Key と Private Key が出るので控える。

### 3. Edge Function をデプロイ
```bash
npm i -g supabase            # まだなら
supabase login
supabase link --project-ref <xxxx>   # URLの xxxx 部分
supabase secrets set \
  VAPID_PUBLIC_KEY=<公開鍵> \
  VAPID_PRIVATE_KEY=<秘密鍵> \
  VAPID_SUBJECT=mailto:<自分のメール> \
  CRON_SECRET=<適当な長い文字列>
supabase functions deploy notify --no-verify-jwt
```
`--no-verify-jwt` は必須。関数の中で本人チェックをしているので問題ない。

### 4. config.js を書き換えて GitHub に公開
`config.js` の3つを書き換える。anonキーは公開されても大丈夫。テーブルには直接触れず、決めた関数しか呼べない作りになっている。

```bash
git init && git add . && git commit -m "first"
git branch -M main
git remote add origin git@github.com:<you>/wering-yobikomi.git
git push -u origin main
```
GitHub の **Settings → Pages → Deploy from a branch → main / (root)**。
`https://<you>.github.io/wering-yobikomi/` が配るリンクになる。

### 5. マスター（自分）になる
1. iPhoneのSafariでリンクを開き、共有 → **ホーム画面に追加**
2. ホームのアイコンから開いて名前を登録
3. 上のロゴを **5回タップ** → マイページに出る欄に合言葉を入れる → 「マスター」タブが出る
4. 最初のカウント係は自動で自分になる

PCで確認したいときは、URLの末尾に `?web=1` を付けると、ホーム画面に追加しなくても開ける（通知は来ない）。

### 6.（任意）ヒントが出たときの通知
Supabase の **Database → Extensions** で `pg_cron` と `pg_net` をON。SQL Editor で次を実行する。

```sql
select cron.schedule('wering-hints', '*/2 3-6 3,4 11 *', $$
  select net.http_post(
    url     := 'https://<xxxx>.supabase.co/functions/v1/notify',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body    := '{"type":"hint","cron_secret":"<CRON_SECRET と同じ文字列>"}'::jsonb)
$$);
```
11/3・11/4 の 12:00〜15:59（日本時間）に2分おきに確認し、新しいヒントが出た回だけ通知を送る。
リハーサルで試すときは `'* * * * *'` で別名を登録し、終わったら `select cron.unschedule('名前');` で止める。

---

## 当日までの流れ
1. アンケートが出たら、マスタータブで日にちを選んでチームを追加（「〇〇チーム」）
2. LINEでリンクを流す →「Safari（AndroidはChrome）で開いて、ホーム画面に追加してね」
3. みんなが登録すると、マスタータブの「メンバー」に名前が並ぶ。チーム移動もここからできる
4. カウント係は「メンバー」の「係にする」で指名する。相手に通知が飛び、前の係の権限は自動で外れる
5. 景品は1〜3位をマスタータブで入れる

## ルール（アプリの動き）
| 時刻 | 動き |
|---|---|
| 〜12:30 | 全員にランキングを公開。他チームに＋1が入ると通知 |
| 12:30〜 | 順位と人数を非公開（サーバー側で隠すので、画面を調べても分からない）。通知は自分のチームの＋1だけ |
| 13:00 / 13:30 / 14:00 / 14:30 | 自分のチームにだけヒント（11/3は4回、11/4は3回） |
| 終了後 | マスタータブの「結果発表する」で全員に公開 |

ヒントは4段階で、各回3パターンからチームごとにランダムに選ぶ（文はすべて本当のこと）。
1. ぼんやり：「○位ではありません」「順位は奇数です」「全チーム合計でこの30分に○人」
2. 範囲：「上位3チームに入っています」「上半分にいます」「トップ5圏内です」
3. 差：「1位との差は○人以内」「すぐ上まであと○人以内」「すぐ下に○人以内まで迫られています」（5人単位で切り上げ）
4. 動き：「この30分で順位が上がりました」「この30分の呼び込み数は平均より多いです」

文言を変えたいときは `schema.sql` の `_hint` 関数を編集して、その関数だけ SQL Editor で再実行する。

## リハーサル
マスタータブ →「リハーサル」で **ヒント1分ごと → 今から隠す** を押すと、1分ごとにヒントが出る。終わったら **本番設定に戻す**。

本番前のリセット（チームとメンバーは残し、カウントだけ消す）：
```sql
truncate counts, hint_sent;
update config set force_at = null, slot_minutes = 30, revealed = '{}' where id = 1;
```
全部消す場合：`truncate counts, hint_sent, push_subs, members, teams cascade;`（このあと合言葉の行をもう一度実行）

## 注意
- iPhoneは **iOS 16.4以上** で、ホーム画面のアイコンから開いたときだけ通知が届く
- LINEの中のブラウザではホーム画面に追加できない。「ブラウザで開く」を押してもらう
- ＋1の通知は1件ずつ上書きされる（Androidは鳴らずに更新、iPhoneは機種によって鳴ることがある）
- Supabaseの無料プランでは、1週間アクセスがないとプロジェクトが一時停止する。当日の前日に一度開いておく
- 学園祭が終わったら Supabase のプロジェクトを削除すれば全データが消える

## ファイル
```
index.html            画面（見た目のCSSもここ）
app.js                画面の動き・Supabaseとのやりとり
sw.js                 通知を受け取るサービスワーカー
manifest.webmanifest  ホーム画面用の設定
config.js             SupabaseのURL・キー・VAPID公開鍵
icons/                アイコン
supabase/schema.sql   テーブルと関数（全部ここ）
supabase/functions/notify/index.ts  プッシュ通知を送る関数
```
