-- ============================================================
-- v3 への更新（migration_v2.sql を流したあとに、これを丸ごと貼って Run）
-- チームに「〇人」でカウントする形に変更。データはそのまま残る。
-- ============================================================
-- ---------- v3：チームに「〇人」まとめてカウント ----------
create or replace function add_team_count(p_id uuid, p_secret text, p_team uuid, p_n int) returns bigint[]
language plpgsql security definer set search_path = public, extensions as $$
declare m members; t teams; ids bigint[];
begin
  m := _auth(p_id, p_secret);
  if not _is_counter(m) then raise exception 'not_counter'; end if;
  t := _live_team(p_team);
  if t.id is null then raise exception 'no_team'; end if;
  if p_n is null or p_n < 1 or p_n > 20 then raise exception 'bad_n'; end if;
  with ins as (
    insert into counts(team_id, day, counted_by)
    select t.id, t.day, m.id from generate_series(1, p_n)
    returning id)
  select array_agg(id order by id) into ids from ins;
  return ids;
end $$;

-- そのチームのその日の最新1件を取り消す（-1）
create or replace function minus_team_count(p_id uuid, p_secret text, p_team uuid) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare m members; cid bigint;
begin
  m := _auth(p_id, p_secret);
  if not _is_counter(m) then raise exception 'not_counter'; end if;
  select id into cid from counts where team_id = p_team and deleted_at is null
   order by created_at desc, id desc limit 1;
  if cid is null then raise exception 'nothing_to_minus'; end if;
  update counts set deleted_at = now() where id = cid;
  return cid;
end $$;

-- まとめて取り消し（直前の「+3」を丸ごと戻す用）
create or replace function undo_counts(p_id uuid, p_secret text, p_ids bigint[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare m members;
begin
  m := _auth(p_id, p_secret);
  if not _is_counter(m) then raise exception 'not_counter'; end if;
  update counts set deleted_at = now() where id = any(p_ids) and deleted_at is null;
end $$;

-- 通知用：同時に入れた分（+3なら3件）をまとめて1回の通知にする
create or replace function _claim_count_notify(p_id uuid, p_secret text, p_count bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare m members; c counts; tname text; n int;
begin
  m := _auth(p_id, p_secret);
  select * into c from counts
   where id = p_count and counted_by = m.id and not notified and deleted_at is null
     and created_at > now() - interval '5 minutes';
  if c.id is null then return null; end if;
  with u as (
    update counts set notified = true
     where team_id = c.team_id and counted_by = c.counted_by and created_at = c.created_at and not notified
    returning 1)
  select count(*) into n from u;
  select name into tname from teams where id = c.team_id;
  return json_build_object('day', c.day, 'team_id', c.team_id, 'team_name', tname, 'n', n, 'hidden', _hidden(c.day));
end $$;

revoke execute on function add_team_count(uuid, text, uuid, int), minus_team_count(uuid, text, uuid),
  undo_counts(uuid, text, bigint[]), _claim_count_notify(uuid, text, bigint) from public, anon, authenticated;
grant execute on function add_team_count(uuid, text, uuid, int), minus_team_count(uuid, text, uuid),
  undo_counts(uuid, text, bigint[]) to anon, authenticated;
grant execute on all functions in schema public to service_role;
