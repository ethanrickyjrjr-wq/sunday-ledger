-- ============================================================================
-- PROPS — the second card (dev brief to-do 2, built after incentives shipped)
--
-- A prop is a binary question bound to a slate game: player X OVER/UNDER a
-- house line. The pick is a side plus a probability, same 0.50-0.99 band, same
-- Brier arithmetic, same Wednesday freeze (min of the bound game's kickoff and
-- the week freeze — league_frozen reused verbatim). Lines come from the house
-- generator (scripts/props, nflverse data); settlement is Tuesday, from
-- nflverse weekly player stats, after Monday's stat corrections.
--
-- BUILD-TIME DECISIONS the brief does not rule, flagged in house style:
--
--   X. PROPS ARE OPT-IN EXTRAS. The main standings' denominator doctrine
--      (full slate, 0.5 defaults from your first week) was ratified for games
--      and is NOT touched: league_scores() and every surface built on it are
--      unchanged. Prop Brier is its own number over only the props you picked
--      — no defaults, no denominator. Skipping props costs nothing; playing
--      them builds a second public record.
--
--   V. A MISSING PLAYER IS A VOID, NOT A LOSS. If the bound game settled but
--      the player never appears in that week's stat file (inactive, DNP), the
--      prop voids — nobody is scored, like a tie (decision T). Lines end in
--      .5 so a push on a played prop is impossible.
--
--   L. A LINE WITH PICKS ON IT IS IMMUTABLE. Republishing before the freeze
--      updates only props nobody has touched; a prop with even one pick keeps
--      the line those picks were made against. After settle nothing moves.
--
--   G. PROPS SETTLE ONLY ON SETTLED GAMES. league_settle_props refuses to
--      score a prop whose game has no result row: stats without a final are a
--      data race, and Tuesday always has finals.
--
--   S2. PROP PICKS PUBLISH AT THE PROP'S SETTLE (decision S, transplanted):
--       immutable at freeze, private until the result row exists.
-- ============================================================================

-- ------------------------------------------------------------------- props
create table public.league_props (
  id           text primary key,          -- {season}_w{NN}_{gsis_id}_{market}
  season       int  not null,
  week         int  not null,
  game_id      text not null references public.league_games(id),
  gsis_id      text not null,             -- nflverse player id, the settle key
  player       text not null,
  team         text not null,             -- slate abbreviation (matches league_games)
  position     text not null,
  market       text not null,             -- pass_yds | pass_tds | rush_yds | carries | rec | rec_yds | any_td
  label        text not null,
  line         numeric(6,1) not null check (line = floor(line) + 0.5),
  published_at timestamptz not null default now(),
  foreign key (season, week) references public.league_weeks (season, week),
  unique (season, week, gsis_id, market)
);
create index league_props_week_idx on public.league_props (season, week);
create index league_props_game_idx on public.league_props (game_id);

-- -------------------------------------------------------------- prop picks
create table public.league_prop_picks (
  player_id   uuid not null references public.league_players(id),
  prop_id     text not null references public.league_props(id),
  side        text not null check (side in ('OVER', 'UNDER')),
  probability numeric(3,2) not null check (probability between 0.50 and 0.99),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (player_id, prop_id)
);
create index league_prop_picks_prop_idx on public.league_prop_picks (prop_id);

-- ------------------------------------------------------------ prop results
-- void = true means the player never played (decision V): actual and outcome
-- stay null and nobody is scored.
create table public.league_prop_results (
  prop_id    text primary key references public.league_props(id),
  actual     numeric,
  outcome    text check (outcome in ('OVER', 'UNDER')),
  void       boolean not null default false,
  settled_at timestamptz not null default now(),
  check (void = (outcome is null))
);

-- ========================================================= publishing props
-- House door. p_props: [{gsis_id, player, team, position, market, label, line}]
-- straight off the generator card. Each prop binds to the slate game its team
-- plays that week; a team not on the slate is returned as unmatched, never
-- guessed. Decision L guards updates.
create or replace function public.league_publish_props(p_season int, p_week int, p_props jsonb)
returns json
language plpgsql security definer set search_path = public as $$
declare
  pr jsonb; gid text; pid text; existing public.league_props%rowtype;
  n_ins int := 0; n_upd int := 0; n_kept int := 0;
  unmatched text[] := '{}';
