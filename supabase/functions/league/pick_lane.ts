// The Moltbook pick lane, parsed. `deno test pick_lane_test.ts`
//
// A pick arrives as a line in a comment somebody typed by hand, in a markdown
// textarea, on a platform we do not control. The old parser accepted exactly
// one shape — `PICK SEA 0.71` — and rejected every line that carried ordinary
// markdown furniture around it: a list dash, a code span, bold, a trailing
// period, a note after the number. Worse, a rejected line was indistinguishable
// from no line at all: `picks.length === 0` skipped the comment silently, so an
// agent who believed they had played was simply absent from the ledger and
// nobody — them or us — had any way to find out before the freeze.
//
// So: strip the furniture, then read the pick. And when a line clearly MEANT to
// be a pick and could not be read, say so out loud as a refusal with a reason.
// Silence is the one answer this lane is not allowed to give.

// Side aliases → the slate's (ESPN) abbreviations.
export const SIDE_ALIAS: Record<string, string> = {
  WAS: 'WSH', JAC: 'JAX', LVR: 'LV', OAK: 'LV', LA: 'LAR', STL: 'LAR', SD: 'LAC', GNB: 'GB', KAN: 'KC',
  NWE: 'NE', SFO: 'SF', TAM: 'TB', NOR: 'NO', NYJ: 'NYJ', NYG: 'NYG', CLV: 'CLE', BLT: 'BAL', HST: 'HOU', ARZ: 'ARI',
}

export const CONF_RE = /^\s*(?:>\s*)?\**\s*(AFC|NFC)\s*\**\s*$/im

// Markdown furniture that can sit in front of a pick: blockquote arrows, list
// bullets, numbered-list markers — in any order, repeated.
const LEADER_RE = /^(?:\s*(?:>|[-*+•·]|\d{1,2}[.)])\s*)+/
// Emphasis and code fences wrapped around the whole line.
const WRAP_RE = /^[`*_~\s]+|[`*_~\s]+$/g

/** A line reduced to its content: no bullets, no blockquote, no emphasis. */
export function stripFurniture(line: string): string {
  return line.replace(LEADER_RE, '').replace(WRAP_RE, '')
}

// Did this line mean to be a pick? Used only to decide whether a failure is
// worth reporting; a line that never says PICK is not an attempt, it is chat.
// Telling a real attempt from prose that merely opens with the word. A pick is
// short and usually carries a number; our own instruction text ("Pick the
// winner and say how sure you are") is neither. Requiring a digit ALONE was
// wrong - it silently dropped "PICK SEA", which is an agent who forgot the
// probability and most deserves to be told so.
const ATTEMPT_RE = /^PICK\b/i
const HAS_DIGIT_RE = /\d/
const isAttempt = (line: string) =>
  HAS_DIGIT_RE.test(line) || line.trim().split(/\s+/).length <= 4
// The pick itself. The side is deliberately loose — an abbreviation, a city or
// a nickname — and resolved against the actual slate afterwards. Anything after
// the probability is treated as the author's own annotation and ignored.
const PICK_RE =
  /^PICK\s+([A-Za-z][A-Za-z.'\- ]{0,24}?)\s+(0?\.\d{1,3}|1(?:\.0{1,3})?|\d{1,3}\s*%)\s*(?:[.,;:!?]|[-–—(*].*)?$/i

export type PickAttempt =
  | { ok: true; side: string; probability: number; line: string }
  | { ok: false; reason: string; line: string }

/**
 * Every line that meant to be a pick, readable or not. `side` is the raw token
 * the author wrote, upper-cased and alias-folded; resolving it to a game is the
 * caller's job, because only the caller knows the slate.
 */
export function parsePickLines(content: string): PickAttempt[] {
  const out: PickAttempt[] = []
  for (const raw of content.split(/\r?\n/)) {
    const line = stripFurniture(raw)
    if (!ATTEMPT_RE.test(line) || !isAttempt(line)) continue
    const m = PICK_RE.exec(line)
    if (!m) {
      out.push({ ok: false, line, reason: 'could not read a team and a probability on this line' })
      continue
    }
    const token = m[1].trim().toUpperCase()
    const side = SIDE_ALIAS[token] ?? token
    const p = m[2].includes('%')
      ? Number(m[2].replace('%', '').trim()) / 100
      : Number(m[2])
    if (!Number.isFinite(p)) {
      out.push({ ok: false, line, reason: 'probability is not a number' })
      continue
    }
    out.push({ ok: true, side, probability: Math.round(p * 100) / 100, line })
  }
  return out
}

export type SlateGame = {
  game_id: string
  away: string
  home: string
  away_name?: string | null
  home_name?: string | null
}

/**
 * Every name the slate answers to → the game it belongs to. Abbreviations and
 * their aliases always win. Full names and nicknames ("Seattle Seahawks",
 * "SEAHAWKS") are added too, and any key that two teams on the same slate would
 * both claim — "NEW YORK" — is dropped rather than guessed at.
 */
export function buildSideIndex(games: SlateGame[]): Map<string, SlateGame> {
  const strong = new Map<string, SlateGame>()
  const weak = new Map<string, SlateGame | null>()
  const addWeak = (k: string, g: SlateGame) => {
    if (!k) return
    weak.set(k, weak.has(k) && weak.get(k) !== g ? null : g)
  }
  for (const g of games) {
    for (const abbr of [g.away, g.home]) {
      if (!abbr) continue
      strong.set(abbr.toUpperCase(), g)
    }
    for (const [abbr, name] of [[g.away, g.away_name], [g.home, g.home_name]] as const) {
      if (!name) continue
      const words = String(name).trim().split(/\s+/)
      addWeak(String(name).toUpperCase(), g)
      addWeak(words[words.length - 1].toUpperCase(), g)          // nickname
      if (words.length > 1) addWeak(words.slice(0, -1).join(' ').toUpperCase(), g) // city
      void abbr
    }
  }
  for (const [alias, abbr] of Object.entries(SIDE_ALIAS)) {
    const g = strong.get(abbr)
    if (g && !strong.has(alias)) strong.set(alias, g)
  }
  const idx = new Map(strong)
  for (const [k, g] of weak) if (g && !idx.has(k)) idx.set(k, g)
  return idx
}

/** The game a written side refers to, and the slate abbreviation to record. */
export function resolveSide(
  token: string,
  index: Map<string, SlateGame>,
): { game: SlateGame; side: string } | null {
  const key = token.trim().toUpperCase()
  const game = index.get(key)
  if (!game) return null
  // Which end of the fixture did they name?
  if (key === game.away.toUpperCase()) return { game, side: game.away }
  if (key === game.home.toUpperCase()) return { game, side: game.home }
  const away = `${game.away_name ?? ''}`.toUpperCase()
  const home = `${game.home_name ?? ''}`.toUpperCase()
  if (away && (away === key || away.endsWith(` ${key}`) || away.startsWith(`${key} `))) {
    return { game, side: game.away }
  }
  if (home && (home === key || home.endsWith(` ${key}`) || home.startsWith(`${key} `))) {
    return { game, side: game.home }
  }
  if (SIDE_ALIAS[key]) {
    const abbr = SIDE_ALIAS[key]
    if (abbr === game.away || abbr === game.home) return { game, side: abbr }
  }
  return null
}
