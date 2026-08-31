import type { Game, Week } from '../lib/api'
import { SectionHead } from './Slate'
import { PlayerLink } from './Player'

export function Settled({ week }: { week: Week | null }) {
  if (!week) {
    return (
      <p className="py-10 text-center text-ink-dim">
        Nothing has settled yet. Come back after the first Monday night.
      </p>
    )
  }
  const main = week.games.filter((g) => g.main_card)
  const rest = week.games.filter((g) => !g.main_card)

  return (
    <div>
      <SectionHead
        title={`Week ${week.week} — settled`}
        sub="What was said on Wednesday, against what happened on Sunday."
      />

      {week.podium && (
        <blockquote className="border-l-4 border-ink bg-paper-2 p-4">
          <p className="text-lg italic">&ldquo;{week.podium.text}&rdquo;</p>
          <footer className="tabular mt-2 text-sm text-ink-dim">
            — <PlayerLink handle={week.podium.handle} className="text-ink" />, best Brier of the week, from the podium
          </footer>
        </blockquote>
      )}

      {week.call_of_week && (
        <p className="mt-4 text-sm">
          <span className="stamp">call of the week</span>{' '}
          <PlayerLink handle={week.call_of_week.handle} className="font-bold" /> took {week.call_of_week.side} at{' '}
          <span className="tabular">{Number(week.call_of_week.probability).toFixed(2)}</span> in{' '}
          {week.call_of_week.game} when only{' '}
          <span className="tabular">{Math.round(Number(week.call_of_week.side_share) * 100)}%</span>{' '}
          of the field did.
        </p>
      )}

      {week.week_briers && week.week_briers.length > 0 && (
        <div className="mt-8">
          <h3 className="mb-2 font-bold uppercase tracking-wider text-sm">The week&rsquo;s Briers</h3>
          <div className="divide-y divide-rule border-y border-rule">
            {week.week_briers.map((b, i) => (
              <div key={b.handle} className="flex items-baseline justify-between py-1.5 text-sm">
                <span>
                  <span className="tabular mr-3 text-ink-dim">{i + 1}</span>
                  <PlayerLink handle={b.handle} className="font-bold" />
                </span>
                <span className="tabular">{Number(b.brier).toFixed(4)} <span className="text-ink-dim">({b.record})</span></span>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="mt-10">
        <h3 className="mb-2 font-bold uppercase tracking-wider text-sm">Main card results &amp; the revealed picks</h3>
        {main.map((g) => <SettledGame key={g.game_id} g={g} />)}
        <h3 className="mb-2 mt-8 font-bold uppercase tracking-wider text-sm">The rest of the slate</h3>
        {rest.map((g) => <SettledGame key={g.game_id} g={g} />)}
      </div>
    </div>
  )
}

function SettledGame({ g }: { g: Game }) {
  const r = g.result
  return (
    <div className="mb-3 border border-rule bg-paper-2 p-3">
      <div className="flex items-baseline justify-between">
        <p className="font-bold">
          {g.away} at {g.home}
          {r && (
            <span className="tabular ml-3">{r.away_score}–{r.home_score}
              <span className="ml-2 text-field">{r.tie ? 'TIE (push)' : `${r.winner} FINAL`}</span>
            </span>
          )}
        </p>
      </div>
      {g.picks && g.picks.length > 0 && (
        <div className="tabular mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs">
          {g.picks.map((p) => {
            const hit = r?.winner != null && p.side === r.winner
            const miss = r?.winner != null && p.side !== r.winner
            return (
              <span key={p.handle} className={hit ? 'text-field' : miss ? 'text-stamp' : 'text-ink-dim'}>
                <PlayerLink handle={p.handle} />: {p.side} {Number(p.probability).toFixed(2)}
              </span>
            )
          })}
        </div>
      )}
      {(!g.picks || g.picks.length === 0) && (
        <p className="mt-1 text-xs italic text-ink-dim">No picks were registered on this one.</p>
      )}
    </div>
  )
}
