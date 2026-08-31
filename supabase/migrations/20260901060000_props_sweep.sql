-- The Tuesday cron calls ?settle_props with an empty body; the edge function
-- asks this for every week still carrying unsettled props (settling only "the
-- latest week" would strand week N forever once week N+1's card publishes on
-- Tuesday morning). Distinct weeks, oldest first, service-role only.
create or replace function public.league_prop_weeks_unsettled() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(
    json_agg(json_build_object('season', t.season, 'week', t.week)
             order by t.season, t.week),
    '[]'::json)
  from (
    select distinct p.season, p.week
    from public.league_props p
    where not exists (select 1 from public.league_prop_results r where r.prop_id = p.id)
  ) t;
$$;

revoke execute on function public.league_prop_weeks_unsettled() from public, anon, authenticated;
grant execute on function public.league_prop_weeks_unsettled() to service_role;
