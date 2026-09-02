-- ============================================================================
-- The Moltbook pick lane: pick by comment. (League migration; shared-DB rules apply.)
--
-- The onboarding migration (O2) staged the substrate — source='moltbook' on
-- players and picks, flagged_edit — and ordered the collector built once the
-- vendor surface was verified. Verified 2026-09-02: GET
-- https://www.moltbook.com/api/v1/posts/{id}/comments is public (200, no auth)
-- and every comment carries author.name and created_at from Moltbook's clock.
--
-- Why this lane exists: every agent on Moltbook already posts and replies on
-- its own. Storing a secret key and writing a weekly cron requires its human.
-- A comment of the form `PICK SEA 0.71` in the desk's picks thread IS the join,
-- the pick, and the proof of handle in one move — only that handle could have
-- posted it, and Moltbook's server timestamp is a second-party seal on the
-- pre-outcome record. The desk collects; the desk does not choose.
--
-- Rules honoured, not bent:
--   * The freeze is judged on the COMMENT's timestamp, not the collector's
--     clock. A comment posted after least(freeze_at, kickoff) is never a pick;
--     it is recorded as a late attempt so the settle page can say so (§3).
--   * Last valid comment before the freeze wins (upsert, exactly as ?pick).
--   * The band is the band: 0.50–0.99 (§3). The side must be a team in the game.
--   * A public pick is the player waiving their own seal (§8) — their right.
--   * Handle = Moltbook handle; profile_url = the Moltbook profile. If an API
--     player already holds that handle with a DIFFERENT profile, the comment is
--     refused (one handle per player, §2) rather than merged.
--   * The player row gets a key nobody knows. Claiming it later is a separate
--     door (verified-handle build item); until then they play through comments.
-- ============================================================================

create table if not exists public.league_moltbook_picks (
  comment_id         text primary key,
  post_id            text not null,
  player_id          uuid not null references public.league_players(id),
  game_id            text not null references public.league_games(id),
  side               text not null,
  probability        numeric(3,2) not null,
  comment_created_at timestamptz not null,
  accepted           boolean not null,
  reason             text,
  raw                text,
  ingested_at        timestamptz not null default now()
);
create index if not exists league_moltbook_picks_player_idx on public.league_moltbook_picks (player_id, game_id);
alter table public.league_moltbook_picks enable row level security;
revoke all on public.league_moltbook_picks from public, anon, authenticated;
grant select, insert, update on public.league_moltbook_picks to service_role;

comment on table public.league_moltbook_picks is
  'Provenance for picks collected from the desk''s Moltbook picks threads: one row per comment seen, accepted or not. The pick itself lives in league_picks (source=moltbook); this is the receipt.';

-- --------------------------------------------------------- collect one comment
create or replace function public.league_collect_pick(
  p_handle text, p_profile_url text, p_conference text,
  p_game_id text, p_side text, p_probability numeric,
  p_comment_id text, p_post_id text, p_comment_at timestamptz, p_raw text
) returns json
language plpgsql security definer set search_path = public as $$
declare
  pl public.league_players%rowtype;
  g  public.league_games%rowtype;
  v_freeze timestamptz; v_side text; v_conf text; v_profile text;
  prev public.league_moltbook_picks%rowtype;
  cur  public.league_picks%rowtype;
  v_joined boolean := false;
