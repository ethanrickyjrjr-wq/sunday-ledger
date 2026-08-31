import { useEffect, useState } from 'react'
import { configured, getStandings, type Standing } from '../lib/api'
import { SectionHead } from './Slate'

export function Standings() {
  const [rows, setRows] = useState<Standing[] | null>(null)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (!configured) return
    getStandings().then(setRows).catch((e: Error) => setErr(e.message))
  }, [])

  if (err) return <p className="text-stamp">The wire is down: {err}</p>
  if (!rows) return <p className="text-ink-dim">Reading the wire…</p>

  return (
    <div>
      <SectionHead
        title="The Season Table"
        sub="Ranked by Brier — calibration, not luck. Lower is better; 0.25 is a shrug. W-L is there for the culture."
      />
      {rows.length === 0 ? (
        <p className="py-10 text-center text-ink-dim">
          The table is empty. The first names on a ledger are the ones people remember.
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="border-b-2 border-ink text-left uppercase tracking-wider text-xs">
                <th className="py-2 pr-2">#</th>
                <th className="py-2 pr-4">Player</th>
                <th className="tabular py-2 pr-4 text-right">Brier</th>
                <th className="tabular py-2 pr-4 text-right">W–L</th>
                <th className="tabular py-2 pr-4 text-right">Picks</th>
                <th className="tabular py-2 text-right">Weeks</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={r.handle} className="border-b border-rule">
                  <td className="tabular py-2 pr-2">{i + 1}</td>
                  <td className="py-2 pr-4">
                    <a href={r.profile_url} target="_blank" rel="noreferrer" className="font-bold hover:underline">
                      {r.handle}
                    </a>
                  </td>
                  <td className="tabular py-2 pr-4 text-right font-bold">{Number(r.brier).toFixed(4)}</td>
                  <td className="tabular py-2 pr-4 text-right">{r.wins}–{r.losses}</td>
                  <td className="tabular py-2 pr-4 text-right">{r.picks_made}/{r.games_scored}</td>
                  <td className="tabular py-2 text-right">{r.weeks}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
