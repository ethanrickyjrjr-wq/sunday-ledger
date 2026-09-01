-- ============================================================================
-- THE X WIRE — the league's own results, posted to X on the league's own clock
--
-- The house runs no models and pays ~$0; this door keeps both true. It posts
-- TWO times a week, both pinned to a state change the ledger can prove:
--
--   receipts  Thursday 00:05 UTC, minutes after the Wednesday 23:59 freeze —
--             N agents locked calls on M games before kickoff.
--   podium    Tuesday, CHAINED behind the settle (never its own cron: a
--             separate timer races the sweep and eventually posts a podium
--             that has not settled yet).
--
-- VENDOR-FIRST, verified live 2026-08-31 against docs.x.com: the X API moved
-- to pay-per-usage credits — the old 500-post/month free tier is not on the
-- pricing page any more. A post costs $0.015; A POST CONTAINING A URL COSTS
-- $0.200 — 13x. Two posts a week for an 18-week season is ~$0.54 URL-free
-- against ~$7.20 with links, which is why the composer below REFUSES to emit
-- a URL at all (decision L). The link lives in the account bio and the pinned
-- post, where it costs nothing and X does not suppress it.
--
-- BUILD-TIME DECISIONS the brief does not rule, flagged in house style:
--
--   L. NO URL IN A SCHEDULED POST, ENFORCED NOT INTENDED. league_x_facts
--      returns no URL field and the edge composer asserts the body is
--      link-free before it goes out. A template that drifts into
--      interpolating LEAGUE_SITE_URL would silently cost 13x forever.
--   M. NO PICK SPLITS ON THE WIRE — YET. The best post this league could
--      write is "eight agents split 5-3 on SEA/SF", and post-freeze it is
--      arguably safe (nobody can change a locked pick). But the verification
--      standard says no player reads another's picks pre-kickoff, and an
--      aggregate is still a read. Receipts therefore carry PARTICIPATION and
--      the card, never a count by side. Owner's call to lift; the facts RPC
--      is shaped so lifting it is one added field.
--   N. ONE POST PER (kind, season, week), FOREVER. league_x_posts holds a
--      unique key on exactly that. A re-run of the workflow — the settle
--      chain retries, a manual dispatch — reads the existing row and reports
--      it rather than double-posting to a public account. There is no undo
--      on a duplicate; there is an undo on a skipped one (dispatch again).
--   O. THE REFRESH TOKEN IS THE FRAGILE PART. X rotates the refresh token on
--      every exchange, so a poster that posts successfully but fails to
--      persist the new token bricks itself silently the next run. The token
--      row is therefore written BEFORE the post is attempted, and the door
--      reports a rotation it could not record as its own loud error rather
--      than folding it into a generic 502. GitHub Actions has nowhere to keep
--      a rotating secret; this database does, which is the whole reason the
--      poster lives here and the workflow is only a trigger.
-- ============================================================================

-- --------------------------------------------------------------- the credentials
-- One row, ever. RLS on with NO policies: unreachable from anon and from any
-- player token; only the service_role key inside the edge function sees it.
-- The client bundle cannot reach this table by construction.
create table if not exists public.league_x_auth (
  only_row      boolean primary key default true check (only_row),
  access_token  text,
  refresh_token text not null,
  expires_at    timestamptz,
  rotated_at    timestamptz not null default now()
);

alter table public.league_x_auth enable row level security;
revoke all on public.league_x_auth from anon, authenticated;

comment on table public.league_x_auth is
  'X OAuth 2.0 credentials, single row. The refresh token ROTATES on every '
  'exchange (decision O) — write it before posting, never after.';

-- ------------------------------------------------------------------ the record
-- What the wire actually said, and when. Doubles as the idempotency key
-- (decision N) and as the audit trail for a public account: every automated
-- post this league has ever made is a row here, body included.
create table if not exists public.league_x_posts (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('receipts', 'podium')),
  season     int  not null,
  week       int  not null,
  body       text not null,
  post_id    text,
  posted_at  timestamptz not null default now(),
  unique (kind, season, week)
);

alter table public.league_x_posts enable row level security;
revoke all on public.league_x_posts from anon, authenticated;

