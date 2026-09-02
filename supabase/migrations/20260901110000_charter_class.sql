-- ============================================================================
-- The Charter Class + the retire door. (League migration; shared-DB rules apply.)
--
-- §8 Charter Class: every player with a pick frozen on the inaugural slate
-- (the earliest published week of the league) carries a charter mark on the
-- card, the badge, and the standings, forever. Recognition, never scoring —
-- nothing in league_scores() reads it, so sl-brier-slate-v1 is untouched.
-- The mark is computed, not stored: a pick on the first week's games IS the
-- fact, and picks cannot be deleted, so once the freeze passes the mark is
-- permanent by construction. Before the freeze it reads "on the charter
-- roll as of now", which is also true.
--
-- §9 the retire door: the house removes a handle from the ledger (impersonation,
-- multiple handles, a smoke row) by setting active=false and appending a
-- ledger event — noted in the ledger, never silently deleted. Retired handles
-- vanish from the card, the standings, and the scoreboard. Their picks stay
-- in the tables (the record is append-only); they simply stop being listed.
-- ============================================================================

-- ------------------------------------------------------------ the charter test
create or replace function public.league_is_charter(p_player uuid) returns boolean
language sql stable security definer set search_path = public as $$
  with first_slate as (
    select season, week from public.league_weeks order by season, week limit 1
  )
  select exists (
    select 1
    from public.league_picks p
    join public.league_games g on g.id = p.game_id
    join first_slate f on f.season = g.season and f.week = g.week
    where p.player_id = p_player
  );
$$;

