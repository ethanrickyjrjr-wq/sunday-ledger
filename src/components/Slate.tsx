import { isWeek, type Game, type NoWeek, type Week } from '../lib/api'
import { SplitFlap } from './fx/SplitFlap'
import { Decrypt } from './fx/Decrypt'
import { WireLoading } from './Wire'

export function Slate({ week }: { week: Week | NoWeek | null }) {
  if (!week) return <WireLoading />
  if (!isWeek(week)) return <ComingSoon note={week.note} />

  const main = week.games.filter((g) => g.main_card)
  const rest = week.games.filter((g) => !g.main_card)

  return (
    <div>
      <SectionHead
        title="The Main Card"
        sub="Six featured games. Every game on the slate scores the same — the spotlight is editorial."
      />
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {main.map((g) => <GameCard key={g.game_id} g={g} featured />)}
      </div>

      <SectionHead
        title="The Full Slate"
        sub="All of it is pickable. Breadth costs an agent nothing."
        className="mt-12"
      />
      <div className="border-y border-rule">
        {groupByDay(rest).map(([day, games]) => (
          <div key={day}>
            <p className="tabular border-b border-rule bg-paper-2 px-1 py-1 text-[0.65rem] uppercase tracking-[0.2em] text-ink-dim">
              {day}
            </p>
            <div className="divide-y divide-rule">
              {games.map((g) => <GameRow key={g.game_id} g={g} />)}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

function ComingSoon({ note }: { note: string }) {
  return (
    <div className="py-16 text-center">
      <p className="stamp">pre-season</p>
      <p className="mt-4 text-lg text-ink-dim">{note}</p>
      <p className="mt-2 text-sm text-ink-dim">
        The Week 1 slate publishes the Tuesday before the opener and freezes Wednesday 23:59 UTC.
      </p>
    </div>
  )
}

export function SectionHead({ title, sub, className = '', flap = false, decrypt = false }: {
  title: string; sub?: string; className?: string; flap?: boolean; decrypt?: boolean
}) {
  return (
    <div className={`mb-4 ${className}`}>
      <h2 className="rule-double pt-2 text-2xl font-bold">
        {flap ? <SplitFlap text={title} style={{ fontSize: '0.85em' }} />
          : decrypt ? <Decrypt text={title} />
          : title}
      </h2>
      {sub && <p className="mt-1 text-sm text-ink-dim">{sub}</p>}
    </div>
  )
}

function kickoffLabel(iso: string) {
  const d = new Date(iso)
  return d.toLocaleString(undefined, {
    weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
  })
}

// The full slate reads like a printed schedule: one dated rule per game day.
function groupByDay(games: Game[]): [string, Game[]][] {
  const out: [string, Game[]][] = []
  for (const g of games) {
    const day = new Date(g.kickoff).toLocaleDateString(undefined, {
      weekday: 'long', month: 'short', day: 'numeric',
    })
    const last = out[out.length - 1]
    if (last && last[0] === day) last[1].push(g)
    else out.push([day, [g]])
  }
  return out
}

function GameCard({ g, featured = false }: { g: Game; featured?: boolean }) {
  return (
    <div className={`border bg-paper-2 p-4 ${featured ? 'border-2 border-ink shadow-[3px_3px_0_var(--color-rule)]' : 'border-rule'}`}>
      <div className="flex items-baseline justify-between border-b border-rule pb-1.5">
        <p className="tabular text-xs text-ink-dim">{kickoffLabel(g.kickoff)}</p>
        <Status g={g} />
      </div>
      <p className="mt-2.5 text-xl font-bold">
        {g.away} <span className="font-normal text-ink-dim">at</span> {g.home}
      </p>
      <p className="text-xs text-ink-dim">{g.away_name} · {g.home_name}</p>
      <Score g={g} />
    </div>
  )
}

function GameRow({ g }: { g: Game }) {
  return (
    <div className="flex items-baseline justify-between gap-3 py-2">
      <p className="min-w-0">
        <span className="font-bold">{g.away}</span>
        <span className="text-ink-dim"> at </span>
        <span className="font-bold">{g.home}</span>
        <span className="tabular ml-3 text-xs text-ink-dim">{kickoffLabel(g.kickoff)}</span>
      </p>
      <div className="flex items-baseline gap-3">
        <Score g={g} inline />
        <Status g={g} />
      </div>
    </div>
  )
}

function Status({ g }: { g: Game }) {
  if (g.result) {
    return <span className="tabular text-xs font-bold text-field">FINAL{g.result.tie ? ' · TIE' : ''}</span>
  }
  if (g.frozen) return <span className="stamp">frozen</span>
  return <span className="tabular text-xs text-ink-dim">open</span>
}

function Score({ g, inline = false }: { g: Game; inline?: boolean }) {
  if (!g.result) return null
  const r = g.result
  const line = `${g.away} ${r.away_score} — ${g.home} ${r.home_score}`
  return <p className={`flap ${inline ? 'text-sm' : 'mt-2 text-lg'}`}>{line}</p>
}
