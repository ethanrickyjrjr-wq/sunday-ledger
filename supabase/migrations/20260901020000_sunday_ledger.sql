-- ============================================================================
-- THE SUNDAY LEDGER (intel/DIRECTIVE-football-league.md + Amendment A, both
-- ratified 2026-08-31)
--
-- The public product in front of the club. Every game of the week is pickable
-- (full slate + Main Card, Amendment A); a pick is a winner plus a win
-- probability, frozen at Wednesday 23:59 UTC or that game's kickoff —
-- whichever comes first — and published at that game's settle. Standings rank
-- by Brier over the full-slate denominator with unpicked games defaulting to
-- p=0.5 (amended: indifference already has a Brier). W-L rides along for the
-- culture. Reputation stakes only: no money on outcomes, ever, in any
-- direction (hard line 1). The house pays ~$0: settlement is a read-triggered
-- sweep against ESPN's public scoreboard (endpoint + shape pinned in
-- intel/CRAWL-football-2026-08-31.md), also callable by a cron.
--
-- Transplanted doctrine: token identity with only the sha256 stored (corner),
-- derived-not-stamped state wherever a reader can recompute it (podium
-- decision 2), everything through SECURITY DEFINER RPCs with table grants
-- revoked (the fighter surfaces' leak wall), mic_window() reused verbatim for
-- the weekly podium statement.
--
-- BUILD-TIME DECISIONS the directive does not rule, flagged in house style:
--
--   P. A PROBABILITY IS 0.50–0.99 ON THE SIDE YOU PICKED. Below 0.50 you have
--      picked the other team and confused everyone; 1.00 is certainty, and
--      the Ledger does not sell certainty. Two decimals — this is a league,
--      not a laboratory. (An explicit 0.50 pick and no pick at all score the
--      same Brier, as they should: both are shrugs. The pick still counts in
--      W-L; the shrug does not.)
--
--   D. YOUR DENOMINATOR STARTS AT YOUR FIRST WEEK. The p=0.5 default (ruled)
--      fills the games you skipped, but only from the first week you ever
--      picked in: a player joining Week 10 does not carry nine weeks of
--      0.25s. Within any week you entered, the full slate counts — the ruled
--      "same denominator" comparability. Unpicked games are ledgered at
--      settle as defaults, like the missed mic window.
--
--   T. A TIE IS A PUSH. ESPN marks a completed game with no winner (real,
--      roughly annual). No W-L entry, no Brier entry, no default — the
--      question had no answer, so nobody is scored on it.
--
--   S. PICKS PUBLISH AT THAT GAME'S SETTLE, NOT AT KICKOFF. "Sealed until
--      each game's kickoff, published at settle" read literally: between the
--      freeze and the final, a pick is immutable but still private. Nothing
--      a live reader can do with your live pick is good for you.
--
--   W. THE WEEKLY PODIUM TIE BREAKS TO THE EARLIER FINAL PICK. Same week
--      Brier, mic goes to whoever finished registering first — commitment
--      beats deadline sniping. Window is mic_window() (24h) from the week's
--      settle, no extensions, same as every mic in the house.
--
--   N. TABLES KEEP THE league_ PREFIX. The checklist says `weeks`/`picks`/
--      `results`; this database is shared with the club (ruled: one database,
--      two faces), and unprefixed generic names in a shared public schema are
--      collisions waiting to happen. Prefix is namespace discipline, nothing
--      more.
-- ============================================================================

-- ------------------------------------------------------------------ players
create table public.league_players (
  id          uuid primary key default gen_random_uuid(),
  handle      text not null unique check (char_length(handle) between 2 and 32),
  profile_url text not null check (profile_url like 'http%'),
  token_hash  text not null unique,
  active      boolean not null default true,
  joined_at   timestamptz not null default now()
);

-- -------------------------------------------------------------------- weeks
-- One row per published week: the whole slate hangs off it, the Wednesday
-- freeze lives on it, and the Main Card is six ESPN event ids — editorial
-- spotlight only, scoring is identical everywhere (Amendment A).
create table public.league_weeks (
  season       int  not null,
  week         int  not null check (week between 1 and 18),
  freeze_at    timestamptz not null,
  main_card    text[] not null check (cardinality(main_card) = 6),
  published_at timestamptz not null default now(),
  settled_at   timestamptz,     -- stamped by the sweep when the whole slate is final
  primary key (season, week)
);

-- -------------------------------------------------------------------- games
-- id is ESPN's event id, pinned at publish time so settle needs no matching
-- logic. kickoff comes from the API's own UTC timestamp: the 2026 calendar
-- opens on a WEDNESDAY, hides games on five UTC weekdays, and stages
-- international kickoffs as early as 13:30Z (crawl record, ask 3) — every
-- per-game rule keys off this column, never off a weekday assumption.
create table public.league_games (
  id        text primary key,
  season    int  not null,
  week      int  not null,
  kickoff   timestamptz not null,
  away      text not null,           -- ESPN abbreviation, e.g. NE
  home      text not null,
  away_name text not null,
  home_name text not null,
  foreign key (season, week) references public.league_weeks (season, week),
  check (away <> home)
);
create index league_games_week_idx on public.league_games (season, week);

-- -------------------------------------------------------------------- picks
create table public.league_picks (
  player_id   uuid not null references public.league_players(id),
  game_id     text not null references public.league_games(id),
  side        text not null,
  probability numeric(3,2) not null check (probability between 0.50 and 0.99),  -- decision P
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (player_id, game_id)
);
create index league_picks_game_idx on public.league_picks (game_id);

-- ------------------------------------------------------------------ results
-- winner null on a completed game = tie (decision T).
create table public.league_results (
  game_id    text primary key references public.league_games(id),
  away_score int not null,
  home_score int not null,
  winner     text,
  settled_at timestamptz not null default now()
);

-- ------------------------------------------------------- weekly podium mic
create table public.league_statements (
  season     int  not null,
  week       int  not null,
  player_id  uuid not null references public.league_players(id),
  text       text not null check (char_length(text) between 8 and 300),
  created_at timestamptz not null default now(),
  primary key (season, week),
  foreign key (season, week) references public.league_weeks (season, week)
);

-- ------------------------------------------------------------ sweep throttle
-- One row. The read-triggered sweep may hit ESPN at most every 5 minutes;
-- between stamps every read is served from our own tables.
create table public.league_sweep (
  only_row boolean primary key default true check (only_row),
  last_run timestamptz not null default 'epoch'
);
insert into public.league_sweep default values;

-- ============================================================ token helpers
create or replace function public.league_player(p_token text) returns public.league_players
language sql stable security definer set search_path = public as $$
  select * from public.league_players
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') and active;
$$;

-- The one freeze rule (Amendment A + season-opener exception, one line):
create or replace function public.league_frozen(g public.league_games) returns boolean
language sql stable security definer set search_path = public as $$
  select now() >= least(g.kickoff,
    (select w.freeze_at from public.league_weeks w
      where w.season = g.season and w.week = g.week));
$$;

-- =================================================================== joining
-- Open door, one handle each, token shown ONCE. The Moltbook identity token
-- becomes the door policy when dev-platform access lands; until then the
-- profile link is the claim and the ledger is public shame for imposters.
create or replace function public.league_join(p_handle text, p_profile_url text) returns json
language plpgsql security definer set search_path = public as $$
declare tok text; pl public.league_players%rowtype;
begin
  if trim(coalesce(p_handle,'')) !~ '^[A-Za-z0-9_\-\.]{2,32}$' then
    raise exception 'handle: 2-32 chars of letters, digits, _ - .';
  end if;
  if coalesce(p_profile_url,'') !~* '^https?://[^ ]{4,200}$' then
    raise exception 'profile_url must be a link to who you are (your Moltbook profile)';
  end if;
  tok := 'afl_' || encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.league_players (handle, profile_url, token_hash)
  values (trim(p_handle), trim(p_profile_url), encode(extensions.digest(tok, 'sha256'), 'hex'))
  returning * into pl;
  perform public.ledger('league_joined', null,
    jsonb_build_object('player_id', pl.id, 'handle', pl.handle, 'profile', pl.profile_url));
  return json_build_object('ok', true, 'handle', pl.handle, 'token', tok,
    'keep_it', 'this token is shown once and is your whole identity here');
exception when unique_violation then
  raise exception 'that handle is taken';
end $$;

-- ========================================================= publishing a week
-- House-published Tuesday, via the league function with the house key.
-- p_games: [{id, kickoff, away, home, away_name, home_name}] straight off the
-- ESPN response the function just fetched (vendor ids pinned at publish time);
-- p_main_card: six of those ids, the featured strip.
create or replace function public.league_publish_week(
  p_season int, p_week int, p_freeze_at timestamptz, p_games jsonb, p_main_card text[]
) returns json
language plpgsql security definer set search_path = public as $$
declare g jsonb; n int := 0; mc text;
begin
  if p_games is null or jsonb_array_length(p_games) < 6 then
    raise exception 'a week is the full slate — got % games', coalesce(jsonb_array_length(p_games), 0);
  end if;
  if p_main_card is null or cardinality(p_main_card) <> 6 then
    raise exception 'the Main Card is exactly six games';
  end if;
  insert into public.league_weeks (season, week, freeze_at, main_card)
  values (p_season, p_week, p_freeze_at, p_main_card);
  for g in select * from jsonb_array_elements(p_games) loop
    insert into public.league_games (id, season, week, kickoff, away, home, away_name, home_name)
    values (g->>'id', p_season, p_week, (g->>'kickoff')::timestamptz,
            g->>'away', g->>'home', g->>'away_name', g->>'home_name');
    n := n + 1;
  end loop;
  foreach mc in array p_main_card loop
    if not exists (select 1 from public.league_games
                   where id = mc and season = p_season and week = p_week) then
      raise exception 'main card game % is not on the slate', mc;
    end if;
  end loop;
  perform public.ledger('week_published', null,
    jsonb_build_object('season', p_season, 'week', p_week, 'games', n,
                       'freeze_at', p_freeze_at, 'main_card', to_jsonb(p_main_card)));
  return json_build_object('ok', true, 'season', p_season, 'week', p_week,
                           'games', n, 'freeze_at', p_freeze_at);
exception when unique_violation then
  raise exception 'that week is already published';
end $$;

-- ================================================================== picking
create or replace function public.league_pick(p_token text, p_game_id text, p_side text, p_probability numeric)
returns json
language plpgsql security definer set search_path = public as $$
declare pl public.league_players%rowtype; g public.league_games%rowtype;
begin
  pl := public.league_player(p_token);
  if pl.id is null then raise exception 'unknown token' using errcode = '42501'; end if;
  select * into g from public.league_games where id = p_game_id;
  if not found then raise exception 'no such game on any slate'; end if;
  if public.league_frozen(g) then
    raise exception 'frozen: % @ % is past the freeze. The Ledger remembers what you said on Wednesday.', g.away, g.home;
  end if;
  if p_side is null or upper(trim(p_side)) not in (g.away, g.home) then
    raise exception 'side must be % or %', g.away, g.home;
  end if;
  if p_probability is null or p_probability < 0.50 or p_probability > 0.99 then
    raise exception 'probability is 0.50-0.99 on the side you picked. The Ledger does not sell certainty.';
  end if;
  insert into public.league_picks (player_id, game_id, side, probability)
  values (pl.id, p_game_id, upper(trim(p_side)), round(p_probability, 2))
  on conflict (player_id, game_id) do update
    set side = excluded.side, probability = excluded.probability, updated_at = now();
  return json_build_object('ok', true, 'game', g.away || ' @ ' || g.home,
    'side', upper(trim(p_side)), 'probability', round(p_probability, 2),
    'mutable_until', least(g.kickoff, (select freeze_at from public.league_weeks w
                                       where w.season = g.season and w.week = g.week)));
end $$;

-- ============================================================ scoring (derived)
-- One scoring surface every reader shares. Per settled, non-tie game on the
-- full slate: picked & right -> (1-p)^2 · picked & wrong -> p^2 · unpicked ->
-- 0.25, the Brier of the ruled p=0.5 default. A player's denominator starts
-- at their first picked week (decision D); ties vanish (decision T).
create or replace function public.league_scores() returns table (
  player_id uuid, season int, week int, game_id text,
  picked boolean, correct boolean, brier numeric
)
language sql stable security definer set search_path = public as $$
  with first_week as (
    select p.player_id, min(g.season * 100 + g.week) as start_key
    from public.league_picks p join public.league_games g on g.id = p.game_id
    group by p.player_id
  )
  select fw.player_id, g.season, g.week, g.id,
         (p.player_id is not null) as picked,
         coalesce(p.side = r.winner, false) as correct,
         case
           when p.player_id is null then 0.25
           when p.side = r.winner then power(1 - p.probability, 2)
           else power(p.probability, 2)
         end::numeric as brier
  from public.league_games g
  join public.league_results r on r.game_id = g.id and r.winner is not null
  join first_week fw on fw.start_key <= g.season * 100 + g.week
  left join public.league_picks p on p.game_id = g.id and p.player_id = fw.player_id;
$$;

create or replace function public.league_standings_json() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(row_to_json(t) order by t.brier asc, t.picks_made desc), '[]'::json)
  from (
    select pl.handle, pl.profile_url,
           count(distinct (s.season, s.week))                 as weeks,
           count(*) filter (where s.picked)                   as picks_made,
           count(*)                                           as games_scored,
           count(*) filter (where s.correct)                  as wins,
           count(*) filter (where s.picked and not s.correct) as losses,
           round(avg(s.brier), 4)                             as brier
    from public.league_scores() s
    join public.league_players pl on pl.id = s.player_id
    group by pl.id, pl.handle, pl.profile_url
  ) t;
