-- ============================================================================
-- ARENA PROPS — fights the world settles
--
-- A league prop asks whether a player clears a line in a game the house owns.
-- An arena prop asks whether a public institution does a thing by a date the
-- law already fixed. Nobody in this club runs the clock: the SEC, the GAO and
-- FERC do, and the house only reads the record back.
--
-- These are SIBLING tables, not shared ones. league_props binds to
-- league_games(id) and to an nflverse gsis_id at the table level; a docket has
-- no kickoff, no team and no player, so it cannot ride those columns. What
-- transplants is the doctrine, and the doctrine is the expensive part. The
-- letters below are the same letters as 20260901050000_props.sql, and mean the
-- same things, so the two files argue in one language.
--
--   X. PROPS ARE OPT-IN EXTRAS. Arena prop Brier is its own number over only
--      the props you picked — no defaults, no denominator. league_scores(),
--      the fight Elo and the football prop table are all untouched. Skipping
--      costs nothing; playing builds a third public record.
--
--   V. A MISSING OUTCOME IS A VOID, NOT A LOSS. Football voids when the player
--      never plays. Here the source event never resolves: the NT is withdrawn,
--      the registrant deregisters mid-window, the protest is dismissed, the
--      solicitation is cancelled. Nobody is scored.
--
--   L. A LINE WITH PICKS ON IT IS IMMUTABLE. Republishing before the freeze
--      updates only props nobody has touched. After settle nothing moves.
--
--   G. SETTLE ONLY ON A SETTLED SOURCE. Football refuses to score a prop whose
--      game has no result row. Here: refuse unless the resolver actually
--      fetched the outcome record and handed back the evidence it read. A
--      timeout is not a NO. arena_prop_results.evidence is not null, and that
--      is the whole tooth in this rule.
--
--   S2. PICKS PUBLISH AT THE PROP'S SETTLE. Immutable at freeze, private until
--       the result row exists.
--
-- BUILD-TIME DECISIONS ruled by Ricky 2026-09-03, flagged in house style:
--
--   N. THE RESOLVER RUNS HOUSE-SIDE, ON CRON. Settlement is the house fetching
--      a free government endpoint on the same cron shape as settle_walkovers()
--      and close_mics(). House-pays-$0 survives — data.sec.gov is public domain
--      and costs nothing — but the house now owns settlement uptime, and this
--      is the first thing it runs on a schedule for a fight. The alternative,
--      owner-side settlement, was rejected because it leaves decision G with no
--      teeth: an owner who stalls or misreports cannot be caught by a rule that
--      only the owner executes.
--
--   C. NO PROP WITHOUT A NAMED RESOLVER. A source is not publishable until it
--      states an endpoint, a field and an expected value type, up front, in
--      arena_sources. This is the whole discipline. RESULT-patch-grading-
--      2026-09-02.md is what happens when the check is decided after the fact.
--
--   A. NO PROP WITHOUT A RECORDED ANCHOR DERIVATION. Every arena prop hangs off
--      a statutory date, and that date is almost never handed to you — it is
--      computed from inputs that are themselves sometimes missing. Half of the
--      live NT 10-K filers sampled on 2026-09-03 carry no filer status in
--      EDGAR, so their 10-K due date (60/75/90 days on fiscal year end) is not
--      derivable at all. Those are SKIPPED, not assumed. anchor_basis must show
--      its work or the row does not insert. Guessing an input the settle
--      boundary depends on is the same sin as grading a patch by keyword.
--
--   P. THE PICKER IS A league_players ROW. That table is named for the football
--      league but is not football: handle, profile_url, token_hash, active — a
--      token-bearing predictor. One door, not two. Decision X already keeps the
--      scores apart, so sharing the identity costs nothing and spares the club
--      a second onboarding.
--
--   K. A PROP THAT BECAME KNOWABLE BEFORE ITS FREEZE VOIDS. This hole does not
--      exist in football and is not in the handoff. Kickoff bounds a league
--      prop: nobody can know the passing yards while the market is open. An
--      arena prop has no such bound — a registrant may file its 10-K on day 3
--      of a fifteen-day window, and from that moment the answer is public on
--      EDGAR while the prop is still open. Anyone watching the feed could then
--      register YES at 0.99 and book a free 0.0001 Brier, which would poison
--      the only thing this ledger sells: calibration.
--      So the resolver reports resolved_on — the date the event actually became
--      public — and any prop whose resolved_on precedes its freeze is VOIDED,
--      not scored. Nobody is punished for the house setting a lazy clock, and
--      no one is rewarded for reading a filing the market had not closed on.
--      The generator's job is to make this rare by freezing early; the settle's
--      job is to make it harmless when it happens anyway.
--      resolved_on is REQUIRED on every scored row, at the table and at the
--      door: a resolver that will not say when the answer went public cannot be
--      scored against a freeze, so its props keep waiting instead of settling.
--      An optional guard here would read a missing field as "fine" and reopen
--      the very exploit — the same shape of hole G exists to close.
--      The card obeys K too: the result is withheld until the prop freezes, or
--      the read path would leak an early settle to anyone holding a token.
--
-- ANCHOR ARITHMETIC, verified in-session 2026-09-03 against eCFR:
--   17 CFR 240.12b-25(b)(2)(ii) — the report is deemed timely if filed no later
--     than the FIFTEENTH calendar day following the PRESCRIBED DUE DATE (10-K,
--     20-F, 11-K, N-CEN, N-CSR), or the FIFTH (10-Q, 10-D).
--   17 CFR 240.12b-25(a) — the Form 12b-25 itself is due no later than one
--     business day AFTER that due date, which is why the announcement date is
--     NOT the anchor and must never be used as one.
--   17 CFR 240.0-3(a) — if the last day falls on a Saturday, Sunday or holiday,
--     it rolls to the first business day following. This rolls BOTH the due
--     date and the fifteenth day, so the resolver needs a holiday calendar and
--     not just calendar arithmetic.
-- Brier is unchanged: correct gives (1-p)^2, wrong gives p^2, band 0.50-0.99.
-- ============================================================================

