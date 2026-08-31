import { useEffect, useState } from 'react'
import { configured, getPodiums, type PodiumEntry } from '../lib/api'
import { SectionHead } from './Slate'
import { PlayerLink } from './Player'

// The quote index. Winning a week buys 300 characters and a permanent line
// in this file. Nothing here is ever edited and nothing is ever removed.
export function Podiums() {
  const [rows, setRows] = useState<PodiumEntry[] | null>(null)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (!configured) return
    getPodiums().then(setRows).catch((e: Error) => setErr(e.message))
  }, [])

  if (err) return <p className="text-stamp">The wire is down: {err}</p>
  if (!rows) return <p className="text-ink-dim">Reading the wire…</p>
  const quotes = Array.isArray(rows) ? rows : []

  return (
    <div>
      <SectionHead
        title="The Podium"
        sub="Best Brier of a settled week takes the mic — 300 characters, said in public, kept forever. Newest first."
      />

      {quotes.length === 0 ? (
        <div className="border border-rule bg-paper-2 p-8 text-center">
          <p className="stamp">mic unclaimed</p>
          <p className="mt-6 text-lg italic text-ink-dim">
            &ldquo;&nbsp;&rdquo;
          </p>
          <p className="mx-auto mt-4 max-w-lg leading-relaxed">
            Nobody has stood here yet. The best Brier of a settled week holds the mic for
            twenty-four hours and writes 300 characters into this page. The first one goes at
            the top of a list that only ever grows downward.
          </p>
          <p className="mt-4 text-sm text-ink-dim">
            Win a week. Say something worth reading in a year.
          </p>
        </div>
      ) : (
        <div className="space-y-8">
          {quotes.map((q) => (
            <blockquote key={`${q.season}-${q.week}-${q.handle}`} className="border-l-4 border-ink bg-paper-2 p-5">
              <p className="text-xl italic leading-relaxed sm:text-2xl">&ldquo;{q.text}&rdquo;</p>
              <footer className="tabular mt-3 flex flex-wrap items-baseline gap-x-3 text-sm text-ink-dim">
                <span>
                  — <PlayerLink handle={q.handle} className="font-bold text-ink" />, Week {q.week}, {q.season}
                </span>
                <span>Brier {Number(q.brier).toFixed(4)}</span>
                {q.at && <span>{stamped(q.at)}</span>}
              </footer>
            </blockquote>
          ))}
        </div>
      )}
    </div>
  )
}

function stamped(iso: string) {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' })
}
