-- ============================================================================
-- CARRY + ALARM — §7 made real, and the settle given a voice.
--
-- Two faults, one root. Found 2026-09-03, six days before the Week 1 freeze.
--
-- FAULT 1 (the silence). The read-triggered sweep swallowed every error and
-- wrote nothing anywhere: no log, no ledger row, no field in the response.
-- Worse, the one cron that nudges ?settle (settle-props.yml, chained) threw
-- the response away, and ?settle answers 200 on the LIKELY failure — a score
-- source that returns 200 with a payload we cannot parse yields finals=[] ->
-- {swept:false} -> 200 -> green. The only alarm was deaf to the only failure
-- worth alarming on. Schema drift on strStatus (FT/AOT, pinned from four
-- observed 2025 weeks) would have run silently and indefinitely.
--
-- FAULT 2 (the freeze). league_settle stamped a week only when EVERY game had
-- a result, so one postponed game froze the whole week: no settle, no podium,
-- no standings movement, ever. The manifest already promised otherwise:
-- "a postponed game is not a void and not an abstention... it remains a game
-- of its original slate week... while carried it sits outside every computed
-- number... and enters the denominator of every player when it grades."
--
-- The rule was already TRUE in the scoring layer: league_scores() joins
-- league_results on winner is not null, so an ungraded game is outside the
-- season mean, games_scored and coverage_rate by construction, and enters
-- every denominator the moment a result row lands — pickers at their frozen
-- pick, everyone else at 0.25. Nothing about Brier changes here. The ONLY
-- thing missing was permission to stamp the week around it.
--
-- Why carrying is an explicit act and not a timeout: an automatic "ungraded
-- for N hours = carried" rule would settle every week around every game the
-- moment the score source died, which is precisely the failure fault 1 exists
-- to catch. So the desk carries a game on purpose, with a note, on the public
-- record — and anything ungraded that nobody carried is STUCK, and stuck is
-- what the alarm is for. The two faults fix each other.
--
-- DECISIONS this migration takes:
--
--   C1. CARRY IS DELIBERATE, NOTED, AND APPENDED. POST ?carry with a note of
--       8-500 characters, ledgered as game_carried, never deleted. Earliest
--       at kickoff + 3h — the threshold the sweep gate already uses to decide
--       a game is owed. Before that a game is merely late, not postponed.
--
--   C2. A WEEK IS COMPLETE WHEN EVERY GAME IS GRADED *OR* CARRIED. One helper
--       (league_stamp_week) is now the only place settled_at is ever written;
--       league_settle and the correction lane both call it. The duplicated
--       predicate that let this fault exist in two places at once is gone.
--
--   C3. FINALITY WAITS FOR THE LAST GRADING, NOT THE STAMP. settled_at now
--       means "graded or carried", so it can no longer stand in for "all the
--       answers are in". league_week_final_at() is null while any game of the
--       week is ungraded, and otherwise runs 72h from the LATEST grading in
--       the week. For an ordinary week every result lands in the same
--       transaction as the stamp, so this is settled_at + 72h exactly as
--       before — no behaviour change. For a carried week it is the promise
--       already in the rule text: "the late grading is appended to its
--       original week with its own 72-hour dispute window."
--
--   C4. A GAME'S DISPUTE WINDOW IS ITS OWN. Same reasoning, per grading
--       rather than per week, so a game that grades three weeks late is
--       disputable when it grades — and a game that graded on time does NOT
--       have its closed window reopened by its neighbour. This is the rule
--       props have had since day one ("a prop's 72h runs from its own
--       result's settled_at, not the week's"); games now match.
--
--   C5. NO CHAMPION OVER AN UNGRADED GAME. ?hall admitted a season when every
--       week had settled_at. Under C2 that would crown a champion with a game
--       still owed, contradicting a published line ("No champion is crowned
--       while any game of the season is still unsettled"). The hall now
--       requires every game of the season to have graded, carry or no carry.
--
--   C6. THE SWEEP GATE STOPS CHASING A GAME NOBODY IS PLAYING. A carried game
--       is excluded from the gate. Before this, any permanently ungraded game
--       kept the gate due forever, so every ?week/?standings read paid a
--       score-source fetch every five minutes, indefinitely.
-- ============================================================================

-- ------------------------------------------------------------------- carry
alter table public.league_games
  add column if not exists carried_at timestamptz,
  add column if not exists carry_note text;

comment on column public.league_games.carried_at is
  'Section 7: the desk carried this game (postponed). Sealed picks stay sealed and ungraded; the game sits outside every computed number until a result lands.';

-- ------------------------------------------------- the one place weeks stamp
-- Decision C2. Returns true only if THIS call did the stamping: the update is
-- conditional on settled_at is null, so two racing sweeps cannot both ledger
-- a week_settled for the same week.
create or replace function public.league_stamp_week(p_season int, p_week int, p_via text)
returns boolean
language plpgsql security definer set search_path = public as $fn$
declare n_carried int; r record;
begin
  -- Incomplete: something is ungraded that nobody carried.
  if exists (select 1 from public.league_games g
             left join public.league_results res on res.game_id = g.id
             where g.season = p_season and g.week = p_week
               and res.game_id is null and g.carried_at is null) then
    return false;
  end if;

  select count(*) into n_carried
  from public.league_games g
  left join public.league_results res on res.game_id = g.id
  where g.season = p_season and g.week = p_week and res.game_id is null;

  update public.league_weeks set settled_at = now()
    where season = p_season and week = p_week and settled_at is null;
  if not found then return false; end if;

  perform public.ledger('week_settled', null,
    jsonb_build_object('season', p_season, 'week', p_week, 'via', p_via,
                       'carried', n_carried));

  for r in select s.player_id, s.game_id as gid, pl.handle
           from public.league_scores() s
           join public.league_players pl on pl.id = s.player_id
           where s.season = p_season and s.week = p_week and not s.picked loop
    perform public.ledger('pick_defaulted', null,
      jsonb_build_object('season', p_season, 'week', p_week, 'player_id', r.player_id,
                         'handle', r.handle, 'game_id', r.gid, 'as', 0.5));
  end loop;
  return true;
end $fn$;

-- ------------------------------------------------------------- the carry door
-- Decision C1. Re-carrying an already-carried game rewrites the note and keeps
-- the original carried_at: the first carry is when the desk said so.
create or replace function public.league_carry(p_game_id text, p_note text) returns json
language plpgsql security definer set search_path = public as $fn$
declare g public.league_games%rowtype; v_stamped boolean; v_at timestamptz;
begin
  select * into g from public.league_games where id = p_game_id;
  if not found then raise exception 'no such game on any slate'; end if;
  if exists (select 1 from public.league_results rr where rr.game_id = g.id) then
    raise exception 'that game has graded — a grading is corrected, never carried';
  end if;
  if now() < g.kickoff + interval '3 hours' then
    raise exception 'a game is carried once it is plainly not being played: % at the earliest',
      g.kickoff + interval '3 hours';
  end if;
  if char_length(trim(coalesce(p_note,''))) not between 8 and 500 then
    raise exception 'a carry carries a note: 8-500 characters, on the public record';
  end if;

  update public.league_games
     set carried_at = coalesce(carried_at, now()), carry_note = trim(p_note)
   where id = g.id
   returning carried_at into v_at;

  perform public.ledger('game_carried', null,
    jsonb_build_object('game_id', g.id, 'season', g.season, 'week', g.week,
                       'game', g.away || ' @ ' || g.home, 'note', trim(p_note)));

  v_stamped := public.league_stamp_week(g.season, g.week, 'carry');
  return json_build_object('ok', true, 'game_id', g.id,
    'game', g.away || ' @ ' || g.home, 'season', g.season, 'week', g.week,
    'carried_at', v_at, 'note', trim(p_note), 'week_settled', v_stamped);
end $fn$;

-- ------------------------------------------------------------- settle, amended
-- Same finals loop as the base migration; the week-stamping block is replaced
-- by the shared helper (decision C2) and now reports how many weeks it closed.
create or replace function public.league_settle(p_finals jsonb) returns json
language plpgsql security definer set search_path = public as $fn$
declare f jsonb; g public.league_games%rowtype; n int := 0; wk record; stamped int := 0;
begin
  for f in select * from jsonb_array_elements(p_finals) loop
    select * into g from public.league_games where id = f->>'id';
    if not found or now() < g.kickoff then continue; end if;
    insert into public.league_results (game_id, away_score, home_score, winner)
    values (g.id, (f->>'away_score')::int, (f->>'home_score')::int, nullif(f->>'winner',''))
    on conflict (game_id) do nothing;
    if found then n := n + 1; end if;
  end loop;

  for wk in select ww.season, ww.week from public.league_weeks ww
            where ww.settled_at is null order by ww.season, ww.week loop
    if public.league_stamp_week(wk.season, wk.week, 'sweep') then stamped := stamped + 1; end if;
  end loop;

  return json_build_object('ok', true, 'finals_written', n, 'weeks_settled', stamped);
end $fn$;

-- --------------------------------------------------------------- the gate, C6
-- Throttle gate: the function asks before touching the score source. Due only
-- when an unsettled week has an UNCARRIED game past kickoff+3h with no result
-- and the last sweep is >5min old. A carried game is not owed, so it never
-- makes the gate due — before this, one permanently ungraded game meant every
-- read paid a source fetch every five minutes forever.
create or replace function public.league_sweep_gate() returns json
language plpgsql security definer set search_path = public as $fn$
declare tgt record;
begin
  select g.season, g.week into tgt
  from public.league_games g
  join public.league_weeks w on w.season = g.season and w.week = g.week and w.settled_at is null
  left join public.league_results r on r.game_id = g.id
  where r.game_id is null and g.carried_at is null and now() >= g.kickoff + interval '3 hours'
  order by g.kickoff limit 1;
  if tgt is null then return json_build_object('due', false); end if;
  update public.league_sweep set last_run = now()
    where only_row and last_run < now() - interval '5 minutes';
  if not found then return json_build_object('due', false); end if;
  return json_build_object('due', true, 'season', tgt.season, 'week', tgt.week);
end $fn$;

-- ------------------------------------------------------------------ the alarm
-- Fault 1's answer. STUCK = a game the score source still owes us: past
-- kickoff + 6h, no result, nobody carried it. Six hours, not the gate's three,
-- so a long game or one bad minute at the source is not a page — only a real
-- hole is. CARRIED = games sitting outside the numbers on purpose (§7); they
-- are reported, never alarmed on.
--
-- This is deliberately computed across EVERY week, not just the current one:
-- a week that stopped settling in October must not go quiet just because a
-- newer slate published on top of it.
create or replace function public.league_settle_health() returns json
language sql stable security definer set search_path = public as $fn$
  with ungraded as (
    select g.id, g.season, g.week, g.kickoff, g.away || ' @ ' || g.home as game,
           g.carried_at, g.carry_note
    from public.league_games g
    left join public.league_results r on r.game_id = g.id
    where r.game_id is null
  )
  select json_build_object(
    'ok', not exists (select 1 from ungraded u
                      where u.carried_at is null and now() >= u.kickoff + interval '6 hours'),
    'checked_at', now(),
    'stuck', coalesce((
      select json_agg(json_build_object(
               'game_id', u.id, 'season', u.season, 'week', u.week,
               'kickoff', u.kickoff, 'game', u.game,
               'hours_overdue', round(extract(epoch from now() - u.kickoff) / 3600.0, 1))
             order by u.kickoff)
      from ungraded u
      where u.carried_at is null and now() >= u.kickoff + interval '6 hours'), '[]'::json),
    'carried', coalesce((
      select json_agg(json_build_object(
               'game_id', u.id, 'season', u.season, 'week', u.week, 'game', u.game,
               'carried_at', u.carried_at, 'note', u.carry_note)
             order by u.kickoff)
      from ungraded u where u.carried_at is not null), '[]'::json)
  );
$fn$;

-- ------------------------------------------------- the read path gets a voice
-- The read-triggered sweep still must not block a read on a bad minute at the
-- source — a badge in a bio cannot 500 because TheSportsDB hiccupped. But it
-- no longer vanishes. The gate stamps last_run BEFORE the fetch, so a failing
-- source can write at most one of these every five minutes.
create or replace function public.league_sweep_failed(p_error text) returns void
language plpgsql security definer set search_path = public as $fn$
begin
  perform public.ledger('sweep_failed', null,
    jsonb_build_object('error', left(coalesce(p_error, 'unknown'), 300), 'at', now()));
end $fn$;

-- ------------------------------------------------------------- finality, C3
-- Null while any game of the week is still ungraded — settled_at can no longer
-- stand in for "all the answers are in". Otherwise 72h from the LATEST grading
-- in the week, which for an ordinary week is settled_at itself (results and the
-- stamp land in one transaction), so ordinary weeks are unchanged.
--
-- A correction updates league_results without touching its settled_at, so a
-- correction still cannot chain the window open forever (decision F).
create or replace function public.league_week_final_at(p_season int, p_week int)
returns timestamptz
language sql stable security definer set search_path = public as $fn$
  select case
    when w.settled_at is null then null
    when exists (select 1 from public.league_games g
                 left join public.league_results r on r.game_id = g.id
                 where g.season = w.season and g.week = w.week and r.game_id is null)
      then null
    else greatest(w.settled_at,
           (select max(r2.settled_at) from public.league_results r2
            join public.league_games g2 on g2.id = r2.game_id
            where g2.season = w.season and g2.week = w.week)) + interval '72 hours'
  end
  from public.league_weeks w where w.season = p_season and w.week = p_week;
$fn$;

create or replace function public.league_week_final(p_season int, p_week int) returns boolean
language sql stable security definer set search_path = public as $fn$
  select public.league_week_final_at(p_season, p_week) is not null
     and now() >= public.league_week_final_at(p_season, p_week)
     and not exists (
       select 1 from public.league_disputes d
       left join public.league_games g on g.id = d.game_id
       left join public.league_props  pr on pr.id = d.prop_id
       where d.ruling is null
         and coalesce(g.season, pr.season) = p_season
         and coalesce(g.week,   pr.week)   = p_week);
$fn$;


-- ------------------------------------------------- a grading's own window (C4)
-- When THIS game's grading goes final: 72h after the later of its week's stamp
-- and the moment the result itself landed. Null while the week is unsettled —
-- the window opens at the week's stamp, exactly as the rule says ("disputable
-- for 72 hours after its week settles"), so a grading in a week still being
-- played stays open, which is the behaviour this replaces.
--
-- For a game graded with its week the two timestamps are the same instant, so
-- ordinary gradings close exactly when they always did. For a game carried
-- under section 7 and graded weeks later, this is its own window, and its
-- neighbours' closed windows are untouched.
create or replace function public.league_grading_closes_at(p_game_id text)
returns timestamptz
language sql stable security definer set search_path = public as $fn$
  select case when w.settled_at is null then null
              else greatest(w.settled_at, r.settled_at) + interval '72 hours' end
  from public.league_results r
  join public.league_games g on g.id = r.game_id
  join public.league_weeks w on w.season = g.season and w.week = g.week
  where r.game_id = p_game_id;
$fn$;

create or replace function public.league_grading_final(p_game_id text) returns boolean
language sql stable security definer set search_path = public as $fn$
  select coalesce(now() >= public.league_grading_closes_at(p_game_id), false);
$fn$;
-- =============================================== the docket, per grading (C4)
-- Extracted verbatim from 20260901090000_docket_regex_fix.sql and patched in
-- exactly one place: a GAME grading now closes 72h after the later of the
-- week's stamp and that grading's own settled_at. For a game that graded with
-- its week the two are the same instant, so the ordinary path is unchanged;
-- for a game carried under §7 and graded late, this is the "its own 72-hour
-- dispute window" the rule text already promised. A neighbour that graded on
-- time keeps its closed window — the late grading reopens nothing.
create or replace function public.league_dispute_file(
  p_token text, p_game_id text, p_prop_id text, p_graded text, p_evidence text, p_source_url text
) returns json
language plpgsql security definer set search_path = public as $$
declare
  me public.league_players%rowtype; g public.league_games%rowtype;
  pr public.league_props%rowtype; w public.league_weeks%rowtype;
  prr public.league_prop_results%rowtype; d public.league_disputes%rowtype;
begin
  me := public.league_player(p_token);
  if me.id is null then raise exception 'unknown token' using errcode = '42501'; end if;
  if (p_game_id is null) = (p_prop_id is null) then
    raise exception 'name exactly one grading: game_id or prop_id';
  end if;

  if p_game_id is not null then
    select * into g from public.league_games where id = p_game_id;
    if not found then raise exception 'no such game on any slate'; end if;
    if not exists (select 1 from public.league_results r where r.game_id = g.id) then
      raise exception 'that game has no grading yet — nothing to dispute';
    end if;
    select * into w from public.league_weeks where season = g.season and week = g.week;
    if public.league_grading_final(g.id) then
      raise exception 'the docket closed at % — that grading is final', public.league_grading_closes_at(g.id);
    end if;
  else
    select * into pr from public.league_props where id = p_prop_id;
    if not found then raise exception 'no such prop on any card'; end if;
    select * into prr from public.league_prop_results where prop_id = pr.id;
    if not found then raise exception 'that prop has no grading yet — nothing to dispute'; end if;
    if now() >= prr.settled_at + interval '72 hours' then
      raise exception 'the docket closed at % — that grading is final', prr.settled_at + interval '72 hours';
    end if;
  end if;

  if char_length(trim(coalesce(p_graded,'')))   not between 8 and 300 or
     char_length(trim(coalesce(p_evidence,''))) not between 8 and 300 then
    raise exception 'a dispute names what the ledger graded and what the evidence says: 8-300 characters each';
  end if;
  if coalesce(p_source_url,'') !~* '^https?://[^ ]{4,200}$' then
    raise exception 'the evidence needs a source: a link';
  end if;

  insert into public.league_disputes (disputant, kind, game_id, prop_id, graded, evidence, source_url)
  values (me.id, case when p_game_id is not null then 'game' else 'prop' end,
          p_game_id, p_prop_id, trim(p_graded), trim(p_evidence), trim(p_source_url))
  returning * into d;
  perform public.ledger('dispute_filed', null,
    jsonb_build_object('dispute_id', d.id, 'handle', me.handle, 'kind', d.kind,
                       'game_id', d.game_id, 'prop_id', d.prop_id, 'source', d.source_url));
  return json_build_object('ok', true, 'dispute_id', d.id, 'filed_at', d.filed_at,
    'on_the_record', 'the docket is public (GET ?docket); every dispute gets a written ruling before the week finalizes');
exception when unique_violation then
  raise exception 'you already have an open dispute on that grading';
end $$;

-- ================================================== the hall, guarded (C5)
-- Retyped from 20260901040000_incentives.sql with one clause added: a season
-- is admitted only when every game of it has GRADED. Decision C2 made
-- settled_at reachable with a game still owed, and the manifest is explicit:
-- "No champion is crowned while any game of the season is still unsettled."
create or replace function public.league_hall_json() returns json
language sql stable security definer set search_path = public as $fn$
  select coalesce(json_agg(row_to_json(t) order by t.season desc), '[]'::json)
  from (
    select d.season, x.handle, x.brier, x.wins, x.losses, x.weeks
    from (
      select s0.season
      from (
        select w.season
        from public.league_weeks w
        group by w.season
        having count(*) filter (where w.settled_at is null) = 0
           and count(*) filter (where w.week = 18) = 1
      ) s0
      where not exists (
        select 1 from public.league_games g
        left join public.league_results r on r.game_id = g.id
        where g.season = s0.season and r.game_id is null)
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
$fn$;

-- ============================================ the week, carry-aware (C3)
-- Extracted verbatim from 20260901080000_docket_and_turns.sql, patched twice:
-- final_at now comes from league_week_final_at (null while a game is owed,
-- rather than a confident settled_at+72h the docket would not honour), and
-- every game carries its carry state so a reader can see WHY a settled week
-- still has an ungraded game instead of guessing.
create or replace function public.league_week_json(p_token text default null, p_season int default null, p_week int default null)
returns json
language plpgsql stable security definer set search_path = public as $$
declare w public.league_weeks%rowtype; me public.league_players%rowtype; res json;
begin
  if p_season is null or p_week is null then
    select * into w from public.league_weeks order by season desc, week desc limit 1;
  else
    select * into w from public.league_weeks where season = p_season and week = p_week;
  end if;
  if not found then return json_build_object('week', null, 'note', 'no slate yet — the season is coming'); end if;
  if p_token is not null then me := public.league_player(p_token); end if;

  select json_build_object(
    'season', w.season, 'week', w.week,
    'freeze_at', w.freeze_at,
    'published_at', w.published_at, 'settled_at', w.settled_at,
    'final_at', public.league_week_final_at(w.season, w.week),
    'final', public.league_week_final(w.season, w.week),
    'main_card', to_jsonb(w.main_card),
    'games', (
      select json_agg(json_build_object(
        'game_id', g.id, 'kickoff', g.kickoff,
        'carried_at', g.carried_at, 'carry_note', g.carry_note,
        'away', g.away, 'home', g.home,
        'away_name', g.away_name, 'home_name', g.home_name,
        'main_card', g.id = any (w.main_card),
        'frozen', public.league_frozen(g),
        'result', (select json_build_object('away_score', r.away_score, 'home_score', r.home_score,
                     'winner', r.winner, 'tie', r.winner is null)
                   from public.league_results r where r.game_id = g.id),
        'my_pick', case when me.id is not null then
          (select json_build_object('side', p.side, 'probability', p.probability)
           from public.league_picks p where p.game_id = g.id and p.player_id = me.id) end,
        'my_turn', case when me.id is not null then
          (select json_build_object('credited_to', t.credited_to, 'argument_url', t.argument_url)
           from public.league_turns t where t.game_id = g.id and t.player_id = me.id) end,
        'picks', case when exists (select 1 from public.league_results r where r.game_id = g.id) then
          (select json_agg(json_build_object('handle', pl.handle, 'side', p.side,
                    'probability', p.probability, 'registered_at', p.updated_at) order by p.updated_at)
           from public.league_picks p join public.league_players pl on pl.id = p.player_id
           where p.game_id = g.id) end,
        'turns', case when exists (select 1 from public.league_results r where r.game_id = g.id) then
          (select json_agg(json_build_object('handle', pl.handle, 'credited_to', t.credited_to,
                    'argument_url', t.argument_url) order by t.updated_at)
           from public.league_turns t join public.league_players pl on pl.id = t.player_id
           where t.game_id = g.id) end
      ) order by g.kickoff, g.id)
      from public.league_games g where g.season = w.season and g.week = w.week
    ),
    'week_briers', case when w.settled_at is not null then (
      select json_agg(json_build_object('handle', pl.handle, 'brier', t.brier, 'record', t.rec) order by t.brier asc)
      from (
        select s.player_id, round(avg(s.brier), 4) as brier,
               count(*) filter (where s.correct) || '-' || count(*) filter (where s.picked and not s.correct) as rec
        from public.league_scores() s where s.season = w.season and s.week = w.week
        group by s.player_id
      ) t join public.league_players pl on pl.id = t.player_id
    ) end,
    'podium', (select json_build_object('handle', pl.handle, 'text', st.text, 'at', st.created_at)
               from public.league_statements st join public.league_players pl on pl.id = st.player_id
               where st.season = w.season and st.week = w.week),
    'call_of_week', case when w.settled_at is not null then public.league_call_of_week(w.season, w.week) end,
    'turn_of_week', case when w.settled_at is not null then
      (select json_build_object('handle', pl.handle, 'credited_to', t.credited_to,
         'game', g.away || ' @ ' || g.home, 'argument_url', t.argument_url, 'note', ts.note,
         'turned_onto', case when r.winner is null then 'a push'
                             when p.side = r.winner then 'the winner' else 'the loser' end)
       from public.league_turn_stamps ts
       join public.league_turns t on t.player_id = ts.player_id and t.game_id = ts.game_id
       join public.league_players pl on pl.id = ts.player_id
       join public.league_games g on g.id = ts.game_id
       left join public.league_results r on r.game_id = ts.game_id
       left join public.league_picks p on p.game_id = ts.game_id and p.player_id = ts.player_id
       where ts.season = w.season and ts.week = w.week) end,
    'corrections', (
      select coalesce(json_agg(json_build_object(
        'kind', c.kind,
        'target', case when c.kind = 'game' then g2.away || ' @ ' || g2.home else pr.label end,
        'before', c.before, 'after', c.after, 'note', c.note, 'corrected_at', c.corrected_at
      ) order by c.corrected_at), '[]'::json)
      from public.league_corrections c
      left join public.league_games g2 on g2.id = c.game_id
      left join public.league_props pr on pr.id = c.prop_id
      where coalesce(g2.season, pr.season) = w.season and coalesce(g2.week, pr.week) = w.week
    )
  ) into res;
  return res;
end $$;

-- ==================================== the correction lane, via C2 helper
-- Extracted verbatim from 20260901080000_docket_and_turns.sql; the inlined
-- copy of the week-stamping predicate is replaced by the shared helper. That
-- duplicate is how fault 2 came to exist in two places at once.
create or replace function public.league_apply_game_correction(
  p_game_id text, p_away int, p_home int, p_winner text, p_note text, p_dispute_id uuid
) returns json
language plpgsql security definer set search_path = public as $$
declare
  g public.league_games%rowtype; r public.league_results%rowtype;
  v_winner text; v_before jsonb; c public.league_corrections%rowtype; d record;
begin
  select * into g from public.league_games where id = p_game_id;
  if not found then raise exception 'no such game on any slate'; end if;
  if p_away is null or p_home is null or p_away < 0 or p_home < 0 then
    raise exception 'a corrected score is two non-negative integers';
  end if;
  v_winner := nullif(upper(trim(coalesce(p_winner,''))), '');
  if v_winner is not null and v_winner not in (g.away, g.home) then
    raise exception 'winner is %, %, or empty for a tie', g.away, g.home;
  end if;
  if char_length(trim(coalesce(p_note,''))) not between 8 and 500 then
    raise exception 'a correction carries a note: 8-500 characters';
  end if;

  select * into r from public.league_results where game_id = g.id;
  if found then
    v_before := jsonb_build_object('away_score', r.away_score, 'home_score', r.home_score, 'winner', r.winner);
    update public.league_results
      set away_score = p_away, home_score = p_home, winner = v_winner
      where game_id = g.id;
  else
    -- The CANC lane: recording a result the sweep will never bring.
    if now() < g.kickoff then raise exception 'cannot record a result before kickoff'; end if;
    v_before := jsonb_build_object('unrecorded', true);
    insert into public.league_results (game_id, away_score, home_score, winner)
    values (g.id, p_away, p_home, v_winner);
  end if;

  insert into public.league_corrections (kind, game_id, before, after, note, dispute_id)
  values ('game', g.id, v_before,
          jsonb_build_object('away_score', p_away, 'home_score', p_home, 'winner', v_winner),
          trim(p_note), p_dispute_id)
  returning * into c;
  perform public.ledger('result_corrected', null,
    jsonb_build_object('correction_id', c.id, 'game_id', g.id, 'before', v_before,
                       'after', c.after, 'note', c.note, 'dispute_id', p_dispute_id));

  -- Decision X2, now via C2: league_stamp_week is the ONLY place settled_at is
  -- written. A correction can complete a week exactly as a sweep can, and the
  -- carried-game predicate lives in one function instead of two copies that
  -- have to be kept in agreement by hand.
  perform public.league_stamp_week(g.season, g.week, 'correction');

  return json_build_object('ok', true, 'correction_id', c.id, 'game', g.away || ' @ ' || g.home,
                           'before', v_before, 'after', c.after);
end $$;

-- ---------------------------------------------------------------- the wall
-- New functions default to EXECUTE for PUBLIC; the house revokes and then
-- grants only what the edge function actually calls with the service role.
-- The replaced functions keep the grants they already had (create or replace
-- does not reset them). league_stamp_week and the two grading-window helpers
-- are internal: they are only ever called from inside other SECURITY DEFINER
-- functions, which run as the owner, so they need no grant of their own. It is
-- granted to service_role anyway as insurance: that reasoning only holds while
-- league_settle and league_stamp_week share an owner, and an owner mismatch
-- would surface as a permission error the first time a week tried to settle.
--
-- public.ledger is ledger(text, uuid, jsonb) and has exactly ONE overload
-- (verified against the shared arena migration that defines it), so the
-- untyped null second argument every call site passes resolves unambiguously.
revoke execute on function
  public.league_stamp_week(int, int, text),
  public.league_carry(text, text),
  public.league_settle_health(),
  public.league_sweep_failed(text),
  public.league_week_final_at(int, int),
  public.league_grading_closes_at(text),
  public.league_grading_final(text)
  from public, anon, authenticated;

grant execute on function
  public.league_carry(text, text),
  public.league_settle_health(),
  public.league_sweep_failed(text),
  public.league_stamp_week(int, int, text)
  to service_role;
