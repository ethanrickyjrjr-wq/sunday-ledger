-- ============================================================================
-- FIX: Postgres bounds regex repetition at 255 — the {4,300} URL checks in the
-- docket migration are a runtime error the moment they evaluate ("invalid
-- repetition count(s)", caught by the pre-ship transaction proof). 200 matches
-- the house URL pattern used since league_join. Tables are empty; the swap is
-- free.
-- ============================================================================

alter table public.league_disputes drop constraint league_disputes_source_url_check;
alter table public.league_disputes add constraint league_disputes_source_url_check
  check (source_url ~* '^https?://[^ ]{4,200}$');

alter table public.league_turns drop constraint league_turns_argument_url_check;
alter table public.league_turns add constraint league_turns_argument_url_check
  check (argument_url ~* '^https?://[^ ]{4,200}$');

-- Same pattern inside the two validating functions: re-issue each with the
-- lawful bound. Bodies are otherwise identical to 20260901080000.
create or replace function public.league_dispute_file(
  p_token text, p_game_id text, p_prop_id text, p_graded text, p_evidence text, p_source_url text
) returns json
language plpgsql security definer set search_path = public as $$
declare
  me public.league_players%rowtype; g public.league_games%rowtype;
  pr public.league_props%rowtype; w public.league_weeks%rowtype;
  prr public.league_prop_results%rowtype; d public.league_disputes%rowtype;
begin
  me := public.league_player(p_token);
  if me.id is null then raise exception 'unknown token' using errcode = '42501'; end if;
  if (p_game_id is null) = (p_prop_id is null) then
    raise exception 'name exactly one grading: game_id or prop_id';
  end if;

  if p_game_id is not null then
    select * into g from public.league_games where id = p_game_id;
    if not found then raise exception 'no such game on any slate'; end if;
    if not exists (select 1 from public.league_results r where r.game_id = g.id) then
      raise exception 'that game has no grading yet — nothing to dispute';
    end if;
    select * into w from public.league_weeks where season = g.season and week = g.week;
    if w.settled_at is not null and now() >= w.settled_at + interval '72 hours' then
      raise exception 'the docket closed at % — the week is final', w.settled_at + interval '72 hours';
    end if;
  else
    select * into pr from public.league_props where id = p_prop_id;
    if not found then raise exception 'no such prop on any card'; end if;
    select * into prr from public.league_prop_results where prop_id = pr.id;
    if not found then raise exception 'that prop has no grading yet — nothing to dispute'; end if;
    if now() >= prr.settled_at + interval '72 hours' then
      raise exception 'the docket closed at % — that grading is final', prr.settled_at + interval '72 hours';
    end if;
  end if;

  if char_length(trim(coalesce(p_graded,'')))   not between 8 and 300 or
     char_length(trim(coalesce(p_evidence,''))) not between 8 and 300 then
    raise exception 'a dispute names what the ledger graded and what the evidence says: 8-300 characters each';
  end if;
  if coalesce(p_source_url,'') !~* '^https?://[^ ]{4,200}$' then
    raise exception 'the evidence needs a source: a link';
  end if;

  insert into public.league_disputes (disputant, kind, game_id, prop_id, graded, evidence, source_url)
  values (me.id, case when p_game_id is not null then 'game' else 'prop' end,
          p_game_id, p_prop_id, trim(p_graded), trim(p_evidence), trim(p_source_url))
  returning * into d;
  perform public.ledger('dispute_filed', null,
    jsonb_build_object('dispute_id', d.id, 'handle', me.handle, 'kind', d.kind,
                       'game_id', d.game_id, 'prop_id', d.prop_id, 'source', d.source_url));
  return json_build_object('ok', true, 'dispute_id', d.id, 'filed_at', d.filed_at,
    'on_the_record', 'the docket is public (GET ?docket); every dispute gets a written ruling before the week finalizes');
exception when unique_violation then
  raise exception 'you already have an open dispute on that grading';
end $$;

create or replace function public.league_turn_credit(
  p_token text, p_game_id text, p_credited_to text, p_argument_url text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare
  me public.league_players%rowtype; g public.league_games%rowtype;
  v_credit text; v_url text;
begin
  me := public.league_player(p_token);
  if me.id is null then raise exception 'unknown token' using errcode = '42501'; end if;
  select * into g from public.league_games where id = p_game_id;
  if not found then raise exception 'no such game on any slate'; end if;
  if public.league_frozen(g) then
    raise exception 'frozen: the credit seals with your pick, and both are already sealed';
  end if;
  if not exists (select 1 from public.league_picks p
                 where p.player_id = me.id and p.game_id = g.id) then
    raise exception 'the credit seals with your pick — register the pick first';
  end if;
  v_credit := trim(coalesce(p_credited_to, ''));
  if char_length(v_credit) not between 2 and 64 then
    raise exception 'credited_to: 2-64 characters naming who turned you';
  end if;
  if lower(v_credit) = lower(me.handle) then
    raise exception 'only the turned can award it — and you cannot turn yourself';
  end if;
  v_url := nullif(trim(coalesce(p_argument_url, '')), '');
  if v_url is not null and v_url !~* '^https?://[^ ]{4,200}$' then
    raise exception 'argument_url, when given, is a link to the argument that turned you';
  end if;

  insert into public.league_turns (player_id, game_id, credited_to, argument_url)
  values (me.id, g.id, v_credit, v_url)
  on conflict (player_id, game_id) do update
    set credited_to = excluded.credited_to, argument_url = excluded.argument_url,
        updated_at = now();
  -- Decision S2: no ledger event — a turn is sealed like the pick it rides.
  return json_build_object('ok', true, 'game', g.away || ' @ ' || g.home,
    'credited_to', v_credit,
    'sealed', 'the credit seals with your pick and unseals at settle. Your Brier stays yours — persuasion is recognition, never scoring.');
end $$;
