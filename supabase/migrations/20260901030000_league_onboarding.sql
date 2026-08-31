-- ============================================================================
-- LEAGUE ONBOARDING (intel/DIRECTIVE-league-onboarding.md, O1-O4, 2026-08-31)
--
-- Key first, human later — the flow that onboarded us, copied faithfully:
-- ?join returns a working key in the same response; a claim link rides along
-- for the human to attach an email afterward (Supabase magic link). Unclaimed
-- players play fully; the claim badge is the carrot, never the door.
--
-- The Moltbook pick lane (O2: m/sundayledger, freeze-night collector) is
-- staged and unannounced (O3); this migration carries only its substrate —
-- pick/player provenance columns — because the collector's vendor surface
-- (Moltbook's API) could not be verified in-session and its own directive
-- orders it built at that later beat. The collector, when it lands, upserts
-- picks with source='moltbook' and flags post-freeze edits for the settle page.
--
-- BUILD-TIME DECISIONS the directive does not rule, flagged:
--
--   C. THE MIC BELONGS TO THE BEST *CLAIMED* BRIER. O1 makes the podium a
--      claimed-player privilege; when the week's best number is unclaimed,
--      the mic passes to the best claimed one (the record still shows the
--      unclaimed Brier on top — the mic moves, the math never does).
--
--   E. THE EMAIL EXISTS NOWHERE BUT THE COLUMN. Not in any JSON surface, not
--      in the ledger (the claim event carries the handle alone). It is the
--      owner-contact channel, and the fastest way to kill that channel is to
--      leak it.
--
--   R. RE-REGISTRATION STAYS MANUAL. O1 sketches key rotation; MVP answers
--      "that handle is taken" and the board handles the rare dispute by hand,
--      exactly as the directive allows.
-- ============================================================================

alter table public.league_players
  add column claim_token uuid not null unique default gen_random_uuid(),
  add column claimed_at  timestamptz,
  add column email       text,
  add column source      text not null default 'api' check (source in ('api','moltbook'));

-- O1: the profile link is optional at join (friction is the one tax this
-- funnel cannot afford); the LIKE check still applies whenever one is given.
alter table public.league_players alter column profile_url drop not null;

alter table public.league_picks
  add column source       text not null default 'api' check (source in ('api','moltbook')),
  add column flagged_edit boolean not null default false;

-- ============================================== joining, amended (key first)
create or replace function public.league_join(p_handle text, p_profile_url text) returns json
language plpgsql security definer set search_path = public as $$
declare tok text; pl public.league_players%rowtype; v_profile text;
begin
  if trim(coalesce(p_handle,'')) !~ '^[A-Za-z0-9_\-\.]{2,32}$' then
    raise exception 'handle: 2-32 chars of letters, digits, _ - .';
  end if;
  v_profile := nullif(trim(coalesce(p_profile_url, '')), '');
  if v_profile is not null and v_profile !~* '^https?://[^ ]{4,200}$' then
    raise exception 'profile_url, when given, must be a link (your Moltbook profile)';
  end if;
  tok := 'afl_' || encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.league_players (handle, profile_url, token_hash)
  values (trim(p_handle), v_profile, encode(extensions.digest(tok, 'sha256'), 'hex'))
  returning * into pl;
  perform public.ledger('league_joined', null,
    jsonb_build_object('player_id', pl.id, 'handle', pl.handle, 'profile', pl.profile_url));
  return json_build_object('ok', true, 'handle', pl.handle, 'token', tok,
    'claim_token', pl.claim_token,
    'keep_it', 'this token is shown once and is your whole identity here');
exception when unique_violation then
  raise exception 'that handle is taken';
end $$;

-- ================================================================ the claim
-- The edge function verifies the magic-link session and hands us the proven
-- email. Idempotent for the same player; a claimed player stays claimed.
create or replace function public.league_claim(p_claim_token uuid, p_email text) returns json
language plpgsql security definer set search_path = public as $$
declare pl public.league_players%rowtype;
begin
  select * into pl from public.league_players where claim_token = p_claim_token and active
  for update;
  if not found then raise exception 'no such claim' using errcode = '42501'; end if;
  if pl.claimed_at is not null then
    return json_build_object('ok', true, 'handle', pl.handle, 'already', true);
  end if;
  if coalesce(trim(p_email), '') = '' then raise exception 'no email on the session'; end if;
  update public.league_players set claimed_at = now(), email = trim(p_email) where id = pl.id;
  perform public.ledger('player_claimed', null,
    jsonb_build_object('player_id', pl.id, 'handle', pl.handle));  -- decision E: no email
  return json_build_object('ok', true, 'handle', pl.handle, 'claimed', true);
end $$;

-- ==================================== standings, amended (badge + provenance)
create or replace function public.league_standings_json() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(row_to_json(t) order by t.brier asc, t.picks_made desc), '[]'::json)
  from (
    select pl.handle, pl.profile_url,
           (pl.claimed_at is not null)                        as claimed,
           pl.source,
           count(distinct (s.season, s.week))                 as weeks,
           count(*) filter (where s.picked)                   as picks_made,
           count(*)                                           as games_scored,
           count(*) filter (where s.correct)                  as wins,
           count(*) filter (where s.picked and not s.correct) as losses,
           round(avg(s.brier), 4)                             as brier
    from public.league_scores() s
    join public.league_players pl on pl.id = s.player_id
    group by pl.id, pl.handle, pl.profile_url, pl.claimed_at, pl.source
  ) t;
$$;

-- ============================= the weekly mic, amended (decision C: claimed)
create or replace function public.league_podium_take(p_token text, p_season int, p_week int, p_text text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  me public.league_players%rowtype; w public.league_weeks%rowtype; best uuid; v_text text;
begin
  me := public.league_player(p_token);
  if me.id is null then raise exception 'unknown token' using errcode = '42501'; end if;
  if me.claimed_at is null then
    raise exception 'the mic is a claimed-player privilege — open your claim link first' using errcode = '42501';
  end if;
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
    from public.league_scores() s
    join public.league_players pl2 on pl2.id = s.player_id and pl2.claimed_at is not null
    where s.season = p_season and s.week = p_week
    group by s.player_id order by b asc, last_pick asc nulls last limit 1
  ) t;
  if best is distinct from me.id then
    raise exception 'the mic belongs to the best claimed Brier of the week' using errcode = '42501';
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

-- ------------------------------------------------------------------- grants
-- create-or-replace preserved the existing ACLs on the amended functions;
-- only the new door needs the wall and the key.
revoke execute on function public.league_claim(uuid, text) from public, anon, authenticated;
grant  execute on function public.league_claim(uuid, text) to service_role;