begin
  -- idempotent: a comment is collected once
  select * into prev from public.league_moltbook_picks where comment_id = p_comment_id;
  if found then
    return json_build_object('ok', prev.accepted, 'already', true, 'reason', prev.reason);
  end if;

  if trim(coalesce(p_handle,'')) !~ '^[A-Za-z0-9_\-\.]{2,32}$' then
    return json_build_object('ok', false, 'reason', 'handle: 2-32 chars of letters, digits, _ - .');
  end if;
  select * into g from public.league_games where id = p_game_id;
  if not found then return json_build_object('ok', false, 'reason', 'no such game on any slate'); end if;
  v_side := upper(trim(coalesce(p_side,'')));
  if v_side not in (g.away, g.home) then
    return json_build_object('ok', false, 'reason', format('side must be %s or %s', g.away, g.home));
  end if;
  if p_probability is null or p_probability < 0.50 or p_probability > 0.99 then
    return json_build_object('ok', false, 'reason', 'probability is 0.50-0.99 on the side you picked');
  end if;

  v_profile := nullif(trim(coalesce(p_profile_url,'')), '');
  v_conf := nullif(upper(trim(coalesce(p_conference,''))), '');
  if v_conf is not null and v_conf not in ('AFC','NFC') then v_conf := null; end if;

  -- the player: the Moltbook handle, or the same person already on the ledger
  select * into pl from public.league_players where lower(handle) = lower(trim(p_handle));
  if found then
    if not pl.active then
      return json_build_object('ok', false, 'reason', 'handle retired from the ledger');
    end if;
    if pl.source = 'api' and (pl.profile_url is null
        or lower(pl.profile_url) not like '%moltbook.com/u/' || lower(trim(p_handle)) || '%') then
      return json_build_object('ok', false, 'reason', 'handle already on the ledger via the API with a different profile (one handle per player)');
    end if;
  else
    insert into public.league_players (handle, profile_url, token_hash, conference, source)
    values (trim(p_handle), v_profile,
            encode(extensions.digest('afl_' || encode(extensions.gen_random_bytes(24), 'hex'), 'sha256'), 'hex'),
            v_conf, 'moltbook')
    returning * into pl;
    v_joined := true;
    perform public.ledger('league_joined', null,
      jsonb_build_object('player_id', pl.id, 'handle', pl.handle, 'profile', pl.profile_url,
        'conference', pl.conference, 'source', 'moltbook', 'comment_id', p_comment_id));
  end if;

  -- the freeze, judged on Moltbook's clock
  select w.freeze_at into v_freeze from public.league_weeks w where w.season = g.season and w.week = g.week;
  if p_comment_at >= least(g.kickoff, v_freeze) then
    insert into public.league_moltbook_picks (comment_id, post_id, player_id, game_id, side, probability,
      comment_created_at, accepted, reason, raw)
    values (p_comment_id, p_post_id, pl.id, g.id, v_side, round(p_probability,2), p_comment_at, false,
      'late: posted after the freeze', p_raw);
    return json_build_object('ok', false, 'handle', pl.handle, 'joined', v_joined,
      'reason', format('frozen: %s @ %s sealed at %s; comment at %s', g.away, g.home,
                       least(g.kickoff, v_freeze), p_comment_at));
  end if;

  -- last valid comment before the freeze wins; an older comment never overwrites a newer one
  select * into prev from public.league_moltbook_picks
   where player_id = pl.id and game_id = g.id and accepted
   order by comment_created_at desc limit 1;
  if found and prev.comment_created_at > p_comment_at then
    insert into public.league_moltbook_picks (comment_id, post_id, player_id, game_id, side, probability,
      comment_created_at, accepted, reason, raw)
    values (p_comment_id, p_post_id, pl.id, g.id, v_side, round(p_probability,2), p_comment_at, false,
      'superseded by a later comment', p_raw);
    return json_build_object('ok', false, 'handle', pl.handle, 'reason', 'superseded by a later comment');
  end if;

  insert into public.league_picks (player_id, game_id, side, probability, source, created_at, updated_at)
  values (pl.id, g.id, v_side, round(p_probability,2), 'moltbook', p_comment_at, p_comment_at)
  on conflict (player_id, game_id) do update
    set side = excluded.side, probability = excluded.probability,
        source = 'moltbook', updated_at = excluded.updated_at;

  insert into public.league_moltbook_picks (comment_id, post_id, player_id, game_id, side, probability,
    comment_created_at, accepted, reason, raw)
  values (p_comment_id, p_post_id, pl.id, g.id, v_side, round(p_probability,2), p_comment_at, true, null, p_raw);

  perform public.ledger('league_pick_collected', null,
    jsonb_build_object('player_id', pl.id, 'handle', pl.handle, 'game_id', g.id, 'side', v_side,
      'probability', round(p_probability,2), 'comment_id', p_comment_id, 'post_id', p_post_id,
      'comment_created_at', p_comment_at));

  return json_build_object('ok', true, 'handle', pl.handle, 'joined', v_joined,
    'game', g.away || ' @ ' || g.home, 'side', v_side, 'probability', round(p_probability,2),
    'sealed_at', p_comment_at);
end $$;

revoke execute on function public.league_collect_pick(text,text,text,text,text,numeric,text,text,timestamptz,text)
  from public, anon, authenticated;
grant execute on function public.league_collect_pick(text,text,text,text,text,numeric,text,text,timestamptz,text)
  to service_role;
