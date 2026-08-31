import { useEffect, useState } from 'react'
import { configured, getHall, type HallEntry } from '../lib/api'
import { SectionHead } from './Slate'
import { PlayerLink } from './Player'
import { CountUp } from './fx/CountUp'
import { WireDown, WireLoading } from './Wire'

// A season ends once. This page is the only thing that survives it.
export function Hall() {
  const [rows, setRows] = useState<HallEntry[] | null>(null)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (!configured) return
    getHall().then(setRows).catch((e: Error) => setErr(e.message))
  }, [])

  if (err) return <WireDown err={err} />
  if (!rows) return <WireLoading />
  const champions = Array.isArray(rows) ? rows : []

  return (
    <div>
      <SectionHead
        title="Hall of Fame"
        sub="One name a season. Written once, never revised, never removed."
      />

      {champions.length === 0 ? <Empty /> : (
        <div className="space-y-6">
          {champions.map((h) => (
            <div key={h.season} className="border-2 border-ink bg-paper-2 p-6">
              <p className="flap text-xs uppercase tracking-[0.3em] text-ink-dim">champion of {h.season}</p>
              <h3 className="mt-2 font-[760] text-4xl tracking-tight sm:text-5xl">
                <span className="shine-gold"><PlayerLink handle={h.handle} /></span>
              </h3>
              <p className="tabular mt-3 text-sm text-ink-dim">
                Brier <span className="font-bold text-ink"><CountUp id={`hall-${h.season}`} value={Number(h.brier)} /></span> ·{' '}
                {h.wins}–{h.losses} · {h.weeks} {h.weeks === 1 ? 'week' : 'weeks'} scored
              </p>
              <p className="mt-4 text-sm">
                <span className="stamp stamp-slam">champion</span>{' '}
                <span className="ml-1 text-ink-dim">
                  Holds the title beside the handle for good, and called one featured game on the
                  opening card of {h.season + 1}.
                </span>
              </p>
            </div>
          ))}
        </div>
      )}

      <Stakes />
    </div>
  )
}

function Empty() {
  return (
    <div className="border border-rule bg-paper-2 p-8 text-center">
      <p className="stamp">no champion yet</p>
      <p className="mx-auto mt-6 max-w-xl text-lg leading-relaxed">
        This page is empty because the first season is still being played. It will not be empty
        again. Every name written here in February stays here in every February after it.
      </p>
    </div>
  )
}

function Stakes() {
  return (
    <div className="mt-10 border border-rule p-5 text-sm leading-relaxed">
      <p className="font-bold uppercase tracking-wider">What the season pays</p>
      <div className="mt-3 divide-y divide-rule/60">
        <p className="py-2.5">
          <span className="tabular mr-2 text-stamp">§1</span>
          <strong>A permanent title.</strong> Champion of the season, carried beside the handle on
          the standings, on the player&rsquo;s page, and here. Titles are not reissued and they are
          not shared.
        </p>
        <p className="py-2.5">
          <span className="tabular mr-2 text-stamp">§2</span>
          <strong>A name that does not leave this page.</strong> Seasons stack downward. A champion
          from year one is still the champion of year one in year twenty.
        </p>
        <p className="py-2.5">
          <span className="tabular mr-2 text-stamp">§3</span>
          <strong>The opening call.</strong> The champion names one featured game on next
          season&rsquo;s opening card — the whole field picks a game the champion chose.
        </p>
      </div>
      <p className="mt-4 text-ink-dim">
        No purse, no prize, nothing that spends. The season pays in the only currency this
        Ledger keeps: a record with your name on it, in public, forever.
      </p>
    </div>
  )
}
