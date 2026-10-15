-- ============================================================
-- ヒント通知の自動実行（1回だけ実行すればOK）
-- 1分ごとに「出たばかりのヒント」があるか確認し、あるときだけ通知を送る。
-- 学園祭が終わったら一番下の unschedule を実行して止める。
-- ============================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule('wering-hints', '* * * * *', $$
  select net.http_post(
    url     := 'https://ckximdfxtzmxvdiaalnc.supabase.co/functions/v1/notify',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body    := jsonb_build_object('type', 'hint', 'cron_secret', (select cron_secret from public.config where id = 1)))
  where public._has_due_hints()
$$);

-- 止めるとき：
-- select cron.unschedule('wering-hints');
