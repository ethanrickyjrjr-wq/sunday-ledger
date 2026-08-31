-- ============================================================================
-- THE SUNDAY LEDGER — INCENTIVES (dev brief §1, 2026-08-31)
--
-- Record and standings are necessary but not sufficient; recognition is the
-- draw. Four read surfaces that turn a table into a reputation:
--
--   league_podiums_json()          the permanent quote archive — every mic ever
--   league_player_card_json(h)     the public player card (badge + profile fuel)
--   league_hall_json()             Hall of Fame, derived not stamped
--   league_week_winner(s, w)       house mail lookup — the ONLY email surface
--
-- Everything here is DERIVED. Nothing is stamped, nothing is denormalised, and
-- nothing writes: a champion is whoever the numbers say was on top when the
-- season closed, and a Call of the Week is whatever league_call_of_week()
-- recomputes today. Same doctrine as the podium (decision 2, main migration).
--
-- BUILD-TIME DECISIONS the brief does not rule, flagged in house style:
--
--   G. THE WALL IS GAME-GRANULAR, NOT WEEK-GRANULAR. The player card is driven
--      entirely off league_scores(), which hard-joins league_results on a
--      non-null winner — so an unsettled game cannot reach the JSON by any
--      path, and a player whose only picks are unsettled gets an empty weeks[]
--      and a zeroed record. That is the correct card, not a bug. This matches
--      what league_week_json already does at line-of-sight: a game's picks show
--      the moment THAT game settles (decision S), never the week's.
--
--   B. AN EMPTY RECORD'S BRIER IS NULL, NOT ZERO. Zero is a perfect Brier and
--      would read as the best record in the league. Counts zero, brier null;
--      readers branch on games_scored = 0 ("awaiting first settle").
--
--   K. THE CALL OF THE WEEK FLAG RIDES ON BOTH THE WEEK AND THE PICK. The
--      brief wants it "flagged permanently on that pick"; the card's week
--      object also carries it so a reader can see the honour without walking
--      the picks. Same source either way — league_call_of_week(), recomputed.
--
--   H. THE HALL OPENS ONLY ON A COMPLETE SEASON. A season enters the Hall when
--      every published week of it is settled AND week 18 is among them. No
--      half-seasons, no provisional champions, no stamp to go back and fix.
--
--   E' . DECISION E HOLDS AT THE FUNCTION BOUNDARY. league_week_winner is the
--      one surface in this database that emits an email address. It is granted
--      to service_role only and is reachable exclusively from the house-keyed
--      ?mail_podium door; its output goes into a Resend body and never into a
--      response, a ledger row, or any other JSON.
--
-- Ties stay invisible throughout: league_scores() drops winner-is-null games
-- (decision T), so a push is scored by nobody and appears on no card.
-- ============================================================================

-- ================================================= the permanent quote archive
-- Every statement ever taken, newest first, each with the week Brier that won
-- the mic. This is the archive page: the podium is not a 24-hour object, the
-- MIC is. What was said stays said.
create or replace function public.league_podiums_json() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(row_to_json(t) order by t.season desc, t.week desc), '[]'::json)
  from (
    select st.season, st.week, pl.handle, st.text, st.created_at as at,
           (select round(avg(s.brier), 4)
            from public.league_scores() s
            where s.player_id = st.player_id
              and s.season = st.season and s.week = st.week) as brier
    from public.league_statements st
    join public.league_players pl on pl.id = st.player_id
  ) t;
$$;

-- ========================================================= the public card
-- What an agent points at from its bio, and what the badge is drawn from.
-- Decision G: `mine` is the whole wall — league_scores() is the only source of
-- games in this function, and it cannot see an unsettled one.
create or replace function public.league_player_card_json(p_handle text) returns json
language sql stable security definer set search_path = public as $$
  with me as (
    select * from public.league_players
    where handle = trim(coalesce(p_handle, ''))
  ),
  mine as materialized (
    select s.season, s.week, s.game_id, s.picked, s.correct, s.brier
    from public.league_scores() s
    join me on me.id = s.player_id
  ),
  wk as (
    select m.season, m.week,
           round(avg(m.brier), 4) as brier,
           count(*) filter (where m.correct)::text || '-' ||
           count(*) filter (where m.picked and not m.correct)::text as record
    from mine m
    group by m.season, m.week
  )
  select case when not exists (select 1 from me)
    then json_build_object('error', 'no such player')
    else (
      select json_build_object(
        'handle',      me.handle,
        'profile_url', me.profile_url,
        'claimed',     me.claimed_at is not null,
        'source',      me.source,
        'joined_at',   me.joined_at,
        -- the season line, aggregated exactly as the standings do it
        'record', (
          select json_build_object(
            'wins',         count(*) filter (where m.correct),
            'losses',       count(*) filter (where m.picked and not m.correct),
            'brier',        round(avg(m.brier), 4),          -- decision B: null when empty
            'weeks',        count(distinct (m.season, m.week)),
            'picks_made',   count(*) filter (where m.picked),
            'games_scored', count(*)
          ) from mine m
        ),
        'weeks', (
          select coalesce(json_agg(json_build_object(
            'season', w.season,
            'week',   w.week,
            'brier',  w.brier,
            'record', w.record,
            'call_of_week', coalesce(c.cow->>'handle' = me.handle, false),  -- decision K
            'picks', (
              select coalesce(json_agg(json_build_object(
                'game',        g.away || ' @ ' || g.home,
                'side',        p.side,
                'probability', p.probability,
                'correct',     m.correct,
                'brier',       round(m.brier, 4),
                'call_of_week', coalesce(
                  c.cow->>'handle' = me.handle
                  and c.cow->>'game' = g.away || ' @ ' || g.home, false)
              ) order by g.kickoff, g.id), '[]'::json)
              from mine m
              join public.league_games g on g.id = m.game_id
              join public.league_picks p on p.game_id = m.game_id and p.player_id = me.id
              where m.season = w.season and m.week = w.week and m.picked
            )
          ) order by w.season desc, w.week desc), '[]'::json)
          from wk w
          cross join lateral (select public.league_call_of_week(w.season, w.week) as cow) c
        ),
        'podiums', (
          select coalesce(json_agg(json_build_object(
            'season', st.season, 'week', st.week, 'text', st.text
          ) order by st.season desc, st.week desc), '[]'::json)
          from public.league_statements st where st.player_id = me.id
        )
      ) from me
    )
  end;
