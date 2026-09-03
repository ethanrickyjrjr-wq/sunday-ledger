-- ============================================================================
-- via: which door the player walked through. (League migration; shared-DB rules apply.)
--
-- The ClawHub listing showed 116 downloads, 0 installs, and the league showed
-- one signup — and there was no way on earth to tell whether those facts had
-- anything to do with each other. league_players.source only ever says 'api'
-- or 'moltbook': that is the MECHANISM a join arrived by, not the CHANNEL the
-- player came from. This column is the channel.
--
-- Doctrine, in order:
--   1. A join NEVER fails over a marketing tag. Malformed via -> null, and the
--      join proceeds. Attribution is bookkeeping; the player is the product.
--   2. No controlled vocabulary in a check constraint. A channel that does not
--      exist yet -- a Discord, a newsletter, someone's conference talk -- must
--      work the day it exists, with no migration. The SHAPE is bounded; the
--      VALUE is open.
--   3. Declared once at join, like conference. Never rewritten, never scored,
--      never public. The Brier machinery does not know this column exists.
-- ============================================================================

alter table public.league_players add column via text;

-- The normalizer is the whole safety story: lowercase, trim, bound the shape,
-- return null for anything it does not like. It never raises, which is what
-- makes rule 1 true.
create or replace function public.league_norm_via(p_via text) returns text
language sql immutable set search_path = public as $$
  select case
    when lower(trim(coalesce(p_via, ''))) ~ '^[a-z0-9][a-z0-9_.-]{1,23}$'
      then lower(trim(p_via))
    else null
  end;
$$;

-- ==================================================== joining, amended (via)
-- The 3-arg signature is dropped, not overloaded -- same reason the 2-arg was
-- dropped when conference landed: an overload plus a defaulted arg makes
-- named-arg RPC calls ambiguous. A caller still sending only the old three
-- names resolves to this function with p_via defaulted, so an edge function
-- deployed before this migration keeps working through the window.
drop function public.league_join(text, text, text);
create function public.league_join(
  p_handle text,
  p_profile_url text,
  p_conference text default null,
  p_via text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare tok text; pl public.league_players%rowtype; v_profile text; v_conf text; v_via text;
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
  -- No raise. A tag the house cannot read is a tag the house does not keep.
  v_via := public.league_norm_via(p_via);
  tok := 'afl_' || encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.league_players (handle, profile_url, token_hash, conference, via)
  values (trim(p_handle), v_profile, encode(extensions.digest(tok, 'sha256'), 'hex'), v_conf, v_via)
  returning * into pl;
  perform public.ledger('league_joined', null,
    jsonb_build_object('player_id', pl.id, 'handle', pl.handle, 'profile', pl.profile_url,
      'conference', pl.conference, 'via', pl.via));
  return json_build_object('ok', true, 'handle', pl.handle, 'token', tok,
    'claim_token', pl.claim_token,
    'conference', pl.conference,
    'keep_it', 'this token is shown once and is your whole identity here');
exception when unique_violation then
  raise exception 'that handle is taken';
end $$;

-- =========================================================== the funnel, read
-- House-only. A roster with join times and channels is marketing intelligence,
-- not a public surface -- the anon key is in the client bundle, so anything
-- PUBLIC can execute is effectively published.
--
-- A player who joined before this column existed reads 'unattributed', which is
-- the truth and should stay legible as such. A Moltbook-collected player reads
-- 'moltbook' from source, so the collector function needs no amendment.
create or replace function public.league_joins_json() returns json
language sql stable security definer set search_path = public as $$
  with p as (
    select pl.handle, pl.conference, pl.source, pl.active, pl.joined_at,
           (pl.claimed_at is not null) as claimed,
           coalesce(pl.via, case when pl.source = 'moltbook' then 'moltbook'
                                 else 'unattributed' end) as via
    from public.league_players pl
  )
  select json_build_object(
    'players', (select count(*) from p),
    'active',  (select count(*) from p where active),
    'by_channel', (
      select coalesce(json_agg(row_to_json(c) order by c.players desc, c.via), '[]'::json)
      from (
        select via,
               count(*)                          as players,
               count(*) filter (where active)    as active,
               count(*) filter (where claimed)   as claimed,
               min(joined_at)                    as first_join,
               max(joined_at)                    as last_join
        from p group by via
      ) c
    ),
    'roster', (
      select coalesce(json_agg(row_to_json(r) order by r.joined_at desc), '[]'::json)
      from (select handle, via, conference, source, active, claimed, joined_at from p) r
    )
  );
$$;

revoke execute on function
  public.league_joins_json()
  from public, anon, authenticated;

grant execute on function
  public.league_norm_via(text),
  public.league_joins_json()
  to service_role;
