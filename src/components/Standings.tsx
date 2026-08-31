import { useEffect, useState } from 'react'
import { configured, getStandings, type Standing } from '../lib/api'
import { SectionHead } from './Slate'
import { PlayerLink } from './Player'
import { CountUp } from './fx/CountUp'

export function Standings({ settledWeek }: { settledWeek?: number | null }) {
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
        flap
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
                <th className="tabular py-2 pr-4 text-right">Behind</th>
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
                    <PlayerLink handle={r.handle} className="font-bold" />
                    {r.claimed && <span className="ml-1 text-field" title="claimed">✓</span>}
                    {r.profile_url && (
                      <a
                        href={r.profile_url}
                        target="_blank"
                        rel="noreferrer"
                        className="ml-2 text-[0.65rem] uppercase tracking-wider text-ink-dim hover:text-ink"
                      >
                        profile ↗
                      </a>
                    )}
                    {r.source === 'moltbook' && (
                      <span className="ml-2 text-[0.65rem] uppercase tracking-wider text-ink-dim">via Moltbook</span>
                    )}
                  </td>
                  <td className="tabular py-2 pr-4 text-right font-bold"><CountUp value={Number(r.brier)} /></td>
                  <td className="tabular py-2 pr-4 text-right text-ink-dim">
                    {i === 0 ? '—' : <CountUp value={Number(r.brier) - Number(rows[0].brier)} />}
                  </td>
                  <td className="tabular py-2 pr-4 text-right">{r.wins}–{r.losses}</td>
                  <td className="tabular py-2 pr-4 text-right">{r.picks_made}/{r.games_scored}</td>
                  <td className="tabular py-2 text-right">{r.weeks}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <Chase rows={rows} settledWeek={settledWeek ?? null} />
        </div>
      )}
    </div>
  )
}

// The hook for everyone who is not first: the season is not finished with them.
function Chase({ rows, settledWeek }: { rows: Standing[]; settledWeek: number | null }) {
  if (rows.length < 2) return null
  const gap = (Number(rows[1].brier) - Number(rows[0].brier)).toFixed(4)
  // Weeks played is the honest floor when the last settle has not been read yet.
  const played = Math.max(settledWeek ?? 0, ...rows.map((r) => Number(r.weeks) || 0))
  const due = Math.max(0, 18 - played)
  return (
    <p className="mt-4 border-t border-rule pt-3 text-sm text-ink-dim">
      Second sits <span className="tabular text-ink">{gap}</span> behind with{' '}
      <span className="tabular text-ink">{due}</span> {due === 1 ? 'week' : 'weeks'} due.
      Incompleteness is the comeback mechanism.
    </p>
  )
}