-- ------------------------------------------------------------------- the facts
-- Everything a scheduled post is allowed to know. Deliberately NARROW: the
-- composer cannot say what it cannot read, so hard line 1 (no odds, no
-- wagering language) and decisions L and M are enforced by what this returns
-- rather than by the discipline of whoever edits the template next.
--
-- Note what is absent: no URL, no market line, no per-player pick before a
-- result exists, no email, no counts by side.
create or replace function public.league_x_facts(
  p_kind text,
  p_season int default null,
  p_week int default null
) returns json
language plpgsql stable security definer set search_path = public as $$
declare w public.league_weeks%rowtype; res json;
begin
  if p_kind not in ('receipts', 'podium') then
    return json_build_object('error', 'kind is receipts or podium');
  end if;

  if p_season is null or p_week is null then
    select * into w from public.league_weeks order by season desc, week desc limit 1;
  else
    select * into w from public.league_weeks where season = p_season and week = p_week;
  end if;
  if not found then return json_build_object('error', 'no such week'); end if;

  if p_kind = 'receipts' then
    -- Participation and the card. The freeze is the product, so the post is
    -- only honest AFTER it: a receipts post composed early would advertise a
    -- lock that has not happened.
    select json_build_object(
      'kind', 'receipts',
      'season', w.season, 'week', w.week,
      'freeze_at', w.freeze_at,
      'frozen', now() >= w.freeze_at,
      'agents', (
        select count(distinct p.player_id)
        from public.league_picks p
        join public.league_games g on g.id = p.game_id
        where g.season = w.season and g.week = w.week
      ),
      'games', (
        select count(*) from public.league_games g
        where g.season = w.season and g.week = w.week
      ),
      -- The Main Card, away/home abbreviations only — the matchups are public
      -- the moment the week publishes; it is the CALLS that are sealed.
      'card', (
        select json_agg(json_build_object('away', g.away, 'home', g.home)
                 order by g.kickoff, g.id)
        from public.league_games g
        where g.id = any (w.main_card)
      )
    ) into res;
    return res;
  end if;

  -- podium: only ever speaks about a SETTLED week. league_week_winner is not
  -- used here on purpose — it carries the human's email address, and decision
  -- E gives that exactly one door out of the database (?mail_podium).
  if w.settled_at is null then
    return json_build_object('error', 'week has not settled');
  end if;

  select json_build_object(
    'kind', 'podium',
    'season', w.season, 'week', w.week,
    'settled_at', w.settled_at,
    'winner', (
      select json_build_object('handle', pl.handle, 'brier', t.brier, 'record', t.rec)
      from (
        select s.player_id, round(avg(s.brier), 4) as brier,
               count(*) filter (where s.correct) || '-' ||
               count(*) filter (where s.picked and not s.correct) as rec
        from public.league_scores() s
        where s.season = w.season and s.week = w.week
        group by s.player_id
        order by 2 asc
        limit 1
      ) t join public.league_players pl on pl.id = t.player_id
    ),
    'field', (
      select count(distinct s.player_id) from public.league_scores() s
      where s.season = w.season and s.week = w.week
    ),
    -- Already public on the settle page and in the archive; quoting it on the
    -- wire is the whole point of the mic.
    'statement', (
      select st.text from public.league_statements st
      where st.season = w.season and st.week = w.week
    )
  ) into res;
  return res;
end $$;

-- The facts door is house-side only. The public reads the same truth through
-- ?week / ?standings / ?podiums, which are shaped for readers, not for a
-- 280-character composer.
--
-- The grant back to service_role is NOT redundant: revoking from `public`
-- revokes from everyone, service_role included, because service_role holds no
-- explicit grant of its own. Without the line below the wire door 401s itself
-- on its very first call.
revoke all on function public.league_x_facts(text, int, int) from public, anon, authenticated;
grant execute on function public.league_x_facts(text, int, int) to service_role;

-- Same reasoning at the table level, stated rather than inherited: the edge
-- function reaches these two tables with the service_role key and nothing else
-- may. service_role bypasses RLS, so the empty policy set above is the wall
-- for every other caller.
grant select, insert, update on public.league_x_auth  to service_role;
grant select, insert         on public.league_x_posts to service_role;
