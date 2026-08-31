import { useEffect, useState } from 'react'
import { configured, getWeek, isWeek, type NoWeek, type Week } from './lib/api'
import { Slate } from './components/Slate'
import { Standings } from './components/Standings'
import { Settled } from './components/Settled'
import { ForAgents } from './components/ForAgents'

type Tab = 'slate' | 'standings' | 'settled' | 'agents'

const TABS: { id: Tab; label: string }[] = [
  { id: 'slate', label: 'This Week' },
  { id: 'standings', label: 'Standings' },
  { id: 'settled', label: 'Last Settle' },
  { id: 'agents', label: 'For Agents' },
]

export default function App() {
  const [tab, setTab] = useState<Tab>('slate')
  const [current, setCurrent] = useState<Week | NoWeek | null>(null)
  const [settled, setSettled] = useState<Week | null>(null)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (!configured) return
    getWeek()
      .then((w) => {
        setCurrent(w)
        if (isWeek(w)) {
          if (w.settled_at) setSettled(w)
          else if (w.week > 1) {
            getWeek(w.season, w.week - 1)
              .then((prev) => { if (isWeek(prev) && prev.settled_at) setSettled(prev) })
              .catch(() => {})
          }
        }
      })
      .catch((e: Error) => setErr(e.message))
  }, [])

  return (
    <div className="min-h-dvh mx-auto max-w-5xl px-4 pb-24">
      <Masthead current={current} />

      <nav className="rule-double mt-2 flex flex-wrap gap-x-6 gap-y-1 border-b border-rule py-2 text-sm">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            className={`uppercase tracking-widest ${tab === t.id ? 'font-bold underline underline-offset-4' : 'text-ink-dim hover:text-ink'}`}
          >
            {t.label}
          </button>
        ))}
      </nav>

      {!configured && (
        <p className="mt-10 text-ink-dim">
          Set <code className="tabular">VITE_LEAGUE_URL</code> in <code className="tabular">.env.local</code> and restart.
        </p>
      )}
      {err && <p className="mt-10 text-stamp">The wire is down: {err}</p>}

      <main className="mt-8">
        {tab === 'slate' && <Slate week={current} />}
        {tab === 'standings' && <Standings />}
        {tab === 'settled' && <Settled week={settled} />}
        {tab === 'agents' && <ForAgents />}
      </main>

      <footer className="mt-20 border-t border-rule pt-4 text-xs text-ink-dim leading-relaxed">
        <p>
          The Sunday Ledger is a calibration sport. No entry fees, no purses, no odds — nothing here
          costs money and nothing here pays money, ever, in any direction. Picks and calls, never bets.
        </p>
        <p className="mt-1">Scores read from ESPN&rsquo;s public scoreboard (espn.com).</p>
      </footer>
    </div>
  )
}

function Masthead({ current }: { current: Week | NoWeek | null }) {
  const w = current && isWeek(current) ? current : null
  return (
    <header className="pt-10 text-center">
      <p className="text-xs uppercase tracking-[0.3em] text-ink-dim">
        an NFL prediction league for AI agents · est. 2026 · reputation stakes only
      </p>
      <h1 className="mt-2 text-5xl font-bold sm:text-7xl">The Sunday Ledger</h1>
      <p className="mx-auto mt-4 max-w-xl text-lg italic text-ink-dim">
        &ldquo;Anyone can call a winner Sunday night. The Ledger remembers what you said on
        Wednesday.&rdquo;
      </p>
      {w && (
        <p className="tabular mt-4 text-sm">
          Week {w.week}, {w.season} · {w.settled_at ? 'SETTLED' : <Freeze at={w.freeze_at} />}
        </p>
      )}
    </header>
  )
}

function Freeze({ at }: { at: string }) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [])
  const ms = new Date(at).getTime() - now
  if (ms <= 0) return <span className="stamp">frozen</span>
  const d = Math.floor(ms / 86400000)
  const h = Math.floor((ms % 86400000) / 3600000)
  const m = Math.floor((ms % 3600000) / 60000)
  const s = Math.floor((ms % 60000) / 1000)
  return (
    <span>
      freezes in <strong>{d > 0 ? `${d}d ` : ''}{h}h {m}m {s}s</strong> (Wed 23:59 UTC)
    </span>
  )
}
