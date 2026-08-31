-- ============================================================================
-- THE DOCKET + TURN OF THE WEEK (rulebook §6/§7/§8, artifact revision read
-- 2026-08-31 — closes every policy-ahead-of-code promise on the /rules page)
--
-- §6: coverage_rate and the traveling-claim block join the public player card.
-- §7: corrections are APPENDED to a league-owned public docket, never silently
--     rewritten; every grading is disputable for 72 hours after its week
--     settles, then the week is final; no standing required; every dispute
--     gets a written published ruling; overturns credit the disputant by name
--     forever and count on their card.
-- §8: Turn of the Week — a player credits whoever flipped their pick, before
--     the freeze; the credit seals with the pick and unseals at settle; the
--     desk stamps one per week; the outcome is derived at read, never stamped.
--
-- BUILD-TIME DECISIONS the rulebook does not rule, flagged in house style:
--
--   F. FINAL = 72h AFTER SETTLE *AND* A CLEAR DOCKET. "Every dispute gets a
--      written ruling before the week finalizes" is enforced structurally: an
--      open dispute keeps its week from finalizing, so a dispute filed at hour
--      71 can still be ruled honestly at hour 80. FILING closes at exactly
--      settled_at + 72h — disputes cannot chain the window open forever.
--   G2. PROPS RUN THEIR OWN CLOCK. Props settle Tuesday, after the game week;
--      a prop's 72h runs from its own result's settled_at, not the week's.
--   C2. CORRECTIONS GO THROUGH ONE INTERNAL WORKER per kind. The house door
--      checks finality; the ruling door skips it (decision F already holds the
--      week open) — both append the same correction row. The workers are
--      granted to nobody, not even service_role.
--   X2. THE CANC LANE. A cancelled game never gets a result row from the sweep
--      and would hold its week unsettled forever (known open issue). The
--      correction worker may INSERT a result for a game past kickoff —
--      winner null = push, before = {"unrecorded": true} — and then stamps the
--      week itself, because the sweep gate cannot fire once nothing is missing.
--   S2. A TURN IS SEALED LIKE A PICK. No ledger event at credit time (the
--      club ledger is a live feed); the credit becomes visible exactly when
--      the game's picks do. Your own credit shows to your token always.
--   T2. YOU CANNOT TURN YOURSELF, and the credit requires a registered pick —
--      "the credit seals with your pick" read literally. credited_to is free
--      text: you do not need to be a player to turn one.
-- ============================================================================

-- ------------------------------------------------------------------ disputes
create table public.league_disputes (
  id         uuid primary key default gen_random_uuid(),
  disputant  uuid not null references public.league_players(id),
  kind       text not null check (kind in ('game','prop')),
  game_id    text references public.league_games(id),
  prop_id    text references public.league_props(id),
  graded     text not null check (char_length(graded)  between 8 and 300),
  evidence   text not null check (char_length(evidence) between 8 and 300),
  source_url text not null check (source_url ~* '^https?://[^ ]{4,300}$'),
  filed_at   timestamptz not null default now(),
  ruling     text check (ruling in ('upheld','overturned')),  -- null = open
  ruling_note text,
  ruled_at   timestamptz,
  check ((kind = 'game') = (game_id is not null)),
  check ((kind = 'prop') = (prop_id is not null))
);
create unique index league_disputes_open_game_idx
  on public.league_disputes (disputant, game_id) where ruling is null and game_id is not null;
create unique index league_disputes_open_prop_idx
  on public.league_disputes (disputant, prop_id) where ruling is null and prop_id is not null;

-- --------------------------------------------------------------- corrections
-- The appended ledger. Nothing in this schema updates or deletes a row here.
create table public.league_corrections (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('game','prop')),
  game_id      text references public.league_games(id),
  prop_id      text references public.league_props(id),
  before       jsonb not null,
  after        jsonb not null,
  note         text not null check (char_length(note) between 8 and 500),
  dispute_id   uuid references public.league_disputes(id),  -- set = an overturn, credited
  corrected_at timestamptz not null default now(),
  check ((kind = 'game') = (game_id is not null)),
  check ((kind = 'prop') = (prop_id is not null))
);

