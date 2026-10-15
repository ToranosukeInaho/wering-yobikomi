# CLAUDE.md — wering 呼び込みランキング戦

学園祭（IVY Festa 2026、11/3・11/4）の2日間だけ使うPWA。使い捨てなので、シンプルさ優先。過剰な抽象化やビルドツールは入れない。

## 構成
- フロント：素のHTML/CSS/JS（`index.html`, `app.js`, `sw.js`）。GitHub Pagesでそのまま配信。npm/ビルドなし
- バックエンド：Supabase。**全ロジックは `supabase/schema.sql` のPL/pgSQL関数**。フロントは PostgREST の `/rest/v1/rpc/<関数名>` を `fetch` で叩くだけ（supabase-js は使っていない）
- 通知：`supabase/functions/notify/index.ts`（Deno, web-push）。`--no-verify-jwt` でデプロイ

## セキュリティの考え方
- テーブルはRLSオン・ポリシーなし・anonから権限剥奪。anonが呼べるのは schema.sql 最後の `grant execute` に並べた関数だけ
- 本人確認：端末ごとに `id` と `secret`（ランダム48桁）を localStorage に持つ。DBには secret の sha256 だけ保存。全RPCで `_auth(p_id, p_secret)` を通す
- マスター：`config.master_key_hash` と一致する合言葉で `claim_master`。マスター専用関数は `_master()` を通す
- カウント係：`config.counter_id` の1人だけが `add_count` できる（二重カウント防止）
- 12:30以降の非公開はサーバー側（`get_board` が score/rank を null で返す）。フロントで隠しているわけではない
- カウントはチームに付く（v3）。係が「〇〇チーム〇人」を `add_team_count(team, n)` で入れる（n行insert）。-1 は `minus_team_count` でそのチームの最新1件を論理削除。直前の+nは `undo_counts(ids)` で丸ごと戻す。`add_count`/`minus_count`/`credited_to` はv2の名残で未使用
- ルール：メンバー本人が係に申告。お客さんに伝言させない。お客さんへの確認はしない（信用ゲーム）
- カウント係（`config.counter_id`）とマスターだけが押せる（`_is_counter`）。指名の履歴は `counter_log`
- チーム削除は論理削除（`teams.deleted_at`）。`restore_team` で戻せる。削除中のチームは全集計から除外
- 既存DBの更新は `supabase/migration_v2.sql` のように、alter ＋ 関数の再定義だけのファイルを作って流す（schema.sql を丸ごと流すと合言葉が上書きされる）。v2→v3 は `migration_v3.sql`、v3→v4 は `migration_v4.sql`
- `_` で始まる関数は内部用。anonにgrantしない。Edge Function（service_role）からは呼べる

## 時刻
- 判定は全部DB側の `now()`。非公開開始は `_hide_at(day)` = `force_at`（旧リハーサル）→ `manual_hide[day]`（マスターの「今すぐ隠す」）→ `hide_times[day]`（日ごとの時刻、初期12:30）の順
- `shown`（今すぐ公開）と `revealed`（結果発表）に入っている日は非公開にならない。`set_visibility(day, hide|show|auto)` で切り替え
- 通知はヒントだけ（v4）。pg_cron が毎分 `_has_due_hints()` を見て、あるときだけ Edge Function `notify`（type=hint）を呼ぶ。合言葉は `config.cron_secret`。設定は `supabase/cron_hints.sql`
- ヒント回数は `_max_slots`（11/3=4, 11/4=3）、間隔は `config.slot_minutes`
- ヒント本文は `_hint(day, team, k, slot_time, slot_minutes)`。同じチーム・同じ回は `hashtext` で毎回同じパターンになる。**文は必ず真実にすること**、1位チームに1位と分かる文を出さないこと

## 変更するとき
- 関数を変えたら `create or replace function ...` の部分だけ SQL Editor で再実行すれば反映される。新しくanonから呼ぶ関数を作ったら `grant execute ... to anon, authenticated` も忘れずに
- 画面の文言は日本語・短く・説明しすぎない（ユーザーの好み）。見た目は黄(#ffd23f)×青(#1d3fbf)×赤(#e8412c)、黒の太枠＋ずらし影、角丸なし
- 個人のランキングは出さない（チーム単位のみ）
- `config.js` に service_role キーを入れない

## ローカル確認
- PCで `?web=1` を付けて開くとPWAインストールなしで動く
- DBの関数は psql で `set role anon;` してから直接呼んで確認できる
