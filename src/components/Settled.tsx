import type { Game, Week } from '../lib/api'
import { SectionHead } from './Slate'
import { PlayerLink } from './Player'
import { SplitFlap } from './fx/SplitFlap'

// The payoff page: what was said on Wednesday, against what happened on
// Sunday. Featured finals flip onto the board — settling is the one moment
// the machinery of this site exists for.

export function Settled({ week }: { week: Week | null }) {
  if (!week) {
    return (
      <div className="py-16 text-center">
        <p className="stamp">nothing settled</p>
        <p className="mt-4 text-lg text-ink-dim">
          The first settle lands after the first Monday night.
        </p>
        <p className="mt-2 text-sm text-ink-dim">
          Until then the Ledger holds only what was promised, not what came true.
        </p>
      </div>
    )
  }
  const main = week.games.filter((g) => g.main_card)
  const rest = week.games.filter((g) => !g.main_card)

  return (
    <div>
      <SectionHead
        title={`Week ${week.week} — settled`}
        sub="What was said on Wednesday, against what happened on Sunday."
        flap
      />

      {week.podium && (
        <blockquote className="border-l-4 border-ink bg-paper-2 p-5">
          <p className="text-xl italic leading-relaxed">&ldquo;{week.podium.text}&rdquo;</p>
          <footer className="tabular mt-3 text-sm text-ink-dim">
            — <PlayerLink handle={week.podium.handle} className="font-bold text-ink" />, best claimed Brier of the week, from the podium
          </footer>
        </blockquote>
      )}

      {week.call_of_week && (
        <div className="mt-6 border-y-2 border-ink py-3">
          <p className="text-sm leading-relaxed">
            <span className="stamp stamp-slam">call of the week</span>{' '}
            <PlayerLink handle={week.call_of_week.handle} className="font-bold" /> took {week.call_of_week.side} at{' '}
            <span className="tabular">{Number(week.call_of_week.probability).toFixed(2)}</span> in{' '}
            {week.call_of_week.game} when only{' '}
            <span className="tabular">{Math.round(Number(week.call_of_week.side_share) * 100)}%</span>{' '}
            of the field did.
          </p>
        </div>
      )}

      {week.week_briers && week.week_briers.length > 0 && (
        <div className="mt-10">
          <h3 className="mb-2 border-b-2 border-ink pb-1 text-sm font-bold uppercase tracking-wider">
            The week&rsquo;s Briers
          </h3>
          <div className="divide-y divide-rule">
            {week.week_briers.map((b, i) => (
              <div key={b.handle} className="flex items-baseline justify-between py-1.5 text-sm">
                <span className="flex items-baseline">
                  <span className="flap mr-3 w-6 text-right text-ink-dim">{i + 1}</span>
                  <PlayerLink handle={b.handle} className={i === 0 ? 'shine-gold font-bold' : 'font-bold'} />
                  {i === 0 && <span className="stamp ml-3">week&rsquo;s best</span>}
                </span>
                <span className="tabular">{Number(b.brier).toFixed(4)} <span className="text-ink-dim">({b.record})</span></span>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="mt-12">
        <SectionHead title="Main card results" sub="The featured six, with every revealed pick beside them." />
        {main.length === 0
          ? <p className="py-4 text-sm italic text-ink-dim">No featured games on this card.</p>
          : main.map((g) => <SettledGame key={g.game_id} g={g} featured />)}

        <h3 className="mt-10 mb-3 border-b border-rule pb-1 text-sm font-bold uppercase tracking-wider text-ink-dim">
          The rest of the slate
        </h3>
        {rest.length === 0
          ? <p className="py-4 text-sm italic text-ink-dim">The main card was the whole card this week.</p>
          : rest.map((g) => <SettledGame key={g.game_id} g={g} />)}
      </div>
    </div>
  )
}

function SettledGame({ g, featured = false }: { g: Game; featured?: boolean }) {
  const r = g.result
  return (
    <div className={`mb-3 border border-rule bg-paper-2 ${featured ? 'p-4 shadow-[3px_3px_0_var(--color-rule)]' : 'p-3'}`}>
      <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <p className={`font-bold ${featured ? 'text-lg' : ''}`}>
          {g.away} <span className="font-normal text-ink-dim">at</span> {g.home}
        </p>
        {r && (
          <p className="flex items-baseline gap-2">
            {featured
              ? <SplitFlap text={`${r.away_score}–${r.home_score}`} style={{ fontSize: '1.15rem' }} />
              : <span className="flap text-sm">{r.away_score}–{r.home_score}</span>}
            <span className="tabular text-xs font-bold text-field">{r.tie ? 'TIE · PUSH' : `${r.winner} FINAL`}</span>
          </p>
        )}
      </div>
      {g.picks && g.picks.length > 0 && (
        <div className="mt-3 flex flex-wrap gap-1.5">
          {g.picks.map((p) => {
            const hit = r?.winner != null && p.side === r.winner
            const miss = r?.winner != null && p.side !== r.winner
            return (
              <span
                key={p.handle}
                className={`tabular inline-flex items-baseline gap-1.5 border px-2 py-0.5 text-xs ${
                  hit ? 'border-field text-field' : miss ? 'border-stamp text-stamp' : 'border-rule text-ink-dim'
                }`}
              >
                {hit && <span aria-label="correct">✓</span>}
                {miss && <span aria-label="missed">✗</span>}
                <PlayerLink handle={p.handle} /> {p.side} {Number(p.probability).toFixed(2)}
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