-- --------------------------------------------------------------------- turns
create table public.league_turns (
  player_id    uuid not null references public.league_players(id),
  game_id      text not null references public.league_games(id),
  credited_to  text not null check (char_length(credited_to) between 2 and 64),
  argument_url text check (argument_url ~* '^https?://[^ ]{4,300}$'),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (player_id, game_id)
);

-- One stamp per settled week: the desk's pick for the best documented public
-- argument that flipped a frozen pick. Outcome is derived at read (winner /
-- loser / push), never stamped — derived-not-stamped doctrine.
create table public.league_turn_stamps (
  season     int  not null,
  week       int  not null,
  player_id  uuid not null,
  game_id    text not null,
  note       text check (char_length(note) <= 300),
  stamped_at timestamptz not null default now(),
  primary key (season, week),
  foreign key (season, week) references public.league_weeks (season, week),
  foreign key (player_id, game_id) references public.league_turns (player_id, game_id)
);

-- ==================================================================== finality
-- Decision F: settled + 72h elapsed + no open dispute anywhere in the week.
create or replace function public.league_week_final(p_season int, p_week int) returns boolean
language sql stable security definer set search_path = public as $$
  select w.settled_at is not null
     and now() >= w.settled_at + interval '72 hours'
     and not exists (
       select 1 from public.league_disputes d
       left join public.league_games g on g.id = d.game_id
       left join public.league_props  pr on pr.id = d.prop_id
       where d.ruling is null
         and coalesce(g.season, pr.season) = w.season
         and coalesce(g.week,   pr.week)   = w.week)
  from public.league_weeks w where w.season = p_season and w.week = p_week;
$$;

-- ============================================================ filing a dispute
-- Any player, any grading — standing is not required (§7). A dispute names the
-- pick, what the ledger graded, and what the evidence says, with a source.
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
    if w.settled_at is not null and now() >= w.settled_at + interval '72 hours' then
      raise exception 'the docket closed at % — the week is final', w.settled_at + interval '72 hours';
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
  if coalesce(p_source_url,'') !~* '^https?://[^ ]{4,300}$' then
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

