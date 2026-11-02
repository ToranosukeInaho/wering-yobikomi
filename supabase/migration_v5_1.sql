-- ============================================================
-- v5.1：4チーム以下のとき、2回目のヒントを「上半分／下半分」だけにする
--   （「上位3チームに入っていません」＝最下位とバレるのを防ぐ）
-- SQL Editor に丸ごと貼って Run
-- ============================================================
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
    if n <= 4 then opt := 1;                    -- 4チーム以下は「上位3」で最下位がバレるので上半分/下半分だけ
    elsif opt = 2 and n <= 5 then opt := 0; end if;
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

