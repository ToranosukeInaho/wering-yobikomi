-- ============================================================
-- v2 への更新（すでに schema.sql を流したプロジェクト用）
-- SQL Editor に丸ごと貼って Run。合言葉・チーム・メンバーはそのまま残る。
-- ============================================================
alter table teams  add column if not exists deleted_at timestamptz;
alter table counts add column if not exists credited_to uuid references members(id) on delete set null;
create table if not exists counter_log (
  id         bigint generated always as identity primary key,
  member_id  uuid references members(id) on delete set null,
  set_by     uuid references members(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table counter_log enable row level security;
revoke all on counter_log from anon, authenticated;
-- 今のカウント係を履歴の1件目として入れておく
insert into counter_log(member_id, set_by)
select counter_id, counter_id from config where id = 1 and counter_id is not null
  and not exists (select 1 from counter_log);

-- ---------- 内部ヘルパー ----------
create or replace function _day_date(p_day text) returns date
language sql immutable as $$
  select case p_day when '11/3' then date '2026-11-03' when '11/4' then date '2026-11-04' end
$$;

-- その日のヒントの回数（11/3は13:00〜14:30の4回、11/4は13:00〜14:00の3回）
create or replace function _max_slots(p_day text) returns int
language sql immutable as $$
  select case p_day when '11/3' then 4 when '11/4' then 3 else 0 end
$$;

create or replace function _hide_at(p_day text) returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(c.force_at, ((_day_date(p_day) + c.hide_time) at time zone 'Asia/Tokyo'))
  from config c where c.id = 1
$$;

create or replace function _hidden(p_day text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select not (p_day = any(c.revealed)) and now() >= _hide_at(p_day)
  from config c where c.id = 1
$$;

-- p_ts 時点のチームごとの人数と順位（同点は同順位）
create or replace function _scores(p_day text, p_ts timestamptz)
returns table(team_id uuid, name text, score int, rnk int)
language sql stable security definer set search_path = public, extensions as $$
  select t.id, t.name, count(c.id)::int,
         (rank() over (order by count(c.id) desc))::int
  from teams t
  left join counts c on c.team_id = t.id and c.deleted_at is null and c.created_at < p_ts
  where t.day = p_day and t.deleted_at is null
  group by t.id, t.name
$$;

-- 削除されていないチーム（なければ null）
create or replace function _live_team(p_team uuid) returns teams
language sql stable security definer set search_path = public, extensions as $$
  select * from teams where id = p_team and deleted_at is null
$$;

create or replace function _is_counter(m members) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select m.is_master or (select counter_id from config where id = 1) = m.id
$$;

create or replace function _ceil5(x int) returns int
language sql immutable as $$ select greatest(5, (ceil(x / 5.0) * 5)::int) $$;

create or replace function _auth(p_id uuid, p_secret text) returns members
language plpgsql stable security definer set search_path = public, extensions as $$
declare m members;
begin
  select * into m from members
   where id = p_id and secret_hash = encode(digest(coalesce(p_secret, ''), 'sha256'), 'hex');
  if not found then raise exception 'not_registered'; end if;
  return m;
end $$;

create or replace function _master(p_id uuid, p_secret text) returns members
language plpgsql stable security definer set search_path = public, extensions as $$
declare m members;
begin
  m := _auth(p_id, p_secret);
  if not m.is_master then raise exception 'not_master'; end if;
  return m;
end $$;

-- ---------- ヒント ----------
-- 1回目：ぼんやり / 2回目：範囲 / 3回目：差 / 4回目：動き。
-- 各回3パターンからチームごとにランダム（同じチーム・同じ回なら毎回同じ文）。
-- 文は必ず本当のこと。1位にも「1位です」とは出ない。
create or replace function _hint(p_day text, p_team uuid, p_k int, p_s timestamptz, p_sm int)
returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  n int; my int; myrank int; opt int; kind int;
  cands int[]; r int; top int; gap int; prev_rank int;
  win_from timestamptz := p_s - make_interval(mins => p_sm);
  tot int; mine int; avg numeric;
begin
  select count(*) into n from teams where day = p_day and deleted_at is null;
  if n < 2 then return 'まだライバルがいません'; end if;
  select s.score, s.rnk into my, myrank from _scores(p_day, p_s) s where s.team_id = p_team;
  if myrank is null then return 'チームが見つかりません'; end if;

  opt  := abs(hashtext(p_team::text || ':' || p_k)) % 3;
  kind := ((p_k - 1) % 4) + 1;

  if kind = 1 then
    if opt = 0 then
      select array_agg(g) into cands from generate_series(1, least(n, 5)) g where g <> myrank;
      if cands is not null then
        r := cands[1 + abs(hashtext(p_team::text || ':r:' || p_k)) % array_length(cands, 1)];
        return format('あなたのチームは%s位ではありません', r);
      end if;
      opt := 1;
    end if;
    if opt = 1 then
      return format('あなたのチームの順位は%sです', case when myrank % 2 = 1 then '奇数' else '偶数' end);
    end if;
    select count(*) into tot from counts
     where day = p_day and deleted_at is null and created_at >= win_from and created_at < p_s
       and team_id in (select id from teams where day = p_day and deleted_at is null);
    return format('全チーム合計で、この%s分に%s人呼び込みました', p_sm, tot);

  elsif kind = 2 then
    if opt = 2 and n <= 5 then opt := 0; end if;
    if opt = 0 then
      return case when myrank <= 3 then '上位3チームに入っています' else '上位3チームには入っていません' end;
    elsif opt = 1 then
      return case when myrank <= ceil(n / 2.0) then '上半分にいます' else '下半分にいます' end;
    end if;
    return case when myrank <= 5 then 'トップ5圏内です' else 'トップ5圏外です' end;

  elsif kind = 3 then
    if opt = 1 then
      select min(s.score) - my into gap from _scores(p_day, p_s) s where s.score > my;
      if gap is not null then return format('すぐ上のチームまで、あと%s人以内です', _ceil5(gap)); end if;
    elsif opt = 2 then
      select my - max(s.score) into gap from _scores(p_day, p_s) s where s.score < my;
      if gap is not null then return format('すぐ下のチームに%s人以内まで迫られています', _ceil5(gap)); end if;
    end if;
    select max(s.score) into top from _scores(p_day, p_s) s;
    return format('1位との差は%s人以内です', _ceil5(top - my));

  else
    if opt = 1 then
      select count(*) filter (where team_id = p_team), count(*) into mine, tot from counts
       where day = p_day and deleted_at is null and created_at >= win_from and created_at < p_s
         and team_id in (select id from teams where day = p_day and deleted_at is null);
      avg := tot::numeric / n;
      return format('この%s分の呼び込み数は、全チームの平均%s', p_sm,
        case when mine > avg * 1.1 then 'より多いです'
             when mine < avg * 0.9 then 'より少ないです'
             else 'と同じくらいです' end);
    end if;
    select s.rnk into prev_rank from _scores(p_day, win_from) s where s.team_id = p_team;
    return format('この%s分で順位が%s', p_sm,
      case when myrank < prev_rank then '上がりました'
           when myrank > prev_rank then '下がりました'
           else '変わっていません' end);
  end if;
end $$;

-- ---------- 誰でも使う関数 ----------
create or replace function register(p_name text, p_secret text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare new_id uuid;
begin
  if char_length(coalesce(p_secret, '')) < 20 then raise exception 'bad_secret'; end if;
  insert into members(name, secret_hash)
  values (trim(p_name), encode(digest(p_secret, 'sha256'), 'hex'))
  returning id into new_id;
  return new_id;
end $$;

create or replace function me(p_id uuid, p_secret text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare m members; c config;
begin
  m := _auth(p_id, p_secret);
  select * into c from config where id = 1;
  return json_build_object(
    'id', m.id, 'name', m.name, 'is_master', m.is_master,
    'team_id',   (select id   from teams where id = m.team_id and deleted_at is null),
    'team_name', (select name from teams where id = m.team_id and deleted_at is null),
    'team_day',  (select day  from teams where id = m.team_id and deleted_at is null),
    'is_counter', c.counter_id = m.id,
    'counter_name', (select name from members where id = c.counter_id));
end $$;

create or replace function list_teams(p_day text) returns json
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(json_agg(json_build_object('id', id, 'name', name) order by created_at), '[]')
  from teams where day = p_day and deleted_at is null
$$;

create or replace function set_my_team(p_id uuid, p_secret text, p_team uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m members;
begin
  m := _auth(p_id, p_secret);
  if (_live_team(p_team)).id is null then raise exception 'no_team'; end if;
  update members set team_id = p_team where id = m.id;
end $$;

create or replace function get_board(p_day text, p_id uuid default null, p_secret text default null)
returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare is_m boolean := false; hid boolean; show boolean; c config; m members;
begin
  if p_id is not null then
    begin m := _auth(p_id, p_secret); is_m := m.is_master; exception when others then is_m := false; end;
  end if;
  select * into c from config where id = 1;
  hid  := _hidden(p_day);
  show := (not hid) or is_m;
  return json_build_object(
    'hidden', hid,
    'hide_at', _hide_at(p_day),
    'revealed', p_day = any(c.revealed),
    'prizes', c.prizes,
    'counter_name', (select name from members where id = c.counter_id),
    'total', case when show then (select coalesce(sum(s2.score), 0) from _scores(p_day, now() + interval '1 second') s2) end,
    'teams', coalesce((
      select json_agg(json_build_object(
               'id', s.team_id, 'name', s.name,
               'score', case when show then s.score end,
               'rank',  case when show then s.rnk end)
             order by case when show then s.rnk end nulls last, s.name)
      from _scores(p_day, now() + interval '1 second') s), '[]'));
end $$;

create or replace function get_hints(p_id uuid, p_secret text, p_day text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare m members; c config; h timestamptz; s timestamptz; maxs int; out_ json := '[]'; arr json[] := '{}';
begin
  m := _auth(p_id, p_secret);
  if (_live_team(m.team_id)).day is distinct from p_day then
    return out_;
  end if;
  select * into c from config where id = 1;
  h := _hide_at(p_day);
  maxs := case when c.force_at is not null then 4 else _max_slots(p_day) end;
  for k in 1..maxs loop
    s := h + make_interval(mins => k * c.slot_minutes);
    exit when s > now();
    arr := arr || json_build_object('slot', k, 'at', s, 'text', _hint(p_day, m.team_id, k, s, c.slot_minutes));
  end loop;
  return coalesce(array_to_json(arr), '[]');
end $$;

create or replace function save_push(p_id uuid, p_secret text, p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m members;
begin
  m := _auth(p_id, p_secret);
  insert into push_subs(endpoint, member_id, p256dh, auth) values (p_endpoint, m.id, p_p256dh, p_auth)
  on conflict (endpoint) do update set member_id = excluded.member_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function claim_master(p_id uuid, p_secret text, p_key text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare m members;
begin
  m := _auth(p_id, p_secret);
  if (select master_key_hash from config where id = 1) is distinct from encode(digest(coalesce(p_key, ''), 'sha256'), 'hex') then
    return false;
  end if;
  update members set is_master = true where id = m.id;
  update config set counter_id = m.id where id = 1 and counter_id is null;  -- 最初のカウント係はマスター
  if found then insert into counter_log(member_id, set_by) values (m.id, m.id); end if;
  return true;
end $$;

-- ---------- カウント係 ----------
-- 呼んできた人(p_member)に +1。チームはその人の今のチームで記録。カウント係とマスターだけ押せる
drop function if exists add_count(uuid, text, uuid);
create or replace function add_count(p_id uuid, p_secret text, p_member uuid) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare m members; t teams; new_id bigint;
begin
  m := _auth(p_id, p_secret);
  if not _is_counter(m) then raise exception 'not_counter'; end if;
  t := _live_team((select team_id from members where id = p_member));
  if t.id is null then raise exception 'no_team'; end if;
  insert into counts(team_id, day, counted_by, credited_to) values (t.id, t.day, m.id, p_member) returning id into new_id;
  return new_id;
end $$;

-- その人のその日の最新の1件を取り消す（-1）
create or replace function minus_count(p_id uuid, p_secret text, p_member uuid, p_day text) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare m members; cid bigint;
begin
  m := _auth(p_id, p_secret);
  if not _is_counter(m) then raise exception 'not_counter'; end if;
  select id into cid from counts
   where credited_to = p_member and day = p_day and deleted_at is null
   order by created_at desc limit 1;
  if cid is null then raise exception 'nothing_to_minus'; end if;
  update counts set deleted_at = now() where id = cid;
  return cid;
end $$;

-- カウント画面用：その日にチームがある人の一覧と、その日の人数
create or replace function members_for_count(p_id uuid, p_secret text, p_day text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare m members;
begin
  m := _auth(p_id, p_secret);
  if not _is_counter(m) then raise exception 'not_counter'; end if;
  return coalesce((
    select json_agg(json_build_object('id', mb.id, 'name', mb.name, 'team_id', t.id, 'team_name', t.name,
      'n', (select count(*) from counts c where c.credited_to = mb.id and c.day = p_day and c.deleted_at is null))
      order by t.created_at, mb.name)
    from members mb join teams t on t.id = mb.team_id and t.deleted_at is null and t.day = p_day), '[]');
end $$;

create or replace function undo_count(p_id uuid, p_secret text, p_count bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m members;
begin
  m := _auth(p_id, p_secret);
  if not _is_counter(m) then raise exception 'not_counter'; end if;
  update counts set deleted_at = now() where id = p_count and deleted_at is null;
end $$;

-- 履歴（カウント係は直近、マスターは全部）
create or replace function history(p_id uuid, p_secret text, p_day text, p_limit int default 10) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare m members; lim int;
begin
  m := _auth(p_id, p_secret);
  if not _is_counter(m) then raise exception 'not_counter'; end if;
  lim := case when m.is_master then least(greatest(p_limit, 1), 5000) else least(greatest(p_limit, 1), 20) end;
  return coalesce((
    select json_agg(x order by x.at desc) from (
      select c.id, c.team_id, t.name as team_name, c.created_at as at,
             c.deleted_at is not null as deleted, mb.name as by_name, cr.name as to_name,
             c.credited_to as to_id
      from counts c join teams t on t.id = c.team_id and t.deleted_at is null
      left join members mb on mb.id = c.counted_by
      left join members cr on cr.id = c.credited_to
      where c.day = p_day and (m.is_master or c.deleted_at is null)
      order by c.created_at desc limit lim) x), '[]');
end $$;

-- ---------- マスター（とら）専用 ----------
create or replace function add_team(p_id uuid, p_secret text, p_day text, p_name text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare new_id uuid;
begin
  perform _master(p_id, p_secret);
  insert into teams(day, name) values (p_day, trim(p_name)) returning id into new_id;
  return new_id;
end $$;

create or replace function rename_team(p_id uuid, p_secret text, p_team uuid, p_name text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  update teams set name = trim(p_name) where id = p_team;
end $$;

create or replace function list_members(p_id uuid, p_secret text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare cid uuid;
begin
  perform _master(p_id, p_secret);
  select counter_id into cid from config where id = 1;
  return coalesce((
    select json_agg(json_build_object(
      'id', mb.id, 'name', mb.name, 'team_id', t.id, 'team_name', t.name, 'team_day', t.day,
      'is_master', mb.is_master, 'is_counter', mb.id = cid,
      'push', exists(select 1 from push_subs p where p.member_id = mb.id))
      order by mb.created_at)
    from members mb left join teams t on t.id = mb.team_id and t.deleted_at is null), '[]');
end $$;

create or replace function move_member(p_id uuid, p_secret text, p_member uuid, p_team uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  if p_team is not null and (_live_team(p_team)).id is null then raise exception 'no_team'; end if;
  update members set team_id = p_team where id = p_member;
end $$;

create or replace function set_counter(p_id uuid, p_secret text, p_member uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  if not exists(select 1 from members where id = p_member) then raise exception 'no_member'; end if;
  update config set counter_id = p_member where id = 1;
  insert into counter_log(member_id, set_by) values (p_member, p_id);
end $$;

create or replace function list_counter_log(p_id uuid, p_secret text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  return coalesce((select json_agg(json_build_object('at', l.created_at, 'name', a.name, 'by_name', b.name) order by l.created_at desc)
    from counter_log l left join members a on a.id = l.member_id left join members b on b.id = l.set_by), '[]');
end $$;

-- チームの削除（ゴミ箱へ）と復元
create or replace function delete_team(p_id uuid, p_secret text, p_team uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  update teams set deleted_at = now() where id = p_team and deleted_at is null;
end $$;

create or replace function restore_team(p_id uuid, p_secret text, p_team uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  update teams set deleted_at = null where id = p_team;
end $$;

create or replace function list_deleted_teams(p_id uuid, p_secret text, p_day text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  return coalesce((select json_agg(json_build_object('id', t.id, 'name', t.name, 'deleted_at', t.deleted_at,
      'members', (select count(*) from members mb where mb.team_id = t.id),
      'counts', (select count(*) from counts c where c.team_id = t.id and c.deleted_at is null))
      order by t.deleted_at desc)
    from teams t where t.day = p_day and t.deleted_at is not null), '[]');
end $$;

create or replace function get_settings(p_id uuid, p_secret text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare c config;
begin
  perform _master(p_id, p_secret);
  select * into c from config where id = 1;
  return json_build_object('prizes', c.prizes, 'revealed', c.revealed, 'force_at', c.force_at,
                           'slot_minutes', c.slot_minutes, 'hide_time', c.hide_time);
end $$;

create or replace function set_prizes(p_id uuid, p_secret text, p_prizes text[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  update config set prizes = p_prizes[1:3] where id = 1;
end $$;

create or replace function set_reveal(p_id uuid, p_secret text, p_day text, p_on boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  update config set revealed = case when p_on then array(select distinct unnest(revealed || array[p_day]))
                                    else array_remove(revealed, p_day) end
  where id = 1;
end $$;

-- リハーサル：p_force=true で「今から隠す」、ヒント間隔を p_slot_minutes 分に
create or replace function set_test(p_id uuid, p_secret text, p_force boolean, p_slot_minutes int) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  update config set force_at = case when p_force then now() end,
                    slot_minutes = least(greatest(coalesce(p_slot_minutes, 30), 1), 60),
                    revealed = case when p_force then '{}' else revealed end
  where id = 1;
end $$;

-- ---------- 通知用（Edge Function から service_role で呼ぶ） ----------
create or replace function _claim_count_notify(p_id uuid, p_secret text, p_count bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare m members; c counts; tname text;
begin
  m := _auth(p_id, p_secret);
  update counts set notified = true
   where id = p_count and counted_by = m.id and not notified and deleted_at is null
     and created_at > now() - interval '5 minutes'
  returning * into c;
  if c.id is null then return null; end if;
  select name into tname from teams where id = c.team_id;
  return json_build_object('day', c.day, 'team_id', c.team_id, 'team_name', tname, 'hidden', _hidden(c.day));
end $$;

-- p_mode: 'others' その日の他チーム全員 / 'team' そのチームだけ / 'day' その日の全員 / 'member' 1人
create or replace function _push_targets(p_day text, p_team uuid, p_mode text, p_member uuid default null)
returns table(endpoint text, p256dh text, auth text)
language sql stable security definer set search_path = public, extensions as $$
  select p.endpoint, p.p256dh, p.auth
  from push_subs p
  join members mb on mb.id = p.member_id
  left join teams t on t.id = mb.team_id and t.deleted_at is null
  where case p_mode
          when 'others' then t.day = p_day and mb.team_id is distinct from p_team
          when 'team'   then mb.team_id = p_team
          when 'day'    then t.day = p_day
          when 'member' then mb.id = p_member
          else false end
$$;

create or replace function _counter_target(p_id uuid, p_secret text) returns uuid
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  return (select counter_id from config where id = 1);
end $$;

-- 出たばかりで、まだ通知していないヒント回（cron から呼ぶ）
create or replace function _due_hint_slots() returns table(day text, slot int)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare d text; c config; s timestamptz; maxs int;
begin
  select * into c from config where id = 1;
  foreach d in array array['11/3', '11/4'] loop
    if d = any(c.revealed) then continue; end if;
    maxs := case when c.force_at is not null then 4 else _max_slots(d) end;
    for k in 1..maxs loop
      s := _hide_at(d) + make_interval(mins => k * c.slot_minutes);
      if s <= now() and s > now() - interval '15 minutes' then
        begin
          insert into hint_sent(day, slot) values (d, k);
          day := d; slot := k; return next;
        exception when unique_violation then null;
        end;
      end if;
    end loop;
  end loop;
end $$;

-- ---------- 権限：外から呼べる関数だけ anon に開ける ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  register(text, text), me(uuid, text), list_teams(text), set_my_team(uuid, text, uuid),
  get_board(text, uuid, text), get_hints(uuid, text, text), save_push(uuid, text, text, text, text),
  claim_master(uuid, text, text),
  add_count(uuid, text, uuid), minus_count(uuid, text, uuid, text), members_for_count(uuid, text, text),
  undo_count(uuid, text, bigint), history(uuid, text, text, int),
  list_counter_log(uuid, text), delete_team(uuid, text, uuid), restore_team(uuid, text, uuid),
  list_deleted_teams(uuid, text, text),
  add_team(uuid, text, text, text), rename_team(uuid, text, uuid, text), list_members(uuid, text),
  move_member(uuid, text, uuid, uuid), set_counter(uuid, text, uuid), get_settings(uuid, text),
  set_prizes(uuid, text, text[]), set_reveal(uuid, text, text, boolean), set_test(uuid, text, boolean, int)
to anon, authenticated;

-- Edge Function（service_role）は全部使える
grant execute on all functions in schema public to service_role;
grant all on all tables in schema public to service_role;

