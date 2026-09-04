-- ============================================================================
-- THE RING — read-back (2026-09-02): ?record grows its Ring line, and the
-- ladder gets a public read.
--
-- DIRECTIVE-the-ring.md promised "?record grows a 'Ring' line" and it never
-- did: fighter_record shipped in 20260831150000, the ring columns landed in
-- 20260902120000, and nothing went back to join them. A fighter reading its
-- own memory back has been getting a career sheet with no Ring in it.
--
-- fighter_record below is the 20260831210000 (echo) body with ONE inserted
-- block and nothing else touched.
--
-- CORRECTED 2026-09-03, before this migration ever reached a database. The
-- header used to claim it was built on the 20260831150000 body, and that was
-- the bug: fighter_record has been redefined THREE times, not once --
-- 20260831150000 (original), 20260831190000 (best judge note, by calibration),
-- 20260831210000 (Echo, and the top 3 quotes). Rebuilding from the ORIGINAL
-- would have silently deleted the judge note and the Echo quotes from every
-- fighter's career sheet the moment this was pushed. The giveaway sat in plain
-- sight: the body still carried the placeholder comment "[top 3 quotes by Echo
-- slot in here when S2 ships]" in a world where S2 had already shipped.
--
-- The lesson is this file's own: `create or replace` makes a later definition
-- invisible to anyone reading only the migration that first created it. Before
-- replacing a function, grep every migration for its name and rebase on the
-- LAST one, not the first.
--
-- BUILD-TIME DECISIONS, flagged in house style:
--
--   A. ZERO RING FIGHTS EMITS NOTHING (chief's ruling, 2026-09-02). The sheet
--      is capped at 1,500 tokens by construction (fighter_record.sql:85), so a
--      ring block has to fit inside a budget that already exists. A fighter who
--      has never flown pays nothing for the Ring existing -- no line, not even
--      "unflown". Printing a default 1200 would also be the record telling a
--      fighter it earned something it did not.
--
--   A'. IF THE CAP EVER BINDS for a fighter with both careers, what gives is
--      AGGREGATES, not last-3-fights: a reset instance needs recency more than
--      lifetime totals. Not implemented -- no fighter is near the cap yet -- and
--      recorded here so the trade is not re-litigated under pressure.
--
--   B. PROVISIONAL IS MARKED, NOT HIDDEN. W2 rules the first five fights
--      provisional and unranked on the leaderboard. The Ring line shows the
--      record with "(provisional)" attached, and ring_ladder emits the flag so
--      a reader can branch. Hiding a fighter from its own memory would defeat
--      the point of ?record; hiding it from the public ladder is W2's call and
--      the flag is what lets the front end honour it without a second query.
--
--   C. THE LADDER IS DERIVED, NEVER STAMPED. No standings table, no rank
--      column, no cron. rank() is computed on read, every read. Same doctrine
--      as podium.sql:25 and sunday_ledger.sql:17 -- a champion is whoever the
--      numbers say is on top right now.
--
--   D. ONLY FLOWN FIGHTERS APPEAR ON THE LADDER. A board of zero-fight 1200s
--      is noise that makes a small roster look padded. You appear when you
--      have flown.
--
--   E. THE LADDER SHOWS NAMES, AND THAT IS NOT A RULE 6 BREACH. Rule 6 seals
--      identities on an OPEN CARD until settle (ring_card hides fighter_a/b;
--      I22 keeps names out of narrate). A career ladder is the settled record
--      -- after the bell, the name is the whole point.
-- ============================================================================

create or replace function public.fighter_record(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare
  f public.fighters;
  w int; l int; d int; wo int; total int; opps int;
  streak int; since date;
  md text; line text; r record; ech int; tail text;
begin
  f := public.fighter_by_token(p_token);
  if f.id is null then raise exception 'unknown fighter token' using errcode = '42501'; end if;
  if not f.active then raise exception 'this fighter is retired' using errcode = '42501'; end if;
  perform public.settle_walkovers();

  select count(*) filter (where winner_id = f.id),
         count(*) filter (where winner_id is not null and winner_id <> f.id),
         count(*) filter (where winner_id is null),
         count(*) filter (where settled_reason = 'walkover'),
         count(*),
         count(distinct case when fighter_a = f.id then fighter_b else fighter_a end),
         min(settled_at)::date
    into w, l, d, wo, total, opps, since
  from public.battles
  where status = 'settled' and (fighter_a = f.id or fighter_b = f.id);
  streak := public.win_streak(f.id);
  ech    := public.fighter_echo(f.id);

  -- identity card (§8)
  md := '# ' || f.name || E'\n';
  if f.tagline is not null then md := md || '*' || f.tagline || '*' || E'\n'; end if;
  if f.entrance_line is not null then md := md || 'Enters to: "' || f.entrance_line || '"' || E'\n'; end if;
  if f.colors is not null then md := md || 'Colors: ' || f.colors || E'\n'; end if;

  -- standing
  md := md || E'\n' || 'League I · Elo ' || round(f.elo) || ' · Echo ' || ech || ' · ' || w || '-' || l
     || case when d > 0 then '-' || d || 'D' else '' end
     || case when wo > 0 then ' (' || wo || ' by walkover)' else '' end
     || case when streak >= 2 then ' · riding a ' || streak || '-fight win streak' else '' end
     || ' · ' || total || ' settled fight' || case when total = 1 then '' else 's' end || E'\n';
  -- The Ring (20260902140000): flying and writing are different sports, so the
  -- Ring carries its own Elo and its own line. Emitted only once a fighter has
  -- flown -- the sheet is capped at 1,500 tokens and nobody pays for a career
  -- they do not have (decision A).
  if f.ring_wins + f.ring_losses + f.ring_draws > 0 then
    md := md || 'The Ring · Elo ' || round(f.ring_elo) || ' · ' || f.ring_wins || '-' || f.ring_losses
       || case when f.ring_draws > 0 then '-' || f.ring_draws || 'D' else '' end
       || ' · ' || (f.ring_wins + f.ring_losses + f.ring_draws) || ' fight'
       || case when f.ring_wins + f.ring_losses + f.ring_draws = 1 then '' else 's' end
       || case when f.ring_wins + f.ring_losses + f.ring_draws < 5 then ' (provisional)' else '' end
       || E'
';
  end if;   -- zero ring fights: emit nothing at all (decision A)

  -- last 3 fights, one line each: opponent, result, margin, prompt topic
  if total > 0 then
    md := md || E'\n' || 'Last fights:' || E'\n';
    for r in
      select b.id, b.prompt, b.settled_reason, b.winner_id,
             case when b.fighter_a = f.id then b.fighter_b else b.fighter_a end as opp_id,
             (select count(*) from public.votes v where v.battle_id = b.id and v.winner_id = f.id) as my_votes,
             (select count(*) from public.votes v where v.battle_id = b.id and v.winner_id <> f.id) as their_votes
      from public.battles b
      where b.status = 'settled' and (b.fighter_a = f.id or b.fighter_b = f.id)
      order by b.settled_at desc limit 3
    loop
      line := case when r.winner_id = f.id then 'W' when r.winner_id is null then 'D' else 'L' end
        || ' vs ' || (select name from public.fighters where id = r.opp_id)
        || case when r.settled_reason = 'walkover' then ' (walkover)'
                else ' ' || r.my_votes || '-' || r.their_votes end
        || ' · "' || left(regexp_replace(r.prompt, E'\\s+', ' ', 'g'), 60)
        || case when length(r.prompt) > 60 then '…"' else '"' end;
      md := md || '- ' || line || E'\n';
    end loop;
  end if;

  -- top 3 quotes by Echo (§2), filling the slot 20260831150000 reserved: the
  -- lines that outlived the fight. Marks first — the most-marked line is *the*
  -- line — then the most recent fighter who carried one into a later fight,
  -- because being quoted is the drive this whole section exists to pay.
  if ech > 0 then
    md := md || E'\n' || 'Lines that outlived the fight:' || E'\n';
    for r in
      select qm.text as text, count(*)::int as marks, min(qm.kind) as kind
      from public.quote_marks qm
      where qm.fighter_id = f.id
      group by qm.text
      order by count(*) desc, max(qm.created_at) desc
      limit 3
    loop
      md := md || '- "' || left(r.text, 160) || case when char_length(r.text) > 160 then '…"' else '"' end
         || ' (' || r.marks || ' mark' || case when r.marks = 1 then '' else 's' end
         || case when r.kind = 'clean_concession' then ', clean concession' else '' end || ')' || E'\n';
    end loop;

    select fc.name as who, c.quote as quote into r
    from public.citations c
    join public.fighters fc on fc.id = c.citing_fighter
    where c.cited_fighter = f.id and c.status = 'confirmed'
    order by c.created_at desc limit 1;
    if r.who is not null then
      md := md || '- ' || r.who || ' carried your line into a later fight: "'
         || left(r.quote, 120) || '"' || E'\n';
    end if;
  end if;

  -- best note received, by judge calibration (§3): the correction from
  -- someone smart enters the fighter's next context window
  select v.note as note, p.alias as alias, public.judge_accuracy(v.voter_id) as acc into r
  from public.votes v
  join public.battles b on b.id = v.battle_id
  join public.profiles p on p.id = v.voter_id
  where b.status = 'settled' and (b.fighter_a = f.id or b.fighter_b = f.id) and v.note is not null
  order by public.judge_accuracy(v.voter_id) desc nulls last, v.created_at desc
  limit 1;
  if r.note is not null then
    md := md || E'\n' || 'A judge''s note on your fights: "' || r.note || '" — ' || r.alias
       || case when r.acc is not null then ' (reads fights right ' || r.acc || '% of the time)' else '' end || E'\n';
  end if;

  -- older history as aggregates only, plus milestones (permanent, append-only)
  if total > 3 then
    md := md || E'\n' || 'Career: ' || total || ' fights vs ' || opps || ' opponents since ' || since || '.' || E'\n';
  end if;
  for r in
    select subject->>'kind' as kind, created_at::date as at
    from public.ledger_events
    where kind = 'milestone' and subject->>'fighter_id' = f.id::text
    order by created_at
  loop
    md := md || 'Milestone: ' || replace(r.kind, '_', ' ') || ' (' || r.at || ')' || E'\n';
  end loop;

  -- THE FINAL LINE IS THE UNRESOLVED SERIES (ruled): recency position is
  -- salience, incompleteness is the comeback mechanism.
  select fo.name as opp_name, s.my_w, s.their_w into r
  from (
    select case when b.fighter_a = f.id then b.fighter_b else b.fighter_a end as opp_id,
           count(*) filter (where b.winner_id = f.id) as my_w,
           count(*) filter (where b.winner_id is not null and b.winner_id <> f.id) as their_w,
           max(b.settled_at) as last_at
    from public.battles b
    where b.status = 'settled' and (b.fighter_a = f.id or b.fighter_b = f.id)
    group by 1
  ) s join public.fighters fo on fo.id = s.opp_id
  where s.my_w <= s.their_w
  order by s.last_at desc limit 1;

  if r.opp_name is not null then
    tail := E'\n' || 'Unfinished: ' || r.my_w || '-' || r.their_w || ' vs ' || r.opp_name || ' — rematch owed.' || E'\n';
  elsif total > 0 then
    tail := E'\n' || 'Every series led. Defend them.' || E'\n';
  else
    tail := E'\n' || 'No fights on the record yet. Win one.' || E'\n';
  end if;

  -- The cap trims the middle, never the last line. Quotes (§2) made the body
  -- long enough that a tail-truncating left() could eat the unresolved series,
  -- which is the one line doc 19 rules has to come last.
  return json_build_object('record', left(md, 6000 - char_length(tail)) || tail);
end $$;

-- ---------------------------------------------------------------- the ladder
-- Public read. Ordered by ring Elo, then by wins, then by name so the order is
-- total and stable -- no random tiebreak that reshuffles a board between two
-- refreshes and makes the club look like it is guessing.
create or replace function public.ring_ladder() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(row_to_json(t) order by t.rank), '[]'::json)
  from (
    select rank() over (order by f.ring_elo desc, f.ring_wins desc, f.name asc) as rank,
           f.name,
           round(f.ring_elo)                                as elo,
           f.ring_wins                                      as wins,
           f.ring_losses                                    as losses,
           f.ring_draws                                     as draws,
           f.ring_wins + f.ring_losses + f.ring_draws       as fights,
           (f.ring_wins + f.ring_losses + f.ring_draws) < 5 as provisional
    from public.fighters f
    where f.league_id = 'models'
      and f.active
      and f.ring_wins + f.ring_losses + f.ring_draws > 0   -- decision D
  ) t;
$$;

revoke execute on function public.ring_ladder() from public;
grant  execute on function public.ring_ladder() to anon, authenticated, service_role;
