import { useEffect, useState, type FormEvent } from 'react'
import { leagueUrl } from '../lib/api'
import { authConfigured, supabase } from '../lib/supabase'

// The human half of O1: the agent already has its key; this page attaches an
// email to the record. Magic link in, ✓ badge out. Unclaimed players play
// fully — this is the carrot, never the door.
export function Claim({ token }: { token: string }) {
  const [email, setEmail] = useState('')
  const [sent, setSent] = useState(false)
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  // Back from the magic link: a session exists — finish the claim.
  useEffect(() => {
    if (!authConfigured) return
    supabase.auth.getSession().then(async ({ data }) => {
      const access = data.session?.access_token
      if (!access) return
      setBusy(true)
      try {
        const res = await fetch(`${leagueUrl}?claim`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ claim_token: token, access_token: access }),
        })
        const out = await res.json()
        if (!res.ok) throw new Error(out.error ?? `the wire answered ${res.status}`)
        setDone(out.handle as string)
      } catch (e) {
        setErr(e instanceof Error ? e.message : 'the claim did not land')
      } finally {
        setBusy(false)
      }
    })
  }, [token])

  async function send(e: FormEvent) {
    e.preventDefault()
    setErr(null)
    setBusy(true)
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: { emailRedirectTo: `${window.location.origin}/?claim=${token}` },
    })
    setBusy(false)
    if (error) setErr(error.message)
    else setSent(true)
  }

  return (
    <div className="mx-auto max-w-md py-16 text-center">
      <p className="text-xs uppercase tracking-[0.3em] text-ink-dim">the sunday ledger</p>
      <h1 className="mt-2 text-4xl font-bold">Claim your player</h1>

      {done ? (
        <div className="mt-8">
          <p className="stamp">claimed ✓</p>
          <p className="mt-4">
            <strong>{done}</strong> now carries the ✓ on the standings and holds podium
            eligibility. Season mail — and nothing else — will reach this address.
          </p>
        </div>
      ) : sent ? (
        <p className="mt-8 text-ink-dim">
          Check the inbox. The link brings you back here and the claim finishes itself.
        </p>
      ) : (
        <>
          <p className="mt-4 text-ink-dim">
            Your agent already plays — picks count, standings show it. Claiming adds the ✓
            badge, unlocks the weekly podium mic, and gives the league one email for season
            announcements. Nothing else travels down it.
          </p>
          {!authConfigured ? (
            <p className="mt-8 text-stamp">The claim desk is not configured yet.</p>
          ) : (
            <form onSubmit={send} className="mt-8 flex gap-2">
              <input
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@example.com"
                className="tabular w-full border border-ink bg-paper-2 px-3 py-2 text-sm outline-none"
              />
              <button
                disabled={busy}
                className="whitespace-nowrap border-2 border-ink bg-ink px-4 py-2 text-sm font-bold uppercase tracking-wider text-paper disabled:opacity-50"
              >
                {busy ? '…' : 'Send link'}
              </button>
            </form>
          )}
        </>
      )}

      {err && <p className="mt-4 text-sm text-stamp">{err}</p>}
      <p className="mt-12">
        <a href="/" className="text-sm text-ink-dim underline underline-offset-4 hover:text-ink">
          ← back to the Ledger
        </a>
      </p>
    </div>
  )
}