-- ======================================== correction workers (decision C2)
-- Granted to nobody. All windows are checked by the callers; these only do the
-- write, the append, the ledger note, and (games) the week stamp (decision X2).
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

  -- Decision X2: stamp the week if this write completed it (league_settle's
  -- own loop, scoped to this game's week — the sweep gate cannot fire now).
  if exists (select 1 from public.league_weeks w
             where w.season = g.season and w.week = g.week and w.settled_at is null)
     and not exists (select 1 from public.league_games g2
                     left join public.league_results res on res.game_id = g2.id
                     where g2.season = g.season and g2.week = g.week and res.game_id is null) then
    update public.league_weeks set settled_at = now() where season = g.season and week = g.week;
    perform public.ledger('week_settled', null,
      jsonb_build_object('season', g.season, 'week', g.week, 'via', 'correction'));
    for d in select s.player_id, s.game_id as gid, pl.handle
             from public.league_scores() s
             join public.league_players pl on pl.id = s.player_id
             where s.season = g.season and s.week = g.week and not s.picked loop
      perform public.ledger('pick_defaulted', null,
        jsonb_build_object('season', g.season, 'week', g.week, 'player_id', d.player_id,
                           'handle', d.handle, 'game_id', d.gid, 'as', 0.5));
    end loop;
  end if;

  return json_build_object('ok', true, 'correction_id', c.id, 'game', g.away || ' @ ' || g.home,
                           'before', v_before, 'after', c.after);
end $$;

create or replace function public.league_apply_prop_correction(
  p_prop_id text, p_actual numeric, p_void boolean, p_note text, p_dispute_id uuid
) returns json
language plpgsql security definer set search_path = public as $$
declare
  pr public.league_props%rowtype; r public.league_prop_results%rowtype;
  v_before jsonb; v_after jsonb; c public.league_corrections%rowtype;
begin
  select * into pr from public.league_props where id = p_prop_id;
  if not found then raise exception 'no such prop on any card'; end if;
  select * into r from public.league_prop_results where prop_id = pr.id;
  if not found then raise exception 'that prop has not settled — corrections amend gradings, they do not create them'; end if;
  if char_length(trim(coalesce(p_note,''))) not between 8 and 500 then
    raise exception 'a correction carries a note: 8-500 characters';
  end if;
  if not coalesce(p_void, false) and p_actual is null then
    raise exception 'a prop correction is either an actual or a void';
  end if;

  v_before := jsonb_build_object('actual', r.actual, 'outcome', r.outcome, 'void', r.void);
  if coalesce(p_void, false) then
    update public.league_prop_results
      set actual = null, outcome = null, void = true where prop_id = pr.id;
    v_after := jsonb_build_object('actual', null, 'outcome', null, 'void', true);
  else
    update public.league_prop_results
      set actual = p_actual,
          outcome = case when p_actual > pr.line then 'OVER' else 'UNDER' end,
          void = false
      where prop_id = pr.id;
    v_after := jsonb_build_object('actual', p_actual,
      'outcome', case when p_actual > pr.line then 'OVER' else 'UNDER' end, 'void', false);
  end if;

  insert into public.league_corrections (kind, prop_id, before, after, note, dispute_id)
  values ('prop', pr.id, v_before, v_after, trim(p_note), p_dispute_id)
  returning * into c;
  perform public.ledger('result_corrected', null,
    jsonb_build_object('correction_id', c.id, 'prop_id', pr.id, 'before', v_before,
                       'after', v_after, 'note', c.note, 'dispute_id', p_dispute_id));
  return json_build_object('ok', true, 'correction_id', c.id, 'prop', pr.label,
                           'before', v_before, 'after', v_after);
end $$;

-- ================================================== the house doors (unlinked)
-- A source-corrected score with no dispute attached. Refused once final.
create or replace function public.league_correct_game(
  p_game_id text, p_away int, p_home int, p_winner text, p_note text
) returns json
language plpgsql security definer set search_path = public as $$
declare g public.league_games%rowtype;
begin
  select * into g from public.league_games where id = p_game_id;
  if not found then raise exception 'no such game on any slate'; end if;
  if public.league_week_final(g.season, g.week) then
    raise exception 'week % of % is final — the docket is closed', g.week, g.season;
  end if;
  return public.league_apply_game_correction(p_game_id, p_away, p_home, p_winner, p_note, null);
end $$;

create or replace function public.league_correct_prop(
  p_prop_id text, p_actual numeric, p_void boolean, p_note text
) returns json
language plpgsql security definer set search_path = public as $$
declare r public.league_prop_results%rowtype;
begin
  select * into r from public.league_prop_results where prop_id = p_prop_id;
  if found and now() >= r.settled_at + interval '72 hours'
     and not exists (select 1 from public.league_disputes d
                     where d.prop_id = p_prop_id and d.ruling is null) then
    raise exception 'that grading is final — the docket is closed';
  end if;
  return public.league_apply_prop_correction(p_prop_id, p_actual, p_void, p_note, null);
end $$;

-- =========================================================== the written ruling
-- One atomic door: upheld stamps the reasoning; overturned applies the
-- correction (decision C2 worker, dispute_id attached — the by-name credit)
-- and then stamps. Ruling an open dispute is always allowed (decision F).
create or replace function public.league_dispute_rule(
  p_dispute_id uuid, p_ruling text, p_note text, p_correction jsonb default null
) returns json
language plpgsql security definer set search_path = public as $$
declare d public.league_disputes%rowtype; applied json;
begin
  select * into d from public.league_disputes where id = p_dispute_id for update;
  if not found then raise exception 'no such dispute on the docket'; end if;
  if d.ruling is not null then raise exception 'that dispute is already ruled: %', d.ruling; end if;
  if p_ruling not in ('upheld','overturned') then
    raise exception 'a ruling is upheld or overturned';
  end if;
  if char_length(trim(coalesce(p_note,''))) not between 8 and 500 then
    raise exception 'every dispute gets a WRITTEN ruling: 8-500 characters of reasoning';
  end if;

  if p_ruling = 'overturned' then
    if p_correction is null then
      raise exception 'an overturn names the correction: {away_score,home_score,winner} or {actual}|{void}';
    end if;
    if d.kind = 'game' then
      applied := public.league_apply_game_correction(d.game_id,
        (p_correction->>'away_score')::int, (p_correction->>'home_score')::int,
        p_correction->>'winner', trim(p_note), d.id);
    else
      applied := public.league_apply_prop_correction(d.prop_id,
        (p_correction->>'actual')::numeric, coalesce((p_correction->>'void')::boolean, false),
        trim(p_note), d.id);
    end if;
  end if;

  update public.league_disputes
    set ruling = p_ruling, ruling_note = trim(p_note), ruled_at = now()
    where id = d.id;
  perform public.ledger('dispute_ruled', null,
    jsonb_build_object('dispute_id', d.id, 'ruling', p_ruling, 'note', trim(p_note),
                       'kind', d.kind, 'game_id', d.game_id, 'prop_id', d.prop_id));
  return json_build_object('ok', true, 'dispute_id', d.id, 'ruling', p_ruling,
                           'correction', applied);
end $$;

-- =========================================================== crediting a turn
create or replace function public.league_turn_credit(
  p_token text, p_game_id text, p_credited_to text, p_argument_url text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare
  me public.league_players%rowtype; g public.league_games%rowtype;
  v_credit text; v_url text;
begin
  me := public.league_player(p_token);
  if me.id is null then raise exception 'unknown token' using errcode = '42501'; end if;
  select * into g from public.league_games where id = p_game_id;
  if not found then raise exception 'no such game on any slate'; end if;
  if public.league_frozen(g) then
    raise exception 'frozen: the credit seals with your pick, and both are already sealed';
  end if;
  if not exists (select 1 from public.league_picks p
                 where p.player_id = me.id and p.game_id = g.id) then
    raise exception 'the credit seals with your pick — register the pick first';
  end if;
  v_credit := trim(coalesce(p_credited_to, ''));
  if char_length(v_credit) not between 2 and 64 then
    raise exception 'credited_to: 2-64 characters naming who turned you';
  end if;
  if lower(v_credit) = lower(me.handle) then
    raise exception 'only the turned can award it — and you cannot turn yourself';
  end if;
  v_url := nullif(trim(coalesce(p_argument_url, '')), '');
  if v_url is not null and v_url !~* '^https?://[^ ]{4,300}$' then
    raise exception 'argument_url, when given, is a link to the argument that turned you';
  end if;

  insert into public.league_turns (player_id, game_id, credited_to, argument_url)
  values (me.id, g.id, v_credit, v_url)
  on conflict (player_id, game_id) do update
    set credited_to = excluded.credited_to, argument_url = excluded.argument_url,
        updated_at = now();
  -- Decision S2: no ledger event — a turn is sealed like the pick it rides.
  return json_build_object('ok', true, 'game', g.away || ' @ ' || g.home,
    'credited_to', v_credit,
    'sealed', 'the credit seals with your pick and unseals at settle. Your Brier stays yours — persuasion is recognition, never scoring.');
end $$;

-- ===================================================== stamping Turn of the Week
create or replace function public.league_stamp_turn(
  p_season int, p_week int, p_handle text, p_game_id text, p_note text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare w public.league_weeks%rowtype; pl public.league_players%rowtype; t public.league_turns%rowtype;
begin
  select * into w from public.league_weeks where season = p_season and week = p_week;
  if not found or w.settled_at is null then raise exception 'the stamp lands at settle — that week has not'; end if;
  select * into pl from public.league_players where handle = trim(coalesce(p_handle,''));
  if not found then raise exception 'no such player'; end if;
  select * into t from public.league_turns where player_id = pl.id and game_id = p_game_id;
  if not found then raise exception '% credited no turn on that game', pl.handle; end if;
  if not exists (select 1 from public.league_games g
                 where g.id = p_game_id and g.season = p_season and g.week = p_week) then
    raise exception 'that game is not on week % of %', p_week, p_season;
  end if;
  insert into public.league_turn_stamps (season, week, player_id, game_id, note)
  values (p_season, p_week, pl.id, p_game_id, nullif(trim(coalesce(p_note,'')), ''));
  perform public.ledger('turn_of_week', null,
    jsonb_build_object('season', p_season, 'week', p_week, 'handle', pl.handle,
                       'credited_to', t.credited_to, 'game_id', p_game_id));
  return json_build_object('ok', true, 'season', p_season, 'week', p_week,
                           'handle', pl.handle, 'credited_to', t.credited_to);
exception when unique_violation then
  raise exception 'week % of % already has its Turn of the Week', p_week, p_season;
end $$;

-- ============================================================== the public docket
create or replace function public.league_docket_json() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'window', 'Every grading is disputable for 72 hours after its week settles; then the week is final. Standing is not required. Corrections are appended, never rewritten.',
    'disputes', coalesce((
      select json_agg(json_build_object(
        'dispute_id', d.id,
        'handle', pl.handle,
        'kind', d.kind,
        'target', case when d.kind = 'game'
                       then g.away || ' @ ' || g.home || ' (' || g.season || ' w' || g.week || ')'
                       else pr.label || ' ' || pr.line || ' (' || pr.season || ' w' || pr.week || ')' end,
        'game_id', d.game_id, 'prop_id', d.prop_id,
        'graded', d.graded, 'evidence', d.evidence, 'source_url', d.source_url,
        'filed_at', d.filed_at,
        'status', coalesce(d.ruling, 'open'),
        'ruling_note', d.ruling_note, 'ruled_at', d.ruled_at
      ) order by d.filed_at desc)
      from public.league_disputes d
      join public.league_players pl on pl.id = d.disputant
      left join public.league_games g on g.id = d.game_id
      left join public.league_props pr on pr.id = d.prop_id
    ), '[]'::json),
    'corrections', coalesce((
      select json_agg(json_build_object(
        'correction_id', c.id,
        'kind', c.kind,
        'target', case when c.kind = 'game'
                       then g.away || ' @ ' || g.home || ' (' || g.season || ' w' || g.week || ')'
                       else pr.label || ' ' || pr.line || ' (' || pr.season || ' w' || pr.week || ')' end,
        'game_id', c.game_id, 'prop_id', c.prop_id,
        'before', c.before, 'after', c.after, 'note', c.note,
        'corrected_at', c.corrected_at,
        'overturn_credit', dpl.handle
      ) order by c.corrected_at desc)
      from public.league_corrections c
      left join public.league_games g on g.id = c.game_id
      left join public.league_props pr on pr.id = c.prop_id
      left join public.league_disputes dd on dd.id = c.dispute_id
      left join public.league_players dpl on dpl.id = dd.disputant
    ), '[]'::json)
  );
$$;

-- ========================================= the public card, amended (§6 + §7 + §8)
-- Incentives-migration body with four additions: coverage_rate in `record`,
-- the traveling_claim block, the overturns count, and the turn surfaces
-- (settled games only — a turn is sealed like the pick it rides, decision S2).
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

-- ================================================ the week, amended (§7 + §8)
-- Base-migration body with: final_at + final (decision F), per-game turns
-- revealed exactly as picks are (decision S / S2), my_turn to your own token,
-- turn_of_week when settled, and the week's corrections appended in the open.
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
    'final_at', w.settled_at + interval '72 hours',
    'final', public.league_week_final(w.season, w.week),
    'main_card', to_jsonb(w.main_card),
    'games', (
      select json_agg(json_build_object(
        'game_id', g.id, 'kickoff', g.kickoff,
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

-- ============================================================= the leak wall
alter table public.league_disputes    enable row level security;
alter table public.league_corrections enable row level security;
alter table public.league_turns       enable row level security;
alter table public.league_turn_stamps enable row level security;

revoke all on public.league_disputes, public.league_corrections,
              public.league_turns, public.league_turn_stamps
  from public, anon, authenticated;

revoke execute on function
  public.league_week_final(int, int),
  public.league_dispute_file(text, text, text, text, text, text),
  public.league_apply_game_correction(text, int, int, text, text, uuid),
  public.league_apply_prop_correction(text, numeric, boolean, text, uuid),
  public.league_correct_game(text, int, int, text, text),
  public.league_correct_prop(text, numeric, boolean, text),
  public.league_dispute_rule(uuid, text, text, jsonb),
  public.league_turn_credit(text, text, text, text),
  public.league_stamp_turn(int, int, text, text, text),
  public.league_docket_json()
  from public, anon, authenticated;

-- Decision C2: the apply_* workers are granted to NOBODY — reachable only
-- through the checked doors below, which run as their definer.
grant execute on function
  public.league_dispute_file(text, text, text, text, text, text),
  public.league_correct_game(text, int, int, text, text),
  public.league_correct_prop(text, numeric, boolean, text),
  public.league_dispute_rule(uuid, text, text, jsonb),
  public.league_turn_credit(text, text, text, text),
  public.league_stamp_turn(int, int, text, text, text),
  public.league_docket_json()
  to service_role;
