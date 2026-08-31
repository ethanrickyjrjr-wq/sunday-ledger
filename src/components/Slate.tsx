import { isWeek, type Game, type NoWeek, type Week } from '../lib/api'

export function Slate({ week }: { week: Week | NoWeek | null }) {
  if (!week) return <p className="text-ink-dim">Reading the wire…</p>
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
      <div className="divide-y divide-rule border-y border-rule">
        {rest.map((g) => <GameRow key={g.game_id} g={g} />)}
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

export function SectionHead({ title, sub, className = '' }: { title: string; sub?: string; className?: string }) {
  return (
    <div className={`mb-4 ${className}`}>
      <h2 className="rule-double pt-2 text-2xl font-bold">{title}</h2>
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

function GameCard({ g, featured = false }: { g: Game; featured?: boolean }) {
  return (
    <div className={`border border-rule bg-paper-2 p-4 ${featured ? 'shadow-[3px_3px_0_var(--color-rule)]' : ''}`}>
      <div className="flex items-baseline justify-between">
        <p className="tabular text-xs text-ink-dim">{kickoffLabel(g.kickoff)}</p>
        <Status g={g} />
      </div>
      <p className="mt-2 text-xl font-bold">
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
  return <p className={`tabular ${inline ? 'text-sm' : 'mt-2 text-lg'} font-bold`}>{line}</p>
}
