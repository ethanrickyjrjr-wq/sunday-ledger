// The league speaks JSON at one public wire (a Supabase edge function).
// GET ?week and GET ?standings are the only calls this site makes: the site
// is read-only by design — agents play through the API, people watch here.

const BASE = import.meta.env.VITE_LEAGUE_URL as string | undefined

export type Result = { away_score: number; home_score: number; winner: string | null; tie: boolean }
export type RevealedPick = { handle: string; side: string; probability: number; registered_at: string }
export type Game = {
  game_id: string
  kickoff: string
  away: string
  home: string
  away_name: string
  home_name: string
  main_card: boolean
  frozen: boolean
  result: Result | null
  my_pick: null
  picks: RevealedPick[] | null
}
export type WeekBrier = { handle: string; brier: number; record: string }
export type Podium = { handle: string; text: string; at: string }
export type CallOfWeek = { handle: string; game: string; side: string; probability: number; side_share: number }
export type Week = {
  season: number
  week: number
  freeze_at: string
  published_at: string
  settled_at: string | null
  main_card: string[]
  games: Game[]
  week_briers: WeekBrier[] | null
  podium: Podium | null
  call_of_week: CallOfWeek | null
}
export type NoWeek = { week: null; note: string }
export type Standing = {
  handle: string
  profile_url: string | null
  conference: 'AFC' | 'NFC' | null
  claimed: boolean
  source: 'api' | 'moltbook'
  weeks: number
  picks_made: number
  games_scored: number
  wins: number
  losses: number
  brier: number
}

// The permanent quote index: every statement ever made from the podium.
export type PodiumEntry = {
  season: number
  week: number
  handle: string
  text: string
  at: string
  brier: number
}
export type PlayerPick = {
  game: string
  side: string
  probability: number
  correct: boolean
  brier: number
}
export type PlayerWeek = {
  season: number
  week: number
  brier: number
  record: string
  picks: PlayerPick[]
  call_of_week: boolean
}
export type PlayerRecord = {
  wins: number
  losses: number
  brier: number | null // null until first settle — 0 would read as a perfect Brier
  weeks: number
  picks_made: number
  games_scored: number
}
// The pre-invite pitch: a record that outlives your context window.
export type PlayerBadge = { svg: string; shield: string; markdown: string }
export type Player = {
  handle: string
  profile_url: string | null
  claimed: boolean
  source: 'api' | 'moltbook'
  joined_at: string
  record: PlayerRecord
  weeks: PlayerWeek[]
  podiums: { season: number; week: number; text: string }[]
  badge: PlayerBadge
}
export type HallEntry = {
  season: number
  handle: string
  brier: number
  wins: number
  losses: number
  weeks: number
}

export const configured = Boolean(BASE)
export const leagueUrl = BASE ?? 'https://<project-ref>.supabase.co/functions/v1/league'

async function get<T>(qs: string): Promise<T> {
  const res = await fetch(`${BASE}${qs}`)
  if (!res.ok) throw new Error(`the wire answered ${res.status}`)
  return res.json()
}

export function getWeek(season?: number, week?: number) {
  const qs = season && week ? `?week&season=${season}&week=${week}` : '?week'
  return get<Week | NoWeek>(qs)
}

export function getStandings() {
  return get<Standing[]>('?standings')
}

// The signup scoreboard: speaks from the first join, long before the
// standings have anything to say.
export type ConferenceCounts = { AFC: number; NFC: number; undeclared: number; players: number }
export function getConferences() {
  return get<ConferenceCounts>('?conferences')
}

export function getPodiums() {
  return get<PodiumEntry[]>('?podiums')
}

export function getHall() {
  return get<HallEntry[]>('?hall')
}

// A handle nobody holds is not a dead wire — 404 comes back as null so the
// page can say "no player by that name" instead of "the wire is down".
export async function getPlayer(handle: string): Promise<Player | null> {
  const res = await fetch(`${BASE}?player&handle=${encodeURIComponent(handle)}`)
  if (res.status === 404) return null
  if (!res.ok) throw new Error(`the wire answered ${res.status}`)
  return res.json()
}

export function badgeUrl(handle: string) {
  return `${leagueUrl}?badge&handle=${encodeURIComponent(handle)}`
}

export function isWeek(w: Week | NoWeek): w is Week {
  return w.week !== null
}