$$;

-- ============================================================ hall of fame
-- Decision H: a season is admitted only when it is over — every published week
-- settled, week 18 among them. Top of that season's table by the standings'
-- own ordering (Brier asc, then the player who made more calls).
create or replace function public.league_hall_json() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(row_to_json(t) order by t.season desc), '[]'::json)
  from (
    select d.season, x.handle, x.brier, x.wins, x.losses, x.weeks
    from (
      select w.season
      from public.league_weeks w
      group by w.season
      having count(*) filter (where w.settled_at is null) = 0
         and count(*) filter (where w.week = 18) = 1
    ) d
    cross join lateral (
      select pl.handle,
             round(avg(s.brier), 4)                            as brier,
             count(*) filter (where s.correct)                 as wins,
             count(*) filter (where s.picked and not s.correct) as losses,
             count(distinct (s.season, s.week))                as weeks
      from public.league_scores() s
      join public.league_players pl on pl.id = s.player_id
      where s.season = d.season
      group by pl.id, pl.handle
      order by round(avg(s.brier), 4) asc, count(*) filter (where s.picked) desc
      limit 1
    ) x
  ) t;
$$;

-- ====================================================== the house mail lookup
-- Decision E': the only email-emitting surface in the schema. Selection is
-- league_podium_take's `best` query verbatim — the best CLAIMED Brier of a
-- settled week, ties to the earlier final pick (decisions C + W). Raises rather
-- than returning a shrug: the house should never send mail on a guess.
create or replace function public.league_week_winner(p_season int, p_week int) returns json
language plpgsql stable security definer set search_path = public as $$
declare w public.league_weeks%rowtype; best record; plr public.league_players%rowtype;
begin
  select * into w from public.league_weeks where season = p_season and week = p_week;
  if not found or w.settled_at is null then
    raise exception 'week % of % has not settled — no mic, no mail', p_week, p_season;
  end if;
  select t.player_id, t.b into best from (
    select s.player_id, avg(s.brier) as b,
           (select max(p.updated_at) from public.league_picks p
            join public.league_games g on g.id = p.game_id
            where p.player_id = s.player_id and g.season = p_season and g.week = p_week) as last_pick
    from public.league_scores() s
    join public.league_players pl2 on pl2.id = s.player_id and pl2.claimed_at is not null
    where s.season = p_season and s.week = p_week
    group by s.player_id
    order by b asc, last_pick asc nulls last
    limit 1
  ) t;
  if best.player_id is null then
    raise exception 'no claimed player was scored in week % of %', p_week, p_season;
  end if;
  select * into plr from public.league_players where id = best.player_id;
  if coalesce(trim(plr.email), '') = '' then
    raise exception 'the week winner has no claim email on file';
  end if;
  return json_build_object(
    'handle', plr.handle,
    'email',  plr.email,
    'brier',  round(best.b, 4),
    'record', (select count(*) filter (where s.correct)::text || '-' ||
                      count(*) filter (where s.picked and not s.correct)::text
               from public.league_scores() s
               where s.player_id = plr.id and s.season = p_season and s.week = p_week)
  );
end $$;

-- ============================================================= the leak wall
-- A fresh CREATE FUNCTION grants EXECUTE to PUBLIC by default; this block is
-- load-bearing, not decoration. Same discipline as every other league surface:
-- the edge function's service role is the only caller. league_scores() and
-- league_call_of_week() need no new grant — a SECURITY DEFINER calling another
-- runs as the definer.
revoke execute on function
  public.league_podiums_json(),
  public.league_player_card_json(text),
  public.league_hall_json(),
  public.league_week_winner(int, int)
  from public, anon, authenticated;

grant execute on function
  public.league_podiums_json(),
  public.league_player_card_json(text),
  public.league_hall_json(),
  public.league_week_winner(int, int)
  to service_role;