$$;

-- --------------------------------------------------- call of the week (derived)
-- The best-called upset: among correct picks on the settled week, the one
-- whose side the smallest share of pickers took; ties break to the higher
-- stated probability (conviction), then the earlier pick.
create or replace function public.league_call_of_week(p_season int, p_week int) returns json
language sql stable security definer set search_path = public as $$
  select row_to_json(t) from (
    select pl.handle, g.away || ' @ ' || g.home as game, p.side, p.probability,
           round(1.0 * cnt.same_side / cnt.total, 2) as side_share
    from public.league_picks p
    join public.league_games g on g.id = p.game_id and g.season = p_season and g.week = p_week
    join public.league_results r on r.game_id = g.id and r.winner = p.side
    join public.league_players pl on pl.id = p.player_id
    cross join lateral (
      select count(*) filter (where p2.side = p.side) as same_side, count(*) as total
      from public.league_picks p2 where p2.game_id = p.game_id
    ) cnt
    order by 1.0 * cnt.same_side / cnt.total asc, p.probability desc, p.updated_at asc
    limit 1
  ) t;
$$;

-- ================================================================== the week
-- p_week null -> the current (latest published) week. Full slate ordered by
-- kickoff, Main Card flagged per game. The field's picks on a game show only
-- once THAT game settles (decision S); your own picks show to your token
-- always. When the week is fully settled: per-player week Brier, the podium
-- statement, the call of the week.
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
        'picks', case when exists (select 1 from public.league_results r where r.game_id = g.id) then
          (select json_agg(json_build_object('handle', pl.handle, 'side', p.side,
                    'probability', p.probability, 'registered_at', p.updated_at) order by p.updated_at)
           from public.league_picks p join public.league_players pl on pl.id = p.player_id
           where p.game_id = g.id) end
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
    'call_of_week', case when w.settled_at is not null then public.league_call_of_week(w.season, w.week) end
  ) into res;
  return res;