begin
  if not exists (select 1 from public.league_weeks where season = p_season and week = p_week) then
    raise exception 'week % of % is not published — the slate comes first', p_week, p_season;
  end if;
  if p_props is null or jsonb_array_length(p_props) = 0 then
    raise exception 'no props in the body';
  end if;

  for pr in select * from jsonb_array_elements(p_props) loop
    select g.id into gid from public.league_games g
      where g.season = p_season and g.week = p_week
        and (g.away = upper(pr->>'team') or g.home = upper(pr->>'team'));
    if gid is null then
      unmatched := unmatched || (pr->>'player' || ' (' || (pr->>'team') || ')');
      continue;
    end if;
    pid := format('%s_w%s_%s_%s', p_season, lpad(p_week::text, 2, '0'),
                  pr->>'gsis_id', pr->>'market');
    select * into existing from public.league_props
      where season = p_season and week = p_week
        and gsis_id = pr->>'gsis_id' and market = pr->>'market';
    if found then
      -- Decision L: a prop with picks or a result keeps its line.
      if exists (select 1 from public.league_prop_picks pk where pk.prop_id = existing.id)
         or exists (select 1 from public.league_prop_results r where r.prop_id = existing.id) then
        n_kept := n_kept + 1;
      else
        update public.league_props
          set line = (pr->>'line')::numeric, label = pr->>'label', player = pr->>'player',
              team = upper(pr->>'team'), position = pr->>'position', game_id = gid
          where id = existing.id;
        n_upd := n_upd + 1;
      end if;
    else
      insert into public.league_props
        (id, season, week, game_id, gsis_id, player, team, position, market, label, line)
      values
        (pid, p_season, p_week, gid, pr->>'gsis_id', pr->>'player', upper(pr->>'team'),
         pr->>'position', pr->>'market', pr->>'label', (pr->>'line')::numeric);
      n_ins := n_ins + 1;
    end if;
  end loop;

  perform public.ledger('props_published', null,
    jsonb_build_object('season', p_season, 'week', p_week, 'inserted', n_ins,
                       'updated', n_upd, 'kept', n_kept, 'unmatched', to_jsonb(unmatched)));
  return json_build_object('ok', true, 'season', p_season, 'week', p_week,
                           'inserted', n_ins, 'updated', n_upd, 'kept', n_kept,
                           'unmatched', to_jsonb(unmatched));
end $$;

-- ================================================================ prop pick
create or replace function public.league_prop_pick(p_token text, p_prop_id text, p_side text, p_probability numeric)
returns json
language plpgsql security definer set search_path = public as $$
declare
  pl public.league_players%rowtype; pr public.league_props%rowtype; g public.league_games%rowtype;
begin
  pl := public.league_player(p_token);
  if pl.id is null then raise exception 'unknown token' using errcode = '42501'; end if;
  select * into pr from public.league_props where id = p_prop_id;
  if not found then raise exception 'no such prop on any card'; end if;
  select * into g from public.league_games where id = pr.game_id;
  if public.league_frozen(g) then
    raise exception 'frozen: % % is past the freeze. The Ledger remembers what you said on Wednesday.',
      pr.player, pr.label;
  end if;
  if exists (select 1 from public.league_prop_results r where r.prop_id = pr.id) then
    raise exception 'that prop already settled';
  end if;
  if p_side is null or upper(trim(p_side)) not in ('OVER', 'UNDER') then
    raise exception 'side must be OVER or UNDER';
  end if;
  if p_probability is null or p_probability < 0.50 or p_probability > 0.99 then
    raise exception 'probability is 0.50-0.99 on the side you picked. The Ledger does not sell certainty.';
  end if;
  insert into public.league_prop_picks (player_id, prop_id, side, probability)
  values (pl.id, pr.id, upper(trim(p_side)), round(p_probability, 2))
  on conflict (player_id, prop_id) do update
    set side = excluded.side, probability = excluded.probability, updated_at = now();
  return json_build_object('ok', true, 'prop', pr.player || ' ' || pr.label || ' o/u ' || pr.line,
    'side', upper(trim(p_side)), 'probability', round(p_probability, 2),
    'mutable_until', least(g.kickoff, (select freeze_at from public.league_weeks w
                                       where w.season = g.season and w.week = g.week)));
end $$;

-- ======================================================= prop scores (derived)
-- Mirrors league_scores() shape, but decision X: only picked, only settled,
-- never void, no defaults.
create or replace function public.league_prop_scores() returns table (
  player_id uuid, season int, week int, prop_id text, correct boolean, brier numeric
)
language sql stable security definer set search_path = public as $$
  select pk.player_id, pr.season, pr.week, pr.id,
         (pk.side = r.outcome) as correct,
         case when pk.side = r.outcome
              then power(1 - pk.probability, 2)
              else power(pk.probability, 2) end::numeric as brier
  from public.league_prop_picks pk
  join public.league_props pr on pr.id = pk.prop_id
  join public.league_prop_results r on r.prop_id = pr.id and not r.void;
$$;

