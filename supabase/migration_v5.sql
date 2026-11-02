-- ============================================================
-- v4 → v5：チームを先に登録しておく（名前を選ぶだけで参加）
--   ・チームは日ごと（11/3と11/4で別のチームに入れる）
--   ・メンバーは最初の画面で「自分の名前」を選ぶだけ（端末と結びつく）
--   ・マスターはチームの移動、当日のメンバー追加、端末の付け外しができる
--   ・テスト中のカウントとリハーサル設定はリセット
-- SQL Editor にこのファイルを丸ごと貼って Run（合言葉は変わりません）
-- ============================================================

-- ---------- テーブル ----------
create table if not exists member_teams (
  member_id uuid not null references members(id) on delete cascade,
  day       text not null check (day in ('11/3', '11/4')),
  team_id   uuid not null references teams(id) on delete cascade,
  primary key (member_id, day)
);
alter table member_teams enable row level security;
revoke all on member_teams from anon, authenticated;
grant all on member_teams to service_role;

alter table members alter column secret_hash drop not null;   -- 名前だけ先に登録（端末なし）
alter table members add column if not exists hidden boolean not null default false;  -- 一覧から消す

-- 今までの1人1チームを日ごとの表に移す
insert into member_teams(member_id, day, team_id)
select m.id, t.day, t.id from members m join teams t on t.id = m.team_id
on conflict (member_id, day) do nothing;

-- ---------- ヘルパー ----------
-- その人のその日のチーム（削除されたチームなら null）
create or replace function _team_of(p_member uuid, p_day text) returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select mt.team_id from member_teams mt join teams t on t.id = mt.team_id and t.deleted_at is null
  where mt.member_id = p_member and mt.day = p_day
$$;

create or replace function _teams_json(p_member uuid) returns json
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(json_object_agg(mt.day, json_build_object('id', t.id, 'name', t.name)), '{}'::json)
  from member_teams mt join teams t on t.id = mt.team_id and t.deleted_at is null
  where mt.member_id = p_member
$$;

-- ---------- 誰でも使う関数 ----------
-- 最初の画面：名前の一覧（端末と結びついているかどうか付き）
create or replace function list_roster() returns json
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(json_agg(json_build_object('id', m.id, 'name', m.name,
           'claimed', m.secret_hash is not null, 'teams', _teams_json(m.id)) order by m.created_at, m.name), '[]')
  from members m where not m.hidden and not m.is_master
$$;

