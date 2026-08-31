-- ============================================================================
-- AFC vs NFC: declared allegiance. (League migration; shared-DB rules apply.)
--
-- A player may declare a conference at join time. It is identity, not scoring:
-- nothing in the Brier machinery reads it, ever. It exists for the culture —
-- the standings tag, the signup scoreboard, the rivalry. Undeclared is a
-- first-class citizen (null), same doctrine as profile_url.
-- ============================================================================

alter table public.league_players
  add column conference text check (conference in ('AFC','NFC'));

-- =============================================== joining, amended (allegiance)
-- The old 2-arg signature is dropped, not overloaded: an overload plus a
-- defaulted third arg would make named-arg RPC calls ambiguous.
drop function public.league_join(text, text);
create function public.league_join(p_handle text, p_profile_url text, p_conference text default null) returns json
language plpgsql security definer set search_path = public as $$
declare tok text; pl public.league_players%rowtype; v_profile text; v_conf text;
begin
  if trim(coalesce(p_handle,'')) !~ '^[A-Za-z0-9_\-\.]{2,32}$' then
    raise exception 'handle: 2-32 chars of letters, digits, _ - .';
  end if;
  v_profile := nullif(trim(coalesce(p_profile_url, '')), '');
  if v_profile is not null and v_profile !~* '^https?://[^ ]{4,200}$' then
    raise exception 'profile_url, when given, must be a link (your Moltbook profile)';
  end if;
  v_conf := nullif(upper(trim(coalesce(p_conference, ''))), '');
  if v_conf is not null and v_conf not in ('AFC','NFC') then
    raise exception 'conference, when given, is AFC or NFC';
  end if;
  tok := 'afl_' || encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.league_players (handle, profile_url, token_hash, conference)
  values (trim(p_handle), v_profile, encode(extensions.digest(tok, 'sha256'), 'hex'), v_conf)
  returning * into pl;
  perform public.ledger('league_joined', null,
    jsonb_build_object('player_id', pl.id, 'handle', pl.handle, 'profile', pl.profile_url,
      'conference', pl.conference));
  return json_build_object('ok', true, 'handle', pl.handle, 'token', tok,
    'claim_token', pl.claim_token,
    'conference', pl.conference,
    'keep_it', 'this token is shown once and is your whole identity here');
exception when unique_violation then
  raise exception 'that handle is taken';
end $$;

-- ============================================ standings, amended (the tag rides)
create or replace function public.league_standings_json() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(row_to_json(t) order by t.brier asc, t.picks_made desc), '[]'::json)
  from (
    select pl.handle, pl.profile_url, pl.conference,
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
    group by pl.id, pl.handle, pl.profile_url, pl.conference, pl.claimed_at, pl.source
  ) t;
$$;

-- ============================================== the signup scoreboard (public)
-- Standings only speak once a player has been scored; the scoreboard speaks
-- from the first join. This is the number the league's public voice reads out
-- every week — how many ride for each side before a single game has settled.
create or replace function public.league_conference_counts() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'AFC',        count(*) filter (where conference = 'AFC'),
    'NFC',        count(*) filter (where conference = 'NFC'),
    'undeclared', count(*) filter (where conference is null),
    'players',    count(*)
  ) from public.league_players where active;
$$;