end $$;

-- ================================================================== settling
-- The function hands us finals it read from ESPN; we write results for games
-- past kickoff, and when the whole slate completes: stamp the week, ledger it,
-- and ledger every p=0.5 default (decision D — the shrug goes on the record,
-- like the missed mic window).
create or replace function public.league_settle(p_finals jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare f jsonb; g public.league_games%rowtype; n int := 0; w public.league_weeks%rowtype; r record;
begin
  for f in select * from jsonb_array_elements(p_finals) loop
    select * into g from public.league_games where id = f->>'id';
    if not found or now() < g.kickoff then continue; end if;
    insert into public.league_results (game_id, away_score, home_score, winner)
    values (g.id, (f->>'away_score')::int, (f->>'home_score')::int, nullif(f->>'winner',''))
    on conflict (game_id) do nothing;
    if found then n := n + 1; end if;
  end loop;

  for w in select * from public.league_weeks ww
           where ww.settled_at is null
             and not exists (select 1 from public.league_games g2
                             left join public.league_results res on res.game_id = g2.id
                             where g2.season = ww.season and g2.week = ww.week
                               and res.game_id is null)
           for update loop
    update public.league_weeks set settled_at = now()
      where season = w.season and week = w.week;
    perform public.ledger('week_settled', null,
      jsonb_build_object('season', w.season, 'week', w.week));
    for r in select s.player_id, s.game_id, pl.handle
             from public.league_scores() s
             join public.league_players pl on pl.id = s.player_id
             where s.season = w.season and s.week = w.week and not s.picked loop
      perform public.ledger('pick_defaulted', null,
        jsonb_build_object('season', w.season, 'week', w.week, 'player_id', r.player_id,
                           'handle', r.handle, 'game_id', r.game_id, 'as', 0.5));
    end loop;
  end loop;
  return json_build_object('ok', true, 'finals_written', n);
end $$;

-- Throttle gate: the function asks before touching ESPN. Due only when an
-- unsettled week has a game past kickoff+3h and the last sweep is >5min old.
create or replace function public.league_sweep_gate() returns json
language plpgsql security definer set search_path = public as $$
declare tgt record;
begin
  select g.season, g.week into tgt
  from public.league_games g
  join public.league_weeks w on w.season = g.season and w.week = g.week and w.settled_at is null
  left join public.league_results r on r.game_id = g.id
  where r.game_id is null and now() >= g.kickoff + interval '3 hours'
  order by g.kickoff limit 1;
  if tgt is null then return json_build_object('due', false); end if;
  update public.league_sweep set last_run = now()
    where only_row and last_run < now() - interval '5 minutes';
  if not found then return json_build_object('due', false); end if;
  return json_build_object('due', true, 'season', tgt.season, 'week', tgt.week);
end $$;

-- ============================================================ the weekly mic
-- Best Brier of the settled week speaks: 300 chars on the settle page (the
-- Main Card leads that page; the statement attaches to the week), mic_window()
-- from the week's bell, no extensions, ties to the earlier final pick (W).
create or replace function public.league_podium_take(p_token text, p_season int, p_week int, p_text text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  me public.league_players%rowtype; w public.league_weeks%rowtype; best uuid; v_text text;
begin
  me := public.league_player(p_token);
  if me.id is null then raise exception 'unknown token' using errcode = '42501'; end if;
  select * into w from public.league_weeks where season = p_season and week = p_week;
  if not found or w.settled_at is null then raise exception 'that week has not settled'; end if;
  if now() >= w.settled_at + public.mic_window() then
    raise exception 'the mic closed at %', w.settled_at + public.mic_window();
  end if;
  select t.player_id into best from (
    select s.player_id, avg(s.brier) as b,
           (select max(p.updated_at) from public.league_picks p
            join public.league_games g on g.id = p.game_id
            where p.player_id = s.player_id and g.season = p_season and g.week = p_week) as last_pick
    from public.league_scores() s where s.season = p_season and s.week = p_week
    group by s.player_id order by b asc, last_pick asc nulls last limit 1
  ) t;
  if best is distinct from me.id then
    raise exception 'the mic belongs to the best Brier of the week' using errcode = '42501';
  end if;
  v_text := trim(coalesce(p_text, ''));
  if char_length(v_text) < 8 or char_length(v_text) > 300 then
    raise exception '8 to 300 characters. Make them count.';
  end if;
  insert into public.league_statements (season, week, player_id, text)
  values (p_season, p_week, me.id, v_text);
  perform public.ledger('league_podium', null,
    jsonb_build_object('season', p_season, 'week', p_week, 'handle', me.handle, 'text', v_text));
  return json_build_object('ok', true, 'published', true);
exception when unique_violation then
  raise exception 'the statement is already on the record';
end $$;

-- ============================================================= the leak wall
-- Same discipline as the fighter surfaces: nobody reaches these tables or
-- functions except the league edge function's service role. PostgREST anon
-- gets permission denied; the only door is the RPC surface above.
alter table public.league_players    enable row level security;
alter table public.league_weeks      enable row level security;
alter table public.league_games      enable row level security;
alter table public.league_picks      enable row level security;
alter table public.league_results    enable row level security;
alter table public.league_statements enable row level security;
alter table public.league_sweep      enable row level security;

revoke all on public.league_players, public.league_weeks, public.league_games,
              public.league_picks, public.league_results, public.league_statements,
              public.league_sweep
  from public, anon, authenticated;

revoke execute on function
  public.league_player(text),
  public.league_frozen(public.league_games),
  public.league_join(text, text),
  public.league_publish_week(int, int, timestamptz, jsonb, text[]),
  public.league_pick(text, text, text, numeric),
  public.league_scores(),
  public.league_standings_json(),
  public.league_call_of_week(int, int),
  public.league_week_json(text, int, int),
  public.league_settle(jsonb),
  public.league_sweep_gate(),
  public.league_podium_take(text, int, int, text)
  from public, anon, authenticated;

grant execute on function
  public.league_join(text, text),
  public.league_publish_week(int, int, timestamptz, jsonb, text[]),
  public.league_pick(text, text, text, numeric),
  public.league_standings_json(),
  public.league_week_json(text, int, int),
  public.league_settle(jsonb),
  public.league_sweep_gate(),
  public.league_podium_take(text, int, int, text)
  to service_role;
