-- ============================================================
-- v4 への更新（migration_v3.sql のあとに、これを丸ごと貼って Run）
-- チーム・メンバー・カウント・合言葉はそのまま残る。
-- ============================================================
-- ---------- v4：隠す時刻の設定・手動スイッチ・ヒント通知 ----------
alter table config add column if not exists hide_times  jsonb  not null default '{"11/3":"12:30","11/4":"12:30"}';
alter table config add column if not exists manual_hide jsonb  not null default '{}';   -- {"11/3": "2026-11-03T13:05:00+09"} 手動で隠した時刻
alter table config add column if not exists shown       text[] not null default '{}';   -- 手動で公開中の日
alter table config add column if not exists cron_secret text   not null default encode(extensions.gen_random_bytes(16), 'hex');

-- 同じ回でも「隠し直し」たら別のヒントとして通知できるように、隠した時刻もキーに入れる
drop table if exists hint_sent;
create table hint_sent (
  day     text not null,
  slot    int  not null,
  hide_at timestamptz not null,
  sent_at timestamptz not null default now(),
  primary key (day, slot, hide_at)
);
alter table hint_sent enable row level security;
revoke all on hint_sent from anon, authenticated;
grant all on hint_sent to service_role;

-- 隠し始める時刻：リハーサル(force_at) → 手動で隠した時刻 → その日の設定時刻
create or replace function _hide_at(p_day text) returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    c.force_at,
    (c.manual_hide ->> p_day)::timestamptz,
    ((_day_date(p_day) + coalesce((c.hide_times ->> p_day)::time, c.hide_time)) at time zone 'Asia/Tokyo'))
  from config c where c.id = 1
$$;

create or replace function _hidden(p_day text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select not (p_day = any(c.revealed) or p_day = any(c.shown)) and now() >= _hide_at(p_day)
  from config c where c.id = 1
$$;

create or replace function get_settings(p_id uuid, p_secret text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare c config;
begin
  perform _master(p_id, p_secret);
  select * into c from config where id = 1;
  return json_build_object('prizes', c.prizes, 'revealed', c.revealed, 'force_at', c.force_at,
    'slot_minutes', c.slot_minutes, 'hide_times', c.hide_times, 'manual_hide', c.manual_hide, 'shown', c.shown,
    'hide_at', json_build_object('11/3', _hide_at('11/3'), '11/4', _hide_at('11/4')),
    'hidden',  json_build_object('11/3', _hidden('11/3'),  '11/4', _hidden('11/4')));
end $$;

-- その日の隠し始める時刻（HH:MM）を変える
create or replace function set_hide_time(p_id uuid, p_secret text, p_day text, p_time text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  perform p_time::time;  -- 形式チェック
  update config set hide_times = hide_times || jsonb_build_object(p_day, p_time) where id = 1;
end $$;

-- 手動スイッチ：p_mode = 'hide'（今すぐ隠す）/ 'show'（今すぐ公開）/ 'auto'（時刻設定に戻す）
create or replace function set_visibility(p_id uuid, p_secret text, p_day text, p_mode text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  if p_mode = 'hide' then
    update config set manual_hide = manual_hide || jsonb_build_object(p_day, now()),
                      shown = array_remove(shown, p_day), revealed = array_remove(revealed, p_day), force_at = null
    where id = 1;
  elsif p_mode = 'show' then
    update config set shown = array(select distinct unnest(shown || array[p_day])), force_at = null where id = 1;
  elsif p_mode = 'auto' then
    update config set manual_hide = manual_hide - p_day, shown = array_remove(shown, p_day), force_at = null where id = 1;
  else
    raise exception 'bad_mode';
  end if;
end $$;

-- 出たばかりで、まだ通知していないヒント回
create or replace function _due_hint_slots() returns table(day text, slot int)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare d text; c config; s timestamptz; h timestamptz; maxs int;
begin
  select * into c from config where id = 1;
  foreach d in array array['11/3', '11/4'] loop
    if not _hidden(d) then continue; end if;
    h := _hide_at(d);
    maxs := case when c.force_at is not null then 4 else _max_slots(d) end;
    for k in 1..maxs loop
      s := h + make_interval(mins => k * c.slot_minutes);
      if s <= now() and s > now() - interval '15 minutes' then
        begin
          insert into hint_sent(day, slot, hide_at) values (d, k, h);
          day := d; slot := k; return next;
        exception when unique_violation then null;
        end;
      end if;
    end loop;
  end loop;
end $$;

-- cron 用：通知すべきヒントがあるか（書き込みなし）
create or replace function _has_due_hints() returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
declare d text; c config; s timestamptz; h timestamptz; maxs int;
begin
  select * into c from config where id = 1;
  foreach d in array array['11/3', '11/4'] loop
    if not _hidden(d) then continue; end if;
    h := _hide_at(d);
    maxs := case when c.force_at is not null then 4 else _max_slots(d) end;
    for k in 1..maxs loop
      s := h + make_interval(mins => k * c.slot_minutes);
      if s <= now() and s > now() - interval '15 minutes'
         and not exists (select 1 from hint_sent x where x.day = d and x.slot = k and x.hide_at = h) then
        return true;
      end if;
    end loop;
  end loop;
  return false;
end $$;

revoke execute on function set_hide_time(uuid, text, text, text), set_visibility(uuid, text, text, text),
  _has_due_hints(), _due_hint_slots() from public, anon, authenticated;
grant execute on function set_hide_time(uuid, text, text, text), set_visibility(uuid, text, text, text) to anon, authenticated;
grant execute on all functions in schema public to service_role;