-- 名前を選んで、この端末を自分にする
create or replace function claim_member(p_member uuid, p_secret text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
begin
  if char_length(coalesce(p_secret, '')) < 20 then raise exception 'bad_secret'; end if;
  update members set secret_hash = encode(digest(p_secret, 'sha256'), 'hex')
   where id = p_member and secret_hash is null and not hidden and not is_master;
  if not found then raise exception 'taken'; end if;
  return p_member;
end $$;

create or replace function me(p_id uuid, p_secret text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare m members; c config;
begin
  m := _auth(p_id, p_secret);
  select * into c from config where id = 1;
  return json_build_object(
    'id', m.id, 'name', m.name, 'is_master', m.is_master,
    'teams', _teams_json(m.id),
    'is_counter', c.counter_id = m.id,
    'counter_name', (select name from members where id = c.counter_id));
end $$;

-- リストにない人（当日飛び入り）が自分で選ぶとき用。その日にチームがない人だけ
create or replace function set_my_team(p_id uuid, p_secret text, p_team uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m members; t teams;
begin
  m := _auth(p_id, p_secret);
  t := _live_team(p_team);
  if t.id is null then raise exception 'no_team'; end if;
  if _team_of(m.id, t.day) is not null and not m.is_master then raise exception 'ask_master'; end if;
  insert into member_teams(member_id, day, team_id) values (m.id, t.day, t.id)
  on conflict (member_id, day) do update set team_id = excluded.team_id;
end $$;

create or replace function get_hints(p_id uuid, p_secret text, p_day text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare m members; c config; h timestamptz; s timestamptz; maxs int; tid uuid; arr json[] := '{}';
begin
  m := _auth(p_id, p_secret);
  tid := _team_of(m.id, p_day);
  if tid is null then return '[]'; end if;
  select * into c from config where id = 1;
  h := _hide_at(p_day);
  maxs := case when c.force_at is not null then 4 else _max_slots(p_day) end;
  for k in 1..maxs loop
    s := h + make_interval(mins => k * c.slot_minutes);
    exit when s > now();
    arr := arr || json_build_object('slot', k, 'at', s, 'text', _hint(p_day, tid, k, s, c.slot_minutes));
  end loop;
  return coalesce(array_to_json(arr), '[]');
end $$;

-- ---------- マスター ----------
create or replace function list_members(p_id uuid, p_secret text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare cid uuid;
begin
  perform _master(p_id, p_secret);
  select counter_id into cid from config where id = 1;
  return coalesce((
    select json_agg(json_build_object(
      'id', mb.id, 'name', mb.name, 'teams', _teams_json(mb.id),
      'claimed', mb.secret_hash is not null,
      'is_master', mb.is_master, 'is_counter', mb.id = cid,
      'push', exists(select 1 from push_subs p where p.member_id = mb.id))
      order by mb.created_at, mb.name)
    from members mb where not mb.hidden), '[]');
end $$;

-- その日のチームを変える（p_team = null で、その日は未所属）
create or replace function move_member_day(p_id uuid, p_secret text, p_member uuid, p_day text, p_team uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  if p_team is null then
    delete from member_teams where member_id = p_member and day = p_day;
    return;
  end if;
  if (_live_team(p_team)).day is distinct from p_day then raise exception 'no_team'; end if;
  insert into member_teams(member_id, day, team_id) values (p_member, p_day, p_team)
  on conflict (member_id, day) do update set team_id = excluded.team_id;
end $$;

-- 旧：チームの日で入れる
create or replace function move_member(p_id uuid, p_secret text, p_member uuid, p_team uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare t teams;
begin
  perform _master(p_id, p_secret);
  t := _live_team(p_team);
  if t.id is null then raise exception 'no_team'; end if;
  insert into member_teams(member_id, day, team_id) values (p_member, t.day, t.id)
  on conflict (member_id, day) do update set team_id = excluded.team_id;
end $$;

-- 当日のメンバー追加（端末はあとから本人が名前を選んで結びつける）
create or replace function add_member(p_id uuid, p_secret text, p_name text, p_team3 uuid, p_team4 uuid) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare new_id uuid;
begin
  perform _master(p_id, p_secret);
  if char_length(trim(coalesce(p_name, ''))) = 0 then raise exception 'bad_name'; end if;
  insert into members(name, secret_hash) values (trim(p_name), null) returning id into new_id;
  if p_team3 is not null and (_live_team(p_team3)).day = '11/3' then
    insert into member_teams values (new_id, '11/3', p_team3);
  end if;
  if p_team4 is not null and (_live_team(p_team4)).day = '11/4' then
    insert into member_teams values (new_id, '11/4', p_team4);
  end if;
  return new_id;
end $$;

-- 違う人が名前を選んでしまったとき：端末との結びつきを外す（本人が選び直せる）
create or replace function release_member(p_id uuid, p_secret text, p_member uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  update members set secret_hash = null where id = p_member and not is_master;
  delete from push_subs where member_id = p_member;
end $$;

-- 一覧から消す（間違って追加した人など）
create or replace function hide_member(p_id uuid, p_secret text, p_member uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  update members set hidden = true, secret_hash = null where id = p_member and not is_master;
  delete from member_teams where member_id = p_member;
  delete from push_subs where member_id = p_member;
end $$;

create or replace function list_deleted_teams(p_id uuid, p_secret text, p_day text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _master(p_id, p_secret);
  return coalesce((select json_agg(json_build_object('id', t.id, 'name', t.name, 'deleted_at', t.deleted_at,
      'members', (select count(*) from member_teams mt where mt.team_id = t.id),
      'counts', (select count(*) from counts c where c.team_id = t.id and c.deleted_at is null))
      order by t.deleted_at desc)
    from teams t where t.day = p_day and t.deleted_at is not null), '[]');
end $$;

-- ---------- 通知の宛先（日ごとのチームで） ----------
create or replace function _push_targets(p_day text, p_team uuid, p_mode text, p_member uuid default null)
returns table(endpoint text, p256dh text, auth text)
language sql stable security definer set search_path = public, extensions as $$
  select p.endpoint, p.p256dh, p.auth
  from push_subs p
  join members mb on mb.id = p.member_id and not mb.hidden
  where case p_mode
          when 'others' then _team_of(mb.id, p_day) is not null and _team_of(mb.id, p_day) is distinct from p_team
          when 'team'   then _team_of(mb.id, p_day) = p_team
          when 'day'    then _team_of(mb.id, p_day) is not null
          when 'member' then mb.id = p_member
          else false end
$$;

-- ---------- 権限 ----------
revoke execute on function _team_of(uuid, text), _teams_json(uuid) from public, anon, authenticated;
grant execute on function list_roster(), claim_member(uuid, text), list_members(uuid, text),
  move_member_day(uuid, text, uuid, text, uuid), add_member(uuid, text, text, uuid, uuid),
  release_member(uuid, text, uuid), hide_member(uuid, text, uuid) to anon, authenticated;
grant execute on all functions in schema public to service_role;

-- ============================================================
-- 本番データ：チームとメンバー（10/28 ドラフトの結果）
-- 何回流しても同じ結果になる（同じ名前のチーム・人は作り直さない）
-- ============================================================
do $$
declare
  -- [日, チーム名, メンバー…] の順（この順でチームが並ぶ）
  plan jsonb := '[
    ["11/3", "皆川チーム", ["皆川拓己","四十萬まひろ","名取美侑","中村広人","太田真優","安西華凜"]],
    ["11/3", "鈴木チーム", ["鈴木佑","星川智就","ゆう","尾崎圭治","小林爽","荒田賢治郎","由本佳葉"]],
    ["11/3", "中村チーム", ["中村圭吾","早川陽菜乃","稲木周平","廣瀬美優","森本群士","保苅麻緒","山口柚菜"]],
    ["11/3", "鴨下チーム", ["鴨下晃太郎","前原紬希","村田昂太郎","秦憲伸","鈴木姫莉","仲川咲千"]],
    ["11/4", "皆川チーム", ["皆川拓己","由本佳葉","佐々木楓月","坂田真勇","前原紬希","ゆう","高崎拓斗","安西華凜"]],
    ["11/4", "鈴木チーム", ["鈴木佑","坂崎さくら","田原太","名取美侑","稲木周平","森本群士","太田真優","秦憲伸"]],
    ["11/4", "中村チーム", ["中村圭吾","薦田莉瑚","星川智就","溝口心菜","粟村真衣","尾崎圭治","小林爽","村田昂太郎"]],
    ["11/4", "鴨下チーム", ["鴨下晃太郎","早川陽菜乃","中村美花","小林瑠莉","四津冴梨","荒田賢治郎","川田瑛之","林莉央"]]
  ]';
  row jsonb; d text; tn text; nm text; tid uuid; mid uuid; keep uuid[] := '{}';
begin
  for row in select jsonb_array_elements(plan) loop
      d := row ->> 0; tn := row ->> 1;
      select id into tid from teams where day = d and name = tn and deleted_at is null order by created_at limit 1;
      if tid is null then insert into teams(day, name) values (d, tn) returning id into tid; end if;
      keep := keep || tid;
      for nm in select jsonb_array_elements_text(row -> 2) loop
        select id into mid from members where name = nm and not hidden order by created_at limit 1;
        if mid is null then insert into members(name, secret_hash) values (nm, null) returning id into mid; end if;
        insert into member_teams(member_id, day, team_id) values (mid, d, tid)
        on conflict (member_id, day) do update set team_id = excluded.team_id;
      end loop;
  end loop;
  -- テストで作ったほかのチームは削除扱いに（マスター画面から元に戻せる）
  update teams set deleted_at = now() where deleted_at is null and not (id = any(keep));
end $$;

-- テストのカウントを消す（11/3より前に入れた分）
update counts set deleted_at = now() where deleted_at is null and created_at < timestamptz '2026-11-03 00:00+09';
-- リハーサル設定を本番に戻す（12:30から非公開、ヒントは30分ごと）
update config set force_at = null, manual_hide = '{}', shown = '{}', revealed = '{}', slot_minutes = 30,
  hide_times = '{"11/3":"12:30","11/4":"12:30"}' where id = 1;