-- ----------------------------------------------------------------- sources
-- One row per event class. Decision C lives entirely in the not-nulls here:
-- a source that cannot say how it settles cannot carry a prop.
create table public.arena_sources (
  id             text primary key,               -- 'sec_nt10k'
  title          text not null,
  authority      text not null,                  -- '17 CFR 240.12b-25(b)(2)(ii)'
  authority_url  text not null check (authority_url like 'http%'),
  verified_at    timestamptz not null,           -- last in-session fetch of the statute
  resolver_url   text not null check (resolver_url like 'http%'),  -- {join_key} template
  resolver_field text not null,                  -- the field read out of the response
  resolver_type  text not null check (resolver_type in ('date', 'number', 'boolean', 'string')),
  grace_days     int  not null check (grace_days >= 0),
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

-- ------------------------------------------------------------------- props
-- anchor_date is the statutory date the window hangs on, computed AT PUBLISH
-- and stored (decision A). It is never re-derived at settle time: the document
-- it came from may be amended, and a prop that changes its own deadline after
-- picks are down is not a prop.
create table public.arena_props (
  id           text primary key,                 -- {source_id}_{join_key}_{market}
  source_id    text not null references public.arena_sources(id),
  join_key     text not null,                    -- CIK / accession no. / docket no. / B-number
  subject      text not null,                    -- 'MYX Inc. (CIK 0002087656)'
  market       text not null,                    -- 'timely_10k'
  question     text not null,                    -- the prop, as asked
  kind         text not null check (kind in ('BINARY', 'NUMERIC')),
  line         numeric(14,1),
  anchor_date  date not null,                    -- the PRESCRIBED DUE DATE, not the announcement
  anchor_basis jsonb not null,                   -- shows its work; decision A
  deadline     date not null,                    -- anchor + grace, rolled per 0-3(a)
  freeze_at    timestamptz not null,             -- per-prop clock; there is no Wednesday here
  published_at timestamptz not null default now(),
  unique (source_id, join_key, market),
  -- NUMERIC keeps football's push-proofing; BINARY has no line to push on.
  check (case when kind = 'NUMERIC' then line is not null and line = floor(line) + 0.5
              else line is null end),
  -- decision A: the derivation is named, or the row does not exist.
  check (coalesce(anchor_basis->>'basis', '') <> ''),
  -- a window that closes before it opens is a bug, not a prop.
  check (deadline >= anchor_date)
);
create index arena_props_source_idx   on public.arena_props (source_id, deadline);
create index arena_props_deadline_idx on public.arena_props (deadline);

-- ------------------------------------------------------------------- picks
create table public.arena_prop_picks (
  player_id   uuid not null references public.league_players(id),
  prop_id     text not null references public.arena_props(id),
  side        text not null check (side in ('OVER', 'UNDER', 'YES', 'NO')),
  probability numeric(3,2) not null check (probability between 0.50 and 0.99),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (player_id, prop_id)
);
create index arena_prop_picks_prop_idx on public.arena_prop_picks (prop_id);

-- ----------------------------------------------------------------- results
-- void = true is decision V: the source event never resolved, actual and
-- outcome stay null, nobody is scored.
-- evidence is decision G with teeth: the record the resolver actually read.
-- No evidence, no settle — a fetch that failed is not a NO.
create table public.arena_prop_results (
  prop_id     text primary key references public.arena_props(id),
  actual      text,                              -- the raw field value as read
  outcome     text check (outcome in ('OVER', 'UNDER', 'YES', 'NO')),
  void        boolean not null default false,
  void_reason text,
  resolved_on date,                              -- when the event became public (decision K)
  evidence    jsonb not null,                    -- {fetched_at, url, field, value}
  settled_at  timestamptz not null default now(),
  check (void = (outcome is null)),
  check (not void or coalesce(void_reason, '') <> ''),
  -- decision K at the table: a scored row must say when the answer went public.
  check (void or resolved_on is not null)
);

-- ------------------------------------------------------------------ freeze
create or replace function public.arena_frozen(p public.arena_props) returns boolean
language sql stable security definer set search_path = public as $$
  select now() >= p.freeze_at;
$$;

-- ========================================================= publishing props
-- House door. p_props: [{join_key, subject, market, question, kind, line,
-- anchor_date, anchor_basis, deadline, freeze_at}] straight off the generator.
-- Decision L guards updates; decision A is enforced at the door AND by the
-- table check, so a generator that cannot derive an anchor gets a named skip,
-- never a silent 90.
create or replace function public.arena_publish_props(p_source_id text, p_props jsonb)
returns json
language plpgsql security definer set search_path = public as $$
declare
  pr jsonb; pid text; existing public.arena_props%rowtype; src public.arena_sources%rowtype;
  n_ins int := 0; n_upd int := 0; n_kept int := 0;
  skipped text[] := '{}';
begin
  select * into src from public.arena_sources where id = p_source_id and active;
  if not found then
    raise exception 'no active source % — decision C: name the resolver first', p_source_id;
  end if;
  if p_props is null or jsonb_array_length(p_props) = 0 then
    raise exception 'no props in the body';
  end if;

  for pr in select * from jsonb_array_elements(p_props) loop
    -- Decision A, at the door: a prop whose anchor derivation is blank is
    -- skipped by name, never defaulted. This is where a blank EDGAR filer
    -- status stops.
    if coalesce(pr->'anchor_basis'->>'basis', '') = '' or (pr->>'anchor_date') is null then
      skipped := skipped || (coalesce(pr->>'subject', '?') || ' (no derivable anchor)');
      continue;
    end if;

    pid := format('%s_%s_%s', p_source_id, pr->>'join_key', pr->>'market');
    select * into existing from public.arena_props where id = pid;
    if found then
      -- Decision L: a prop with picks or a result keeps everything it was picked against.
      if exists (select 1 from public.arena_prop_picks pk where pk.prop_id = existing.id)
         or exists (select 1 from public.arena_prop_results r where r.prop_id = existing.id) then
        n_kept := n_kept + 1;
      else
        update public.arena_props
          set subject = pr->>'subject', question = pr->>'question', kind = pr->>'kind',
              line = nullif(pr->>'line', '')::numeric,
              anchor_date = (pr->>'anchor_date')::date, anchor_basis = pr->'anchor_basis',
              deadline = (pr->>'deadline')::date, freeze_at = (pr->>'freeze_at')::timestamptz
          where id = existing.id;
        n_upd := n_upd + 1;
      end if;
    else
      insert into public.arena_props
        (id, source_id, join_key, subject, market, question, kind, line,
         anchor_date, anchor_basis, deadline, freeze_at)
      values
        (pid, p_source_id, pr->>'join_key', pr->>'subject', pr->>'market', pr->>'question',
         pr->>'kind', nullif(pr->>'line', '')::numeric,
         (pr->>'anchor_date')::date, pr->'anchor_basis',
         (pr->>'deadline')::date, (pr->>'freeze_at')::timestamptz);
      n_ins := n_ins + 1;
    end if;
  end loop;

  perform public.ledger('arena_props_published', null,
    jsonb_build_object('source', p_source_id, 'inserted', n_ins, 'updated', n_upd,
                       'kept', n_kept, 'skipped', to_jsonb(skipped)));
  return json_build_object('ok', true, 'source', p_source_id, 'inserted', n_ins,
                           'updated', n_upd, 'kept', n_kept, 'skipped', to_jsonb(skipped));
end $$;

-- ================================================================ prop pick
-- The freeze comes off the prop, not off a game and not off a week.
create or replace function public.arena_prop_pick(p_token text, p_prop_id text, p_side text, p_probability numeric)
returns json
language plpgsql security definer set search_path = public as $$
declare
  pl public.league_players%rowtype; pr public.arena_props%rowtype; v_side text; ok_sides text[];
begin
  pl := public.league_player(p_token);
  if pl.id is null then raise exception 'unknown token' using errcode = '42501'; end if;
  select * into pr from public.arena_props where id = p_prop_id;
  if not found then raise exception 'no such prop on any card'; end if;
  if public.arena_frozen(pr) then
    raise exception 'frozen: % closed at %. The Ledger remembers what you said before the window.',
      pr.subject, pr.freeze_at;
  end if;
  if exists (select 1 from public.arena_prop_results r where r.prop_id = pr.id) then
    raise exception 'that prop already settled';
  end if;
  v_side := upper(trim(coalesce(p_side, '')));
  ok_sides := case when pr.kind = 'BINARY' then array['YES','NO'] else array['OVER','UNDER'] end;
  if not (v_side = any(ok_sides)) then
    raise exception 'side must be % on a % prop', array_to_string(ok_sides, ' or '), pr.kind;
  end if;
  if p_probability is null or p_probability < 0.50 or p_probability > 0.99 then
    raise exception 'probability is 0.50-0.99 on the side you picked. The Ledger does not sell certainty.';
  end if;
  insert into public.arena_prop_picks (player_id, prop_id, side, probability)
  values (pl.id, pr.id, v_side, round(p_probability, 2))
  on conflict (player_id, prop_id) do update
    set side = excluded.side, probability = excluded.probability, updated_at = now();
  return json_build_object('ok', true, 'prop', pr.question, 'side', v_side,
    'probability', round(p_probability, 2), 'mutable_until', pr.freeze_at,
    'deadline', pr.deadline);
end $$;

-- ======================================================= prop scores (derived)
-- Decision X: only picked, only settled, never void, no defaults.
create or replace function public.arena_prop_scores() returns table (
  player_id uuid, source_id text, prop_id text, correct boolean, brier numeric
)
language sql stable security definer set search_path = public as $$
  select pk.player_id, pr.source_id, pr.id,
         (pk.side = r.outcome) as correct,
         case when pk.side = r.outcome
              then power(1 - pk.probability, 2)
              else power(pk.probability, 2) end::numeric as brier
  from public.arena_prop_picks pk
  join public.arena_props pr on pr.id = pk.prop_id
  join public.arena_prop_results r on r.prop_id = pr.id and not r.void;
$$;

-- ================================================================= settling
-- The cron's door (decision N). p_outcomes: [{join_key, market, actual,
-- outcome, resolved_on, void, void_reason, evidence}] built by the edge
-- function from what the resolver actually fetched. resolved_on is decision K:
-- the date the answer became public, which is not the date we looked.
--
-- Decision G, with teeth: a row carrying no evidence is not settled, it is
-- COUNTED AS WAITING. A source that timed out looks exactly like a source that
-- said NO if you let it, so this function will not let it.
create or replace function public.arena_settle_props(p_source_id text, p_outcomes jsonb)
returns json
language plpgsql security definer set search_path = public as $$
declare
  pr record; o jsonb; n_set int := 0; n_void int := 0; n_wait int := 0;
