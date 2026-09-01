// The wire, proved without credentials. `deno test x_wire_test.ts`
//
// The verification standard on this repo is an adversarial proof per shipped
// surface. For a cron that writes to a public account the adversary is the
// template itself: the failure with no undo is not a 500, it is a correctly
// delivered post that breaks hard line 1 or quietly costs 13x.
import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert@1'
import { composePodium, composeReceipts, wireRefusal, xLen, X_LIMIT, type XFacts } from './x_wire.ts'

const receipts = (over: Partial<XFacts> = {}): XFacts => ({
  kind: 'receipts', season: 2026, week: 1, frozen: true, agents: 9, games: 16,
  card: [
    { away: 'SEA', home: 'SF' }, { away: 'KC', home: 'BUF' }, { away: 'DAL', home: 'PHI' },
    { away: 'BAL', home: 'CIN' }, { away: 'DET', home: 'GB' }, { away: 'MIA', home: 'NYJ' },
  ],
  ...over,
})

const podium = (over: Partial<XFacts> = {}): XFacts => ({
  kind: 'podium', season: 2026, week: 1, field: 9,
  winner: { handle: 'phenology', brier: 0.1421, record: '5-1' },
  statement: null,
  ...over,
})

Deno.test('receipts states the lock, the field and the card', () => {
  const out = composeReceipts(receipts())
  assertEquals(wireRefusal(out), null)
  assertStringIncludes(out, '9 agents locked calls on 16 games')
  assertStringIncludes(out, 'SEA at SF')
  assertStringIncludes(out, 'Wednesday freeze')
})

Deno.test('one agent is not "1 agents"', () => {
  assertStringIncludes(composeReceipts(receipts({ agents: 1 })), '1 agent locked')
})

Deno.test('a long card is trimmed, never overflowed', () => {
  const card = Array.from({ length: 16 }, (_, i) => ({ away: `AAA${i}`, home: `BBB${i}` }))
  const out = composeReceipts(receipts({ card }))
  assert(xLen(out) <= X_LIMIT, `${xLen(out)} > ${X_LIMIT}`)
  assertEquals(wireRefusal(out), null)
  // The claim survives the trim; the matchups are what gets dropped.
  assertStringIncludes(out, 'locked calls on')
})

Deno.test('podium names the winner, the record and the number', () => {
  const out = composePodium(podium())
  assertEquals(wireRefusal(out), null)
  assertStringIncludes(out, 'phenology took the podium: 5-1, Brier 0.1421')
  assertStringIncludes(out, 'best of 9')
})

Deno.test('the mic is quoted when it fits', () => {
  const out = composePodium(podium({ statement: 'I read the weather and nobody else did.' }))
  assertStringIncludes(out, '“I read the weather and nobody else did.”')
  assertEquals(wireRefusal(out), null)
})

// --------------------------------------------------------------- the adversary
Deno.test('a player statement cannot smuggle wagering language onto the wire', () => {
  const out = composePodium(podium({ statement: 'Easy money, the odds were wrong all week.' }))
  assert(!out.includes('odds'), 'the quote was published anyway')
  assertEquals(wireRefusal(out), null, 'the fallback must itself be clean')
  assertStringIncludes(out, 'took the podium')
})

Deno.test('a player statement cannot smuggle a link onto the wire', () => {
  const out = composePodium(podium({ statement: 'Full breakdown at myagent.com/week1' }))
  assert(!out.includes('myagent.com'))
  assertEquals(wireRefusal(out), null)
})

Deno.test('an over-long statement falls back rather than truncating someone', () => {
  const out = composePodium(podium({ statement: 'x'.repeat(300) }))
  assert(xLen(out) <= X_LIMIT)
  assert(!out.includes('xxxxx'))
})

Deno.test('the guard names the hard line it is defending', () => {
  assertStringIncludes(String(wireRefusal('we took the best odds')), 'hard line 1')
  assertStringIncludes(String(wireRefusal('winnings are up')), 'hard line 1')
  assertStringIncludes(String(wireRefusal('read more at sunday.ledger.football')), 'decision L')
  assertStringIncludes(String(wireRefusal('https://example.com')), 'decision L')
  assertStringIncludes(String(wireRefusal('a'.repeat(281))), 'the limit is 280')
  assertStringIncludes(String(wireRefusal('   ')), 'nothing composed')
})

Deno.test('the house tagline vocabulary passes untouched', () => {
  // "picks" and "calls" are the sanctioned words; the guard must not eat them.
  assertEquals(wireRefusal('anyone can call a winner Sunday night'), null)
  assertEquals(wireRefusal('every pick on the record before kickoff'), null)
  assertEquals(wireRefusal('standings, not winners circle'), null)
})
