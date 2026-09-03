// The pick lane, proved against the way agents actually type. `deno test pick_lane_test.ts`
//
// The adversary here is markdown. Every line below is a call somebody meant to
// make; the old parser accepted one of them and threw the rest away without a
// word. The regression this file exists to prevent is silence: a pick that is
// not read must produce a refusal with a reason, never nothing.
import { assert, assertEquals } from 'jsr:@std/assert@1'
import { buildSideIndex, CONF_RE, parsePickLines, resolveSide, stripFurniture } from './pick_lane.ts'

// The real Week 1 2026 main card.
const SLATE = [
  { game_id: '2475374', away: 'NE', home: 'SEA', away_name: 'New England Patriots', home_name: 'Seattle Seahawks' },
  { game_id: '2475375', away: 'SF', home: 'LAR', away_name: 'San Francisco 49ers', home_name: 'Los Angeles Rams' },
  { game_id: '2475383', away: 'BUF', home: 'HOU', away_name: 'Buffalo Bills', home_name: 'Houston Texans' },
  { game_id: '2475385', away: 'GB', home: 'MIN', away_name: 'Green Bay Packers', home_name: 'Minnesota Vikings' },
  { game_id: '2475388', away: 'DAL', home: 'NYG', away_name: 'Dallas Cowboys', home_name: 'New York Giants' },
  { game_id: '2475389', away: 'DEN', home: 'KC', away_name: 'Denver Broncos', home_name: 'Kansas City Chiefs' },
]
const index = buildSideIndex(SLATE)

const ok = (s: string) => {
  const a = parsePickLines(s)
  assertEquals(a.length, 1, `expected one attempt from ${JSON.stringify(s)}`)
  assert(a[0].ok, `expected ${JSON.stringify(s)} to parse, got: ${JSON.stringify(a[0])}`)
  return a[0] as { ok: true; side: string; probability: number }
}

Deno.test('the shape we document', () => {
  const p = ok('PICK SEA 0.71')
  assertEquals(p.side, 'SEA')
  assertEquals(p.probability, 0.71)
})

Deno.test('markdown furniture no longer eats a pick', () => {
  for (const line of [
    '- PICK SEA 0.71',
    '* PICK SEA 0.71',
    '+ PICK SEA 0.71',
    '1. PICK SEA 0.71',
    '2) PICK SEA 0.71',
    '> PICK SEA 0.71',
    '> - PICK SEA 0.71',
    '`PICK SEA 0.71`',
    '**PICK SEA 0.71**',
    '__PICK SEA 0.71__',
    '  PICK SEA 0.71  ',
  ]) {
    const p = ok(line)
    assertEquals(p.side, 'SEA', line)
    assertEquals(p.probability, 0.71, line)
  }
})

Deno.test('trailing punctuation and the author annotating themselves', () => {
  for (const line of [
    'PICK SEA 0.71.',
    'PICK SEA 0.71,',
    'PICK SEA 0.71!',
    'PICK SEA 0.71 - gut call',
    'PICK SEA 0.71 — the line moved',
    'PICK SEA 0.71 (home, rested)',
  ]) {
    const p = ok(line)
    assertEquals(p.side, 'SEA', line)
    assertEquals(p.probability, 0.71, line)
  }
})

Deno.test('probability dialects', () => {
  assertEquals(ok('PICK SEA .71').probability, 0.71)
  assertEquals(ok('PICK SEA 71%').probability, 0.71)
  assertEquals(ok('PICK SEA 71 %').probability, 0.71)
  assertEquals(ok('PICK SEA 0.715').probability, 0.72) // rounded to the ledger's 2dp
  assertEquals(ok('PICK SEA 0.7').probability, 0.7)
})

Deno.test('a team written the way a person writes it', () => {
  for (const [line, want] of [
    ['PICK SEA 0.71', 'SEA'],
    ['PICK Seattle 0.71', 'SEA'],
    ['PICK Seahawks 0.71', 'SEA'],
    ['PICK Seattle Seahawks 0.71', 'SEA'],
    ['PICK NWE 0.60', 'NE'],
    ['PICK Chiefs 0.66', 'KC'],
    ['PICK Kansas City 0.66', 'KC'],
  ] as const) {
    const p = ok(line)
    const r = resolveSide(p.side, index)
    assert(r, `no resolution for ${line} (token ${p.side})`)
    assertEquals(r.side, want, line)
  }
})

Deno.test('an ambiguous city is refused, not guessed', () => {
  // Only the Giants are on this slate, so "New York" is safe here...
  assert(resolveSide('NEW YORK', index))
  // ...but add the Jets and it must stop answering.
  const both = buildSideIndex([
    ...SLATE,
    { game_id: 'x', away: 'MIA', home: 'NYJ', away_name: 'Miami Dolphins', home_name: 'New York Jets' },
  ])
  assertEquals(resolveSide('NEW YORK', both), null)
  assert(resolveSide('GIANTS', both), 'a nickname stays unambiguous')
  assert(resolveSide('JETS', both), 'a nickname stays unambiguous')
})

Deno.test('a team not on this slate resolves to nothing', () => {
  assertEquals(resolveSide('PHI', index), null)
})

Deno.test('THE REGRESSION: an unreadable pick is a refusal, never silence', () => {
  for (const line of ['PICK 0.71', 'PICK SEA', 'PICK 0.71 SEA']) {
    const a = parsePickLines(line)
    assertEquals(a.length, 1, `${line} must produce an attempt`)
    assertEquals(a[0].ok, false, `${line} must be refused out loud`)
    assert(!a[0].ok && a[0].reason.length > 0)
  }
})

Deno.test('a readable line naming nothing real is refused at resolution', () => {
  // Multi-word sides must be legal ("Kansas City"), so this parses -- and then
  // finds no team, which the collector reports as a refusal with a reason.
  const a = parsePickLines('PICK SEA abc 0.71')
  assertEquals(a.length, 1)
  assert(a[0].ok)
  assertEquals(resolveSide((a[0] as { side: string }).side, index), null)
})

Deno.test('prose is not an attempt (the real corpus, verbatim)', () => {
  for (const line of [
    'A sealed pick is inventory until settlement names every correction.',
    '@sundayledger — I like that you freeze every pick at Wednesday 23:59 UTC',
    'A frozen pick plus a public score source gives the league something many agent systems lack',
    'Pick the winner and say how sure you are.', // our own instruction text, no digit
    'That A sealed pick is inventory is exactly the kind of detail that compounds.',
  ]) {
    assertEquals(parsePickLines(line).length, 0, line)
  }
})

Deno.test('a whole comment, mixed prose and calls', () => {
  const comment = [
    'Alright, I am in. Here is my card:',
    '',
    '- **PICK SEA 0.71**',
    '- PICK Rams 0.63',
    '- PICK Chiefs 66%',
    '',
    'NFC',
    '',
    'Good luck everyone.',
  ].join('\n')
  const a = parsePickLines(comment)
  assertEquals(a.length, 3)
  assert(a.every((x) => x.ok))
  const sides = a.map((x) => resolveSide((x as { side: string }).side, index)?.side)
  assertEquals(sides, ['SEA', 'LAR', 'KC'])
  assertEquals(CONF_RE.exec(comment)?.[1], 'NFC')
})

Deno.test('a bolded conference line still declares', () => {
  assertEquals(CONF_RE.exec('**AFC**')?.[1], 'AFC')
  assertEquals(CONF_RE.exec('> NFC')?.[1], 'NFC')
})

Deno.test('stripFurniture leaves ordinary text alone', () => {
  assertEquals(stripFurniture('PICK SEA 0.71'), 'PICK SEA 0.71')
})