begin
  if not exists (select 1 from public.arena_sources where id = p_source_id) then
    raise exception 'no such source %', p_source_id;
  end if;

  for pr in select p.* from public.arena_props p
            where p.source_id = p_source_id
              and not exists (select 1 from public.arena_prop_results r where r.prop_id = p.id)
  loop
    o := null;
    select a into o from jsonb_array_elements(coalesce(p_outcomes, '[]'::jsonb)) a
      where a->>'join_key' = pr.join_key and a->>'market' = pr.market;

    -- G: no row, or a row with no evidence of a fetch, keeps waiting.
    if o is null or o->'evidence' is null or jsonb_typeof(o->'evidence') = 'null' then
      n_wait := n_wait + 1;
      continue;
    end if;

    if coalesce((o->>'void')::boolean, false) then
      insert into public.arena_prop_results (prop_id, void, void_reason, evidence)
      values (pr.id, true, coalesce(nullif(o->>'void_reason', ''), 'source event never resolved'),
              o->'evidence');
      n_void := n_void + 1;

    elsif (o->>'outcome') is null then
      -- fetched, but the window is still open: not a NO yet.
      n_wait := n_wait + 1;

    -- Decision K, and it is NOT optional. A resolver that will not say WHEN the
    -- answer went public cannot be scored against a freeze, so the prop keeps
    -- waiting. Letting a missing resolved_on fall through to the scored insert
    -- would make an absent field read as "fine" — the same failure G exists to
    -- stop, and it would reopen the exploit K was written to close.
    elsif nullif(o->>'resolved_on', '') is null then
      n_wait := n_wait + 1;

    -- The answer went public while the market was still open, so the prop is
    -- unscoreable no matter what anyone picked.
    --
    -- Anchored in UTC on purpose. resolved_on is a DATE and freeze_at is an
    -- instant, so casting freeze_at::date would read the server's TimeZone
    -- setting and a scoring boundary would move depending on where the database
    -- thinks it lives. Compare the START of the resolved day, in UTC, against
    -- the freeze instant: if the day the answer went public had already begun
    -- when the market closed, we cannot prove the pickers did not see it, so
    -- the prop voids.
    --
    -- resolved_on is a DATE, so the answer landed somewhere in [day, day+1).
    -- It could have preceded the freeze exactly when the day STARTED before the
    -- freeze, which is what this compares. Same-day resolution therefore voids
    -- in every case but one: a freeze at exactly 00:00 UTC, where no part of the
    -- resolving day precedes the close, so the prop scores honestly. That is not
    -- a loophole — it is the one same-day arrangement in which nobody could have
    -- read the answer while the market was open.
    elsif ((o->>'resolved_on')::date at time zone 'UTC') < pr.freeze_at then
      insert into public.arena_prop_results (prop_id, void, void_reason, resolved_on, evidence)
      values (pr.id, true,
              format('knowable before freeze: resolved %s UTC, freeze %s UTC',
                     o->>'resolved_on', to_char(pr.freeze_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI')),
              (o->>'resolved_on')::date, o->'evidence');
      n_void := n_void + 1;

    else
      insert into public.arena_prop_results (prop_id, actual, outcome, resolved_on, evidence)
      values (pr.id, o->>'actual', upper(o->>'outcome'),
              (o->>'resolved_on')::date, o->'evidence');
      n_set := n_set + 1;
    end if;
  end loop;

  perform public.ledger('arena_props_settled', null,
    jsonb_build_object('source', p_source_id, 'settled', n_set, 'voided', n_void,
                       'awaiting_source', n_wait));
  return json_build_object('ok', true, 'source', p_source_id, 'settled', n_set,
                           'voided', n_void, 'awaiting_source', n_wait);
end $$;

-- ================================================================ the sweep
-- Decision N's cron helper, same shape as league_prop_weeks_unsettled(): the
-- scheduled call arrives with an empty body and asks which sources still carry
-- props whose statutory window has closed. Oldest deadline first.
create or replace function public.arena_prop_sources_due() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(
    json_agg(json_build_object('source_id', t.source_id, 'open', t.n,
                               'oldest_deadline', t.oldest)
             order by t.oldest),
    '[]'::json)
  from (
    select p.source_id, count(*) as n, min(p.deadline) as oldest
    from public.arena_props p
    join public.arena_sources s on s.id = p.source_id and s.active
    where not exists (select 1 from public.arena_prop_results r where r.prop_id = p.id)
      and p.deadline <= current_date
    group by p.source_id
  ) t;
$$;

-- ================================================================= the card
-- Lines are public product; the field's picks on a prop show only once THAT
-- prop settles (S2); your own always show to your token.
create or replace function public.arena_props_json(p_token text default null, p_source_id text default null)
returns json
language plpgsql stable security definer set search_path = public as $$
declare v_src text; me public.league_players%rowtype; res json;
begin
  v_src := coalesce(p_source_id, (select source_id from public.arena_props
                                  order by published_at desc limit 1));
  if v_src is null then
    return json_build_object('props', null, 'note', 'no arena prop card yet');
  end if;
  if p_token is not null then me := public.league_player(p_token); end if;

  select json_build_object(
    'source', (select json_build_object('id', s.id, 'title', s.title, 'authority', s.authority,
                                        'authority_url', s.authority_url, 'verified_at', s.verified_at,
                                        'grace_days', s.grace_days)
               from public.arena_sources s where s.id = v_src),
    'how', 'POST ?arena_prop_pick {prop_id, side, probability 0.50-0.99} until that prop''s freeze. Settles from the public record once the statutory window closes; a source event that never resolves voids the prop. Arena prop Brier is its own table — skipping never costs you.',
    'props', (
      select json_agg(json_build_object(
        'prop_id', pr.id, 'subject', pr.subject, 'join_key', pr.join_key,
        'market', pr.market, 'question', pr.question, 'kind', pr.kind, 'line', pr.line,
        'anchor_date', pr.anchor_date, 'anchor_basis', pr.anchor_basis,
        'deadline', pr.deadline, 'freeze_at', pr.freeze_at,
        'frozen', public.arena_frozen(pr),
        -- S2 + decision K on the READ path: a prop can settle (a day-3 filing)
        -- while it is still open, so gating the result on the result row alone
        -- would hand the answer to anyone holding a token. Gate on the freeze.
        'result', case when public.arena_frozen(pr) then
          (select json_build_object('actual', r.actual, 'outcome', r.outcome,
                                    'void', r.void, 'void_reason', r.void_reason,
                                    'resolved_on', r.resolved_on,
                                    'evidence', r.evidence)
           from public.arena_prop_results r where r.prop_id = pr.id) end,
        'my_pick', case when me.id is not null then
          (select json_build_object('side', pk.side, 'probability', pk.probability)
           from public.arena_prop_picks pk where pk.prop_id = pr.id and pk.player_id = me.id) end,
        'picks', case when public.arena_frozen(pr)
                       and exists (select 1 from public.arena_prop_results r where r.prop_id = pr.id) then
          (select json_agg(json_build_object('handle', pl.handle, 'side', pk.side,
                    'probability', pk.probability, 'registered_at', pk.updated_at) order by pk.updated_at)
           from public.arena_prop_picks pk join public.league_players pl on pl.id = pk.player_id
           where pk.prop_id = pr.id) end
      ) order by pr.deadline, pr.subject)
      from public.arena_props pr where pr.source_id = v_src
    ),
    'prop_briers', case when exists (select 1 from public.arena_prop_results r
                                     join public.arena_props pr on pr.id = r.prop_id
                                     where pr.source_id = v_src) then (
      select json_agg(json_build_object('handle', pl.handle, 'brier', t.brier, 'record', t.rec)
                      order by t.brier asc)
      from (
        select s.player_id, round(avg(s.brier), 4) as brier,
               count(*) filter (where s.correct) || '-' || count(*) filter (where not s.correct) as rec
        from public.arena_prop_scores() s
        where s.source_id = v_src
        group by s.player_id
      ) t join public.league_players pl on pl.id = t.player_id
    ) end
  ) into res;
  return res;
end $$;

-- ============================================================= the leak wall
alter table public.arena_sources      enable row level security;
alter table public.arena_props        enable row level security;
alter table public.arena_prop_picks   enable row level security;
alter table public.arena_prop_results enable row level security;

revoke all on public.arena_sources, public.arena_props,
              public.arena_prop_picks, public.arena_prop_results
  from public, anon, authenticated;

revoke execute on function
  public.arena_frozen(public.arena_props),
  public.arena_publish_props(text, jsonb),
  public.arena_prop_pick(text, text, text, numeric),
  public.arena_prop_scores(),
  public.arena_settle_props(text, jsonb),
  public.arena_prop_sources_due(),
  public.arena_props_json(text, text)
  from public, anon, authenticated;

grant execute on function
  public.arena_publish_props(text, jsonb),
  public.arena_prop_pick(text, text, text, numeric),
  public.arena_settle_props(text, jsonb),
  public.arena_prop_sources_due(),
  public.arena_props_json(text, text)
  to service_role;

-- ------------------------------------------------- the first and only source
-- Decision C satisfied up front. verified_at is the in-session eCFR fetch of
-- 2026-09-03; grace_days is 12b-25(b)(2)(ii) for a 10-K, read verbatim, not
-- remembered. Nothing else publishes until this one settles a real prop.
insert into public.arena_sources
  (id, title, authority, authority_url, verified_at,
   resolver_url, resolver_field, resolver_type, grace_days)
values
  ('sec_nt10k',
   'Form 12b-25 (NT 10-K): does the registrant file its 10-K inside the statutory grace window?',
   '17 CFR 240.12b-25(b)(2)(ii); due date rolled per 17 CFR 240.0-3(a)',
   'https://www.ecfr.gov/current/title-17/section-240.12b-25',
   timestamptz '2026-09-03 00:00:00+00',
   'https://data.sec.gov/submissions/CIK{join_key}.json',
   'filings.recent.form[]=10-K -> filings.recent.filingDate',
   'date',
   15)
on conflict (id) do nothing;
