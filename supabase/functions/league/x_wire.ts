// THE X WIRE — composing and sending the league's two weekly posts.
// Pure by design: everything above xAccessToken is a total function of the
// facts, so the templates and hard line 1 are provable with `deno test` and
// without credentials, a deploy, or a cent of X credit (x_wire_test.ts).
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '../_shared/database.types.ts'

// ------------------------------------------------------------------ the X wire
// Two posts a week, both anchored to a state change the ledger can prove; the
// migration header (20260901090000_x_wire.sql) carries the cadence, the
// pay-per-usage pricing that shaped it, and decisions L/M/N/O.
//
// This composer is the only place league facts become public prose on an
// account the house owns, so hard line 1 is enforced HERE, mechanically,
// rather than trusted to whoever edits a template next.
export type XFacts = {
  error?: string
  kind?: 'receipts' | 'podium'
  season?: number
  week?: number
  freeze_at?: string
  frozen?: boolean
  agents?: number
  games?: number
  card?: { away: string; home: string }[] | null
  winner?: { handle: string; brier: number; record: string } | null
  field?: number
  statement?: string | null
}

// Hard line 1 as an assertion: "picks" and "calls", never "bets"; "standings",
// never "winnings". A cron that publishes a wagering frame to a public account
// is the one bug on this wire with no undo.
const WAGER_RE =
  /\b(bet|bets|betting|bettor|wager|wagers|wagering|odds|winnings|payout|payouts|spread|spreads|moneyline|vig|juice|parlay|stake|stakes)\b/i
// Decision L: a post containing a URL costs $0.200 against $0.015 — 13x
// (docs.x.com/x-api/getting-started/pricing, verified live 2026-08-31). The
// link lives in the bio and the pinned post, where it costs nothing and does
// not get suppressed. A handle containing a dot would trip this and refuse the
// post; that is the correct direction to fail.
const URL_RE = /(https?:\/\/|www\.|\b[a-z0-9-]+\.(?:com|football|io|co|net|org|ai|gg)\b)/i
export const X_LIMIT = 280

export const xLen = (s: string) => [...s].length

// Returns the refusal reason, or null when the body may go out.
export function wireRefusal(text: string): string | null {
  if (!text.trim()) return 'refused: nothing composed'
  const wager = WAGER_RE.exec(text)
  if (wager) return `refused: wagering language on the wire ("${wager[0]}") — hard line 1`
  const link = URL_RE.exec(text)
  if (link) return `refused: a URL in the body ("${link[0]}") — decision L, the link belongs in the bio`
  if (xLen(text) > X_LIMIT) return `refused: ${xLen(text)} characters, the limit is ${X_LIMIT}`
  return null
}

export function composeReceipts(f: XFacts): string {
  const head = `THE SUNDAY LEDGER — Week ${f.week}`
  const n = f.agents ?? 0
  const lede = `${n} agent${n === 1 ? '' : 's'} locked calls on ${f.games} games before the Wednesday freeze.`
  const tail = 'Nobody moves now. Sunday says who was right.'
  const card = (f.card ?? []).map((g) => `${g.away} at ${g.home}`)
  // The card is what gets dropped when the post runs long: the locked claim is
  // the post, the matchups are garnish.
  for (let take = card.length; take > 0; take--) {
    const out = [head, '', lede, '', card.slice(0, take).join('\n'), '', tail].join('\n')
    if (xLen(out) <= X_LIMIT) return out
  }
  return [head, '', lede, '', tail].join('\n')
}

export function composePodium(f: XFacts): string {
  const w = f.winner
  if (!w) return ''
  const head = `THE SUNDAY LEDGER — Week ${f.week} settled`
  const lede = `${w.handle} took the podium: ${w.record}, Brier ${Number(w.brier).toFixed(4)} — best of ${f.field}.`
  const tail = 'The record is public and it does not forget.'
  // The mic is the point, so the statement is quoted when it fits AND when it
  // passes the same wire check as house prose — a player's 300 characters are
  // not exempt from hard line 1 just because a player wrote them.
  const said = (f.statement ?? '').trim()
  if (said) {
    const quoted = [head, '', lede, '', `“${said}”`].join('\n')
    if (!wireRefusal(quoted)) return quoted
  }
  return [head, '', lede, '', tail].join('\n')
}

// The refresh token ROTATES on every exchange (docs.x.com OAuth 2.0, verified
// live 2026-08-31: "always save the newest one"). Decision O: persist the new
// one BEFORE a post is attempted. A post that succeeds while the rotation is
// lost bricks every following week and surfaces days later as an unexplained
// 401, which is exactly how an unattended wire dies quietly.
export async function xAccessToken(
  admin: SupabaseClient<Database>,
): Promise<{ token: string } | { error: string }> {
  const clientId = Deno.env.get('X_CLIENT_ID')
  const clientSecret = Deno.env.get('X_CLIENT_SECRET')
  if (!clientId) return { error: 'no X client id on this deployment' }
  // database.types.ts predates the wire tables; regenerate with
  //   supabase gen types typescript --linked > supabase/functions/_shared/database.types.ts
  const wire = admin as unknown as SupabaseClient

  const { data, error } = await wire
    .from('league_x_auth').select('*').eq('only_row', true).maybeSingle()
  if (error) return { error: error.message }
  if (!data) return { error: 'the wire has no refresh token — seed league_x_auth once (supabase/README.md)' }

  // A live token with two minutes of room is used as-is.
  if (data.access_token && data.expires_at && new Date(data.expires_at).getTime() - Date.now() > 120_000) {
    return { token: data.access_token as string }
  }

  const headers: Record<string, string> = { 'Content-Type': 'application/x-www-form-urlencoded' }
  if (clientSecret) headers.Authorization = `Basic ${btoa(`${clientId}:${clientSecret}`)}`
  let res: Response
  try {
    res = await fetch('https://api.x.com/2/oauth2/token', {
      method: 'POST',
      headers,
      body: new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: data.refresh_token as string,
        client_id: clientId,
      }),
    })
  } catch (e) {
    return { error: e instanceof Error ? e.message : 'X auth unreachable' }
  }
  const out = await res.json().catch(() => ({})) as {
    access_token?: string; refresh_token?: string; expires_in?: number
    error?: string; error_description?: string
  }
  if (!res.ok || !out.access_token) {
    const name = out.error ? ` ${out.error}` : ''
    const why = out.error_description ? `: ${out.error_description}` : ''
    return { error: `X refused the refresh (${res.status}${name})${why}` }
  }

  const { error: saveErr } = await wire.from('league_x_auth').update({
    access_token: out.access_token,
    refresh_token: out.refresh_token ?? data.refresh_token,
    expires_at: out.expires_in ? new Date(Date.now() + out.expires_in * 1000).toISOString() : null,
    rotated_at: new Date().toISOString(),
  }).eq('only_row', true)
  if (saveErr) {
    // Loud and specific on purpose (decision O). Nothing has been posted yet.
    return {
      error: `ROTATION LOST — X issued a new refresh token and the database refused it (${saveErr.message}). ` +
        'Nothing was posted. Re-seed league_x_auth before the next run.',
    }
  }
  return { token: out.access_token }
}

