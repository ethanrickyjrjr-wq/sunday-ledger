import { useEffect, useState } from 'react'
import { configured, getConferences, isWeek, type ConferenceCounts, type NoWeek, type Week } from '../lib/api'

// The wire itself: one line of tape running under the nav. A newsroom ticker,
// not a stock crawl — finals, the podium holder, the signup tally, the freeze.
// The one standing exception to "motion fires once": the wire never stops.

const styles = `
.wire-ticker{overflow:hidden;position:relative}
.wire-ticker__track{display:inline-flex;white-space:nowrap;width:max-content;animation:wire-scroll var(--wire-dur,60s) linear infinite}
.wire-ticker:hover .wire-ticker__track{animation-play-state:paused}
@keyframes wire-scroll{from{transform:translateX(0)}to{transform:translateX(-50%)}}
@media (prefers-reduced-motion:reduce){
  .wire-ticker__track{animation:none;width:100%}
  .wire-ticker__copy--b{display:none}
}
`

function buildItems(current: Week | NoWeek | null, settled: Week | null, c: ConferenceCounts | null): string[] {
  const out: string[] = []
  const w = current && isWeek(current) ? current : null
  if (w && !w.settled_at) out.push(`week ${w.week} freezes wednesday 23:59 utc`)
  if (settled) {
    if (settled.podium) out.push(`the podium · ${settled.podium.handle} holds the mic`)
    for (const g of settled.games) {
      if (g.result && g.main_card) {
        out.push(`final w${settled.week} · ${g.away} ${g.result.away_score}–${g.home} ${g.result.home_score}${g.result.tie ? ' · tie' : ''}`)
      }
    }
  }
  if (c) out.push(`signup ledger · afc ${c.AFC} — nfc ${c.NFC}${c.undeclared > 0 ? ` · ${c.undeclared} undeclared` : ''}${typeof c.charter === 'number' ? ` · charter roll ${c.charter}` : ''}`)
  out.push('reputation stakes only · picks and calls, never bets')
  return out
}

export function WireTicker({ current, settled }: { current: Week | NoWeek | null; settled: Week | null }) {
  const [c, setC] = useState<ConferenceCounts | null>(null)
  useEffect(() => {
    if (!configured) return
    getConferences().then(setC).catch(() => {})
  }, [])

  const items = buildItems(current, settled, c)
  if (items.length === 0) return null
  // Slower tape for a longer dispatch; clamped so it never races or crawls.
  const dur = Math.min(90, Math.max(30, items.join('').length * 0.35))

  const copy = (which: string, hidden: boolean) => (
    <span className={`wire-ticker__copy--${which}`} aria-hidden={hidden}>
      {items.map((it, i) => (
        <span key={i} className="inline-block px-4">
          {it}
          <span className="pl-8 text-rule" aria-hidden="true">///</span>
        </span>
      ))}
    </span>
  )

  return (
    <>
      <style>{styles}</style>
      <div
        className="wire-ticker tabular border-b border-rule py-1.5 text-[0.68rem] uppercase tracking-[0.14em] text-ink-dim"
        role="marquee"
        aria-label={items.join(' — ')}
      >
        <div className="wire-ticker__track" style={{ '--wire-dur': `${dur}s` } as React.CSSProperties}>
          {copy('a', false)}
          {copy('b', true)}
        </div>
      </div>
    </>
  )
}