-- ---------------------------------------------- the player card, amended (§8/§9)
create or replace function public.league_player_card_json(p_handle text) returns json
language sql stable security definer set search_path = public as $$
  with me as (
    select * from public.league_players
    where handle = trim(coalesce(p_handle, '')) and active
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
        -- §8 Charter Class: a frozen pick on the inaugural slate, forever
        'charter',     public.league_is_charter(me.id),
        -- the season line, aggregated exactly as the standings do it
        'record', (
          select json_build_object(
            'wins',         count(*) filter (where m.correct),
            'losses',       count(*) filter (where m.picked and not m.correct),
            'brier',        round(avg(m.brier), 4),          -- decision B: null when empty
            'weeks',        count(distinct (m.season, m.week)),
            'picks_made',   count(*) filter (where m.picked),
            'games_scored', count(*),
            'coverage_rate', round((count(*) filter (where m.picked))::numeric
                                   / nullif(count(*), 0), 4)
          ) from mine m
        ),
        -- §7: overturned disputes credited to this player, forever
        'overturns', (
          select count(*) from public.league_disputes d
          where d.disputant = me.id and d.ruling = 'overturned'
        ),
        -- §6: the block a calibration claim carries when it leaves this league
        'traveling_claim', (
          select json_build_object(
            'prediction_domain',    'NFL',
            'scoring_rule_version', 'sl-brier-slate-v1',
            'coverage_rate', round((count(*) filter (where m.picked))::numeric
                                   / nullif(count(*), 0), 4),
            'record', json_build_object(
              'wins',   count(*) filter (where m.correct),
              'losses', count(*) filter (where m.picked and not m.correct),
              'brier',  round(avg(m.brier), 4)),
            'settlement_source', json_build_object(
              'finals',       'https://www.thesportsdb.com',
              'player_stats', 'https://github.com/nflverse/nflverse-data')
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
        -- §8: credits this player awarded (unsealed: settled games only)
        'turns', (
          select coalesce(json_agg(json_build_object(
            'game',         g.away || ' @ ' || g.home,
            'season',       g.season, 'week', g.week,
            'credited_to',  t.credited_to,
            'argument_url', t.argument_url,
            'turned_onto',  case when r.winner is null then 'a push'
                                 when p.side = r.winner then 'the winner'
                                 else 'the loser' end,
            'turn_of_week', exists (select 1 from public.league_turn_stamps ts
                                    where ts.player_id = t.player_id and ts.game_id = t.game_id)
          ) order by g.kickoff desc), '[]'::json)
          from public.league_turns t
          join public.league_games g on g.id = t.game_id
          join public.league_results r on r.game_id = t.game_id
          join public.league_picks p on p.game_id = t.game_id and p.player_id = me.id
          where t.player_id = me.id
        ),
        -- §8: credits naming this handle as the persuader (same seal)
        'turned', (
          select coalesce(json_agg(json_build_object(
            'turned',       opl.handle,
            'game',         g.away || ' @ ' || g.home,
            'season',       g.season, 'week', g.week,
            'argument_url', t.argument_url,
            'turned_onto',  case when r.winner is null then 'a push'
                                 when p.side = r.winner then 'the winner'
                                 else 'the loser' end,
            'turn_of_week', exists (select 1 from public.league_turn_stamps ts
                                    where ts.player_id = t.player_id and ts.game_id = t.game_id)
          ) order by g.kickoff desc), '[]'::json)
          from public.league_turns t
          join public.league_players opl on opl.id = t.player_id
          join public.league_games g on g.id = t.game_id
          join public.league_results r on r.game_id = t.game_id
          join public.league_picks p on p.game_id = t.game_id and p.player_id = t.player_id
          where lower(t.credited_to) = lower(me.handle)
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

-- --------------------------------------- the signup scoreboard, amended (charter)
create or replace function public.league_conference_counts() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'AFC',        count(*) filter (where conference = 'AFC'),
    'NFC',        count(*) filter (where conference = 'NFC'),
    'undeclared', count(*) filter (where conference is null),
    'players',    count(*),
    'charter',    count(*) filter (where public.league_is_charter(id))
  ) from public.league_players where active;
$$;

-- ----------------------------------------------- standings, amended (§8/§9)
create or replace function public.league_standings_json() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(row_to_json(t) order by t.brier asc, t.picks_made desc), '[]'::json)
  from (
    select pl.handle, pl.profile_url, pl.conference,
           (pl.claimed_at is not null)                        as claimed,
           pl.source,
           public.league_is_charter(pl.id)                    as charter,
           count(distinct (s.season, s.week))                 as weeks,
           count(*) filter (where s.picked)                   as picks_made,
           count(*)                                           as games_scored,
           count(*) filter (where s.correct)                  as wins,
           count(*) filter (where s.picked and not s.correct) as losses,
           round(avg(s.brier), 4)                             as brier
    from public.league_scores() s
    join public.league_players pl on pl.id = s.player_id and pl.active
    group by pl.id, pl.handle, pl.profile_url, pl.conference, pl.claimed_at, pl.source
  ) t;
$$;

-- ------------------------------------------------------------- the retire door
-- House-only (the edge function checks x-house-key; the function itself is
-- granted to service_role alone). Idempotent: retiring a retired handle is a
-- no-op that says so.
create or replace function public.league_retire(p_handle text, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare pl public.league_players%rowtype;
begin
  select * into pl from public.league_players where handle = trim(coalesce(p_handle, ''));
  if not found then
    raise exception 'no such player';
  end if;
  if not pl.active then
    return json_build_object('ok', true, 'handle', pl.handle, 'already', true);
  end if;
  update public.league_players set active = false where id = pl.id;
  perform public.ledger('league_retired', null,
    jsonb_build_object('player_id', pl.id, 'handle', pl.handle,
      'note', nullif(trim(coalesce(p_note, '')), '')));
  return json_build_object('ok', true, 'handle', pl.handle, 'retired', true);
end $$;

revoke execute on function
  public.league_is_charter(uuid),
  public.league_retire(text, text)
  from public, anon, authenticated;

grant execute on function
  public.league_is_charter(uuid),
  public.league_retire(text, text)
  to service_role;
