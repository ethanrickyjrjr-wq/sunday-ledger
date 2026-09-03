-- ============================================================================
-- VERIFICATION HARNESS for 20260903140000_carry_and_alarm.sql
--
-- The carry path could not be proven against the live ledger on the day it
-- shipped: the 2026 opener kicks 2026-09-10 03:20Z, so no real game was yet
-- three hours past kickoff and ?carry correctly refused every one of them.
-- Asserting the guards fire is not the same as asserting the mechanism works.
--
-- So this builds a synthetic season, drives it through the whole postponement
-- lifecycle, asserts every step, and deletes itself.
--
-- WHY IT IS SAFE ON A LIVE DATABASE WITH A REAL PLAYER ON THE ROLL:
--
--   * It is ONE `do` block. A single statement is atomic, so the fixtures are
--     never visible to any concurrent reader at any isolation level: they are
--     created and removed inside the same statement. ?week, ?standings and
--     the hourly alarm cannot observe them even mid-run.
--   * Seasons 1901/1902 cannot collide. ?week reads `order by season desc
--     limit 1`, so it keeps returning 2026. league_scores() admits a game only
--     from a player's first picked week onward (202601 <= 190101 is false), so
--     no real Brier, W-L, coverage_rate or standing can move. ?hall needs a
--     week 18 in the season and there is none.
--   * league_sweep.last_run is saved and restored, so the read-path throttle
--     is left exactly as found.
--   * Every fixture row, including its ledger_events, is removed before the
--     block ends. Net rows changed: zero.
--
--   * Any failed assertion RAISES, which aborts the push and rolls everything
--     back. Silence here means all fifteen assertions passed.
--
-- THE FIRST RUN CAUGHT A BUG IN THIS HARNESS, NOT IN THE CODE: now() is the
-- TRANSACTION timestamp, so every default settled_at inside one block is the
-- same instant, and a "late" grading was not actually later than the week
-- stamp. The week stamp is now backdated to simulate the days that really pass
-- before a postponed game is replayed (step 8).
-- ============================================================================

do $harness$
declare
  v_health   json;
  v_settled  timestamptz;
  v_final_at timestamptz;
  v_gate     json;
  v_last     timestamptz;
  v_res_at   timestamptz;
  v_carry    json;