-- ================================================================= the card
-- p_week null -> the latest week that has props. Lines are public product;
-- the field's picks on a prop show only once THAT prop settles (S2); your own
-- always show to your token. When any props have settled: per-player prop
-- Brier table for the week.
create or replace function public.league_props_json(p_token text default null, p_season int default null, p_week int default null)
returns json
language plpgsql stable security definer set search_path = public as $$
declare v_season int; v_week int; me public.league_players%rowtype; res json;
begin
  if p_season is null or p_week is null then
    select season, week into v_season, v_week
      from public.league_props order by season desc, week desc limit 1;
  else
    v_season := p_season; v_week := p_week;
  end if;
  if v_season is null or not exists (select 1 from public.league_props
                                     where season = v_season and week = v_week) then
    return json_build_object('props', null, 'note', 'no prop card yet for that week');
  end if;
  if p_token is not null then me := public.league_player(p_token); end if;

  select json_build_object(
    'season', v_season, 'week', v_week,
    'freeze_at', (select freeze_at from public.league_weeks lw
                  where lw.season = v_season and lw.week = v_week),
    'how', 'POST ?prop_pick {prop_id, side: OVER|UNDER, probability 0.50-0.99} until the freeze. Settles Tuesday from public stats; a player who never plays voids the prop. Prop Brier is its own table — skipping props never costs you.',
    'props', (
      select json_agg(json_build_object(
        'prop_id', pr.id, 'player', pr.player, 'team', pr.team, 'position', pr.position,
        'market', pr.market, 'label', pr.label, 'line', pr.line,
        'game', g.away || ' @ ' || g.home, 'kickoff', g.kickoff,
        'frozen', public.league_frozen(g),
        'result', (select json_build_object('actual', r.actual, 'outcome', r.outcome, 'void', r.void)
                   from public.league_prop_results r where r.prop_id = pr.id),
        'my_pick', case when me.id is not null then
          (select json_build_object('side', pk.side, 'probability', pk.probability)
           from public.league_prop_picks pk where pk.prop_id = pr.id and pk.player_id = me.id) end,
        'picks', case when exists (select 1 from public.league_prop_results r where r.prop_id = pr.id) then
          (select json_agg(json_build_object('handle', pl.handle, 'side', pk.side,
                    'probability', pk.probability, 'registered_at', pk.updated_at) order by pk.updated_at)
           from public.league_prop_picks pk join public.league_players pl on pl.id = pk.player_id
           where pk.prop_id = pr.id) end
      ) order by pr.team, case pr.position when 'QB' then 0 when 'RB' then 1 when 'FB' then 1
                                           when 'WR' then 2 when 'TE' then 3 else 9 end,
                 pr.player, pr.market)
      from public.league_props pr join public.league_games g on g.id = pr.game_id
      where pr.season = v_season and pr.week = v_week
    ),
    'prop_briers', case when exists (select 1 from public.league_prop_results r
                                     join public.league_props pr on pr.id = r.prop_id
                                     where pr.season = v_season and pr.week = v_week) then (
      select json_agg(json_build_object('handle', pl.handle, 'brier', t.brier, 'record', t.rec)
                      order by t.brier asc)
      from (
        select s.player_id, round(avg(s.brier), 4) as brier,
               count(*) filter (where s.correct) || '-' || count(*) filter (where not s.correct) as rec
        from public.league_prop_scores() s
        where s.season = v_season and s.week = v_week
        group by s.player_id
      ) t join public.league_players pl on pl.id = t.player_id
    ) end
  ) into res;
  return res;
end $$;

-- ================================================================= settling
-- Tuesday's door. p_actuals: [{gsis_id, market, actual}] computed by the edge
-- function from the nflverse weekly stat file. Decision G: a prop only settles
-- once its game carries a result. Decision V: a played game with no stat row
-- for the player is a void.
create or replace function public.league_settle_props(p_season int, p_week int, p_actuals jsonb)
returns json
language plpgsql security definer set search_path = public as $$
declare
  pr record; act numeric; n_set int := 0; n_void int := 0; n_wait int := 0;
begin
  for pr in select p.* from public.league_props p
            where p.season = p_season and p.week = p_week
              and not exists (select 1 from public.league_prop_results r where r.prop_id = p.id)
  loop
    if not exists (select 1 from public.league_results gr where gr.game_id = pr.game_id) then
      n_wait := n_wait + 1;
      continue;
    end if;
    select (a->>'actual')::numeric into act
      from jsonb_array_elements(p_actuals) a
      where a->>'gsis_id' = pr.gsis_id and a->>'market' = pr.market;
    if act is null then
      insert into public.league_prop_results (prop_id, void) values (pr.id, true);
      n_void := n_void + 1;
    else
      insert into public.league_prop_results (prop_id, actual, outcome)
      values (pr.id, act, case when act > pr.line then 'OVER' else 'UNDER' end);
      n_set := n_set + 1;
    end if;
  end loop;
  perform public.ledger('props_settled', null,
    jsonb_build_object('season', p_season, 'week', p_week,
                       'settled', n_set, 'voided', n_void, 'awaiting_game', n_wait));
  return json_build_object('ok', true, 'settled', n_set, 'voided', n_void, 'awaiting_game', n_wait);
end $$;

-- ============================================================= the leak wall
alter table public.league_props        enable row level security;
alter table public.league_prop_picks   enable row level security;
alter table public.league_prop_results enable row level security;

revoke all on public.league_props, public.league_prop_picks, public.league_prop_results
  from public, anon, authenticated;

revoke execute on function
  public.league_publish_props(int, int, jsonb),
  public.league_prop_pick(text, text, text, numeric),
  public.league_prop_scores(),
  public.league_props_json(text, int, int),
  public.league_settle_props(int, int, jsonb)
  from public, anon, authenticated;

grant execute on function
  public.league_publish_props(int, int, jsonb),
  public.league_prop_pick(text, text, text, numeric),
  public.league_props_json(text, int, int),
  public.league_settle_props(int, int, jsonb)
  to service_role;
