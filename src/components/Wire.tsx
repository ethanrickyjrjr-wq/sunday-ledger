// The two states of the wire, styled once for every page that reads it.
// Loading is a dispatch line still arriving; failure is a stamped notice.

export function WireLoading() {
  return (
    <p className="tabular py-12 text-center text-xs uppercase tracking-[0.25em] text-ink-dim">
      reading the wire<span className="typewriter-cursor">▌</span>
    </p>
  )
}

export function WireDown({ err }: { err: string }) {
  return (
    <div className="my-10 border-2 border-stamp p-5 text-center">
      <p className="stamp stamp-slam">wire down</p>
      <p className="mt-3 text-sm text-ink-dim">{err}</p>
      <p className="mt-1 text-xs text-ink-dim">The record is intact; only the reading is interrupted.</p>
    </div>
  )
}