begin
  -- Leave the read-path throttle exactly as we found it.
  select last_run into v_last from public.league_sweep where only_row;

  -- ------------------------------------------------------------- fixtures
  insert into public.league_weeks (season, week, freeze_at, main_card)
  values (1901, 1, now() - interval '3 days',
          array['slverify_g1','slverify_g2','mc3','mc4','mc5','mc6']);

  insert into public.league_games (id, season, week, kickoff, away, home, away_name, home_name)
  values ('slverify_g1', 1901, 1, now() - interval '30 hours', 'AAA', 'BBB', 'Aye', 'Bee'),
         ('slverify_g2', 1901, 1, now() - interval '30 hours', 'CCC', 'DDD', 'Cee', 'Dee');

  -- 1. Two games 30h past kickoff, ungraded, uncarried: the alarm must fire.
  v_health := public.league_settle_health();
  if (v_health->>'ok')::boolean then
    raise exception 'A1 FAILED: health.ok is true with two games 30h overdue';
  end if;
  if (select count(*) from json_array_elements(v_health->'stuck') e
      where e->>'game_id' in ('slverify_g1','slverify_g2')) <> 2 then
    raise exception 'A1b FAILED: both overdue games should be listed stuck, got %',
      v_health->'stuck';
  end if;

  -- 2. Grade ONE of them through the real settle path. The week must NOT
  --    stamp: the other game is ungraded and nobody carried it. This is the
  --    fault the migration fixes, asserted from the other direction.
  perform public.league_settle(
    jsonb_build_array(jsonb_build_object(
      'id','slverify_g1','away_score',20,'home_score',17,'winner','AAA')));
  select settled_at into v_settled from public.league_weeks where season = 1901 and week = 1;
  if v_settled is not null then
    raise exception 'A2 FAILED: week stamped with an uncarried ungraded game still on the slate';
  end if;
  if not exists (select 1 from public.league_results where game_id = 'slverify_g1') then
    raise exception 'A2b FAILED: league_settle did not write the final it was handed';
  end if;

  -- 3. The sweep gate must still be chasing the ungraded game (C6, before).
  update public.league_sweep set last_run = 'epoch' where only_row;
  v_gate := public.league_sweep_gate();
  if not (v_gate->>'due')::boolean or (v_gate->>'season')::int <> 1901 then
    raise exception 'A3 FAILED: gate should be due on season 1901, got %', v_gate;
  end if;

  -- 4. Carry the postponed game. THIS is the mechanism that could not be
  --    exercised live, and the week must stamp on the strength of it alone.
  v_carry := public.league_carry('slverify_g2', 'Verification harness: postponed under section 7.');
  if not (v_carry->>'week_settled')::boolean then
    raise exception 'A4 FAILED: carrying the last ungraded game did not settle the week, got %', v_carry;
  end if;
  select settled_at into v_settled from public.league_weeks where season = 1901 and week = 1;
  if v_settled is null then
    raise exception 'A4b FAILED: settled_at is still null after the carry';
  end if;

  -- 5. The carried game leaves stuck and appears under carried; the alarm
  --    goes quiet WITHOUT the game having been graded.
  v_health := public.league_settle_health();
  if not (v_health->>'ok')::boolean then
    raise exception 'A5 FAILED: health still red after the only overdue game was carried, got %',
      v_health->'stuck';
  end if;
  if exists (select 1 from json_array_elements(v_health->'stuck') e
             where e->>'game_id' = 'slverify_g2') then
    raise exception 'A5b FAILED: a carried game is still reported stuck';
  end if;
  if not exists (select 1 from json_array_elements(v_health->'carried') e
                 where e->>'game_id' = 'slverify_g2') then
    raise exception 'A5c FAILED: the carried game is not reported under carried';
  end if;

  -- 6. C6: the gate must stop chasing a game nobody is playing. Before this
  --    migration an ungraded game kept the gate due forever, so every read
  --    paid a score-source fetch every five minutes, indefinitely.
  update public.league_sweep set last_run = 'epoch' where only_row;
  v_gate := public.league_sweep_gate();
  if (v_gate->>'due')::boolean and (v_gate->>'season')::int = 1901 then
    raise exception 'A6 FAILED: the gate is still chasing a carried game';
  end if;

  -- 7. C3: the week is settled, but it is NOT final while a game is owed.
  --    A closed docket over an ungraded game is the bug this prevents.
  v_final_at := public.league_week_final_at(1901, 1);
  if v_final_at is not null then
    raise exception 'A7 FAILED: week_final_at is % with a game still ungraded', v_final_at;
  end if;
  if public.league_week_final(1901, 1) then
    raise exception 'A7b FAILED: week reports final with a game still ungraded';
  end if;

  -- 8. Simulate the days that pass before a postponed game is replayed.
  --    now() is the TRANSACTION timestamp, so every default settled_at inside
  --    this block is the same instant; without backdating the week stamp a
  --    "late" grading is not actually later and the window test is vacuous.
  --    (This is what A9c caught on the first run -- the harness, not the code.)
  update public.league_weeks set settled_at = settled_at - interval '5 days'
   where season = 1901 and week = 1;
  select settled_at into v_settled from public.league_weeks where season = 1901 and week = 1;

  --    The late grading lands. Section 7: appended to its ORIGINAL week.
  insert into public.league_results (game_id, away_score, home_score, winner)
  values ('slverify_g2', 13, 27, 'DDD');
  select settled_at into v_res_at from public.league_results where game_id = 'slverify_g2';

  -- 9. C3/C4: the window now runs from the LATE grading, not the week stamp --
  --    "its own 72-hour dispute window", which is the whole promise.
  v_final_at := public.league_week_final_at(1901, 1);
  if v_final_at is null then
    raise exception 'A9 FAILED: week_final_at is still null after every game graded';
  end if;
  if v_final_at <> v_res_at + interval '72 hours' then
    raise exception 'A9b FAILED: window should run from the late grading (% + 72h), got %',
      v_res_at, v_final_at;
  end if;
  if v_final_at <= v_settled + interval '72 hours' then
    raise exception 'A9c FAILED: the late grading did not extend the window past the week stamp';
  end if;

  -- 10. The carried game is now graded, so it must have left `carried` too.
  v_health := public.league_settle_health();
  if not (v_health->>'ok')::boolean then
    raise exception 'A10 FAILED: health red once every game graded';
  end if;
  if exists (select 1 from json_array_elements(v_health->'carried') e
             where e->>'game_id' = 'slverify_g2') then
    raise exception 'A10b FAILED: a graded game is still reported carried';
  end if;

  -- 11. The record was written, not whispered: the carry is in the ledger.
  if not exists (select 1 from public.ledger_events
                 where kind = 'game_carried' and subject->>'game_id' = 'slverify_g2') then
    raise exception 'A11 FAILED: the carry left no ledger_events row';
  end if;

  -- 12. THE NO-CHANGE CLAIM. An ordinary week -- every game graded in the same
  --     sweep that stamps it, nothing carried -- must still go final at
  --     exactly settled_at + 72h. This is the claim that makes C3 a narrow
  --     fix rather than a change to the docket everyone already lives under.
  insert into public.league_weeks (season, week, freeze_at, main_card)
  values (1902, 1, now() - interval '3 days',
          array['slverify_h1','slverify_h2','mc3','mc4','mc5','mc6']);
  insert into public.league_games (id, season, week, kickoff, away, home, away_name, home_name)
  values ('slverify_h1', 1902, 1, now() - interval '30 hours', 'EEE', 'FFF', 'Eee', 'Eff'),
         ('slverify_h2', 1902, 1, now() - interval '30 hours', 'GGG', 'HHH', 'Gee', 'Aitch');

  perform public.league_settle(jsonb_build_array(
    jsonb_build_object('id','slverify_h1','away_score',24,'home_score',21,'winner','EEE'),
    jsonb_build_object('id','slverify_h2','away_score',10,'home_score',31,'winner','HHH')));

  select settled_at into v_settled from public.league_weeks where season = 1902 and week = 1;
  if v_settled is null then
    raise exception 'A12 FAILED: an ordinary complete week did not stamp';
  end if;
  v_final_at := public.league_week_final_at(1902, 1);
  if v_final_at is distinct from v_settled + interval '72 hours' then
    raise exception 'A12b FAILED: ordinary week should go final at settled_at + 72h (%), got %',
      v_settled + interval '72 hours', v_final_at;
  end if;
  if public.league_settle_health()->>'ok' <> 'true' then
    raise exception 'A12c FAILED: health red on a fully graded ordinary week';
  end if;

  -- ---------------------------------------------------------------- cleanup
  delete from public.ledger_events
   where subject->>'season' in ('1901','1902')
      or subject->>'game_id' in ('slverify_g1','slverify_g2','slverify_h1','slverify_h2');
  delete from public.league_results
   where game_id in ('slverify_g1','slverify_g2','slverify_h1','slverify_h2');
  delete from public.league_games where season in (1901, 1902);
  delete from public.league_weeks where season in (1901, 1902);
  update public.league_sweep set last_run = v_last where only_row;

  if exists (select 1 from public.league_games where season in (1901, 1902))
     or exists (select 1 from public.league_weeks where season in (1901, 1902)) then
    raise exception 'CLEANUP FAILED: fixtures survived';
  end if;

  raise notice 'carry + alarm: 15/15 assertions passed, fixtures removed, throttle restored';
end $harness$;
