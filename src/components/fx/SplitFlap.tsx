import { useEffect, useMemo, useRef, useState, type CSSProperties } from 'react'

// Split-flap departure board, vendored from react-bits (DavidHDev/react-bits,
// MIT + Commons Clause) and cut down for the Ledger: one flip, blank tiles to
// the settled text, on entry. The board never cycles — this is a ledger, not
// an airport. Tiles are ink, characters are paper, corners are square.

const CHARSET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789–—.'

type Tile = { current: string; next: string; flipping: boolean; tick: number }

const styles = `
.split-flap{font-family:var(--font-mono);font-weight:700;line-height:1;letter-spacing:.035em;font-variant-numeric:tabular-nums;gap:var(--sf-gap,.06em)}
.split-flap__tile{position:relative;width:.78em;height:1.14em;overflow:hidden;border-radius:2px;background:linear-gradient(180deg,color-mix(in srgb,var(--color-ink) 86%,white),var(--color-ink));box-shadow:0 -.05em .1em rgba(0,0,0,.38) inset,0 .12em .26em rgba(26,23,18,.28);perspective:520px;transform-style:preserve-3d}
.split-flap__tile:before{content:'';position:absolute;z-index:8;top:calc(50% - .5px);left:0;width:100%;height:1px;background:linear-gradient(90deg,transparent,rgba(244,239,228,.16) 18%,rgba(0,0,0,.6) 50%,rgba(244,239,228,.12) 82%,transparent);pointer-events:none}
.split-flap__half,.split-flap__flap{position:absolute;left:0;width:100%;height:50%;overflow:hidden;background:var(--color-ink);backface-visibility:hidden}
.split-flap__half--top,.split-flap__flap--front{top:0}
.split-flap__half--bottom,.split-flap__flap--back{bottom:0;background:color-mix(in srgb,var(--color-ink) 92%,black)}
.split-flap__char{position:absolute;left:0;width:100%;height:200%;display:flex;align-items:center;justify-content:center;color:var(--color-paper);text-shadow:0 .09em .16em rgba(0,0,0,.42)}
.split-flap__half--top .split-flap__char,.split-flap__flap--front .split-flap__char{top:0}
.split-flap__half--bottom .split-flap__char,.split-flap__flap--back .split-flap__char{bottom:0}
.split-flap__flap{z-index:6;will-change:transform}
.split-flap__flap--front{transform-origin:center bottom;animation:split-flap-front var(--sf-flip,.1s) cubic-bezier(.23,1,.32,1) both}
.split-flap__flap--back{transform-origin:center top;transform:rotateX(90deg);animation:split-flap-back var(--sf-flip,.1s) cubic-bezier(.23,1,.32,1) both}
@keyframes split-flap-front{0%{transform:rotateX(0)}100%{transform:rotateX(-90deg)}}
@keyframes split-flap-back{0%,45%{transform:rotateX(90deg)}100%{transform:rotateX(0)}}
@media (prefers-reduced-motion:reduce){.split-flap__flap{animation:none!important}}
`

const sample = () => CHARSET.charAt(Math.floor(Math.random() * CHARSET.length))

function prefersReducedMotion() {
  return typeof window !== 'undefined' &&
    !!window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

// Marked on completion so StrictMode's dev double-mount still flips the board
// and a revisited tab shows the board already settled.
const played = new Set<string>()

export function SplitFlap({
  text,
  flipDuration = 0.1,
  stagger = 45,
  flipsPerChar = 5,
  className = '',
  style = {},
}: {
  text: string
  flipDuration?: number
  stagger?: number
  flipsPerChar?: number
  className?: string
  style?: CSSProperties
}) {
  const target = useMemo(() => text.toUpperCase(), [text])
  const [tiles, setTiles] = useState<Tile[]>(() => {
    const settled = prefersReducedMotion() || played.has(target)
    return target.split('').map((c) => ({
      current: settled ? c : ' ', next: settled ? c : ' ', flipping: false, tick: 0,
    }))
  })
  const rafRef = useRef<number | null>(null)

  useEffect(() => {
    if (prefersReducedMotion() || played.has(target)) {
      setTiles(target.split('').map((c) => ({ current: c, next: c, flipping: false, tick: 0 })))
      return
    }

    const flipMs = Math.max(40, flipDuration * 1000)
    // Blank space stays a blank tile; every other char flips through the drum.
    const plans = target.split('').map((c, i) => ({
      index: i,
      sequence: c === ' ' ? [' '] : [...Array.from({ length: flipsPerChar }, sample), c],
      start: i * stagger,
      step: -1,
      done: false,
    }))
    setTiles(target.split('').map(() => ({ current: ' ', next: ' ', flipping: false, tick: 0 })))

    let cancelled = false
    const startedAt = performance.now()
    const tick = (now: number) => {
      if (cancelled) return
      const elapsed = now - startedAt
      let live = false
      const updates: { i: number; t: Tile }[] = []
      for (const p of plans) {
        const local = elapsed - p.start
        if (local < 0) { live = true; continue }
        const step = Math.floor(local / flipMs)
        if (step < p.sequence.length) {
          live = true
          if (step !== p.step) {
            p.step = step
            updates.push({ i: p.index, t: {
              current: step === 0 ? ' ' : p.sequence[step - 1],
              next: p.sequence[step], flipping: true, tick: step,
            } })
          }
        } else if (!p.done) {
          p.done = true
          const c = p.sequence[p.sequence.length - 1]
          updates.push({ i: p.index, t: { current: c, next: c, flipping: false, tick: p.sequence.length } })
        }
      }
      if (updates.length) {
        setTiles((prev) => {
          const next = [...prev]
          for (const u of updates) if (next[u.i]) next[u.i] = u.t
          return next
        })
      }
      if (live) {
        rafRef.current = requestAnimationFrame(tick)
      } else {
        rafRef.current = null
        played.add(target)
      }
    }
    rafRef.current = requestAnimationFrame(tick)
    return () => {
      cancelled = true
      if (rafRef.current) cancelAnimationFrame(rafRef.current)
    }
  }, [target, flipDuration, stagger, flipsPerChar])

  return (
    <>
      <style>{styles}</style>
      <span
        className={`split-flap inline-flex items-center whitespace-pre select-none align-baseline ${className}`.trim()}
        style={{ '--sf-flip': `${flipDuration}s`, ...style } as CSSProperties}
        role="text"
        aria-label={target}
      >
        {tiles.map((tile, i) => (
          <span className="split-flap__tile" aria-hidden="true" key={i}>
            <span className="split-flap__half split-flap__half--top">
              <span className="split-flap__char">{tile.current === ' ' ? ' ' : tile.current}</span>
            </span>
            <span className="split-flap__half split-flap__half--bottom">
              <span className="split-flap__char">{tile.flipping ? tile.next : tile.current}</span>
            </span>
            {tile.flipping && (
              <>
                <span className="split-flap__flap split-flap__flap--front" key={`f-${i}-${tile.tick}`}>
                  <span className="split-flap__char">{tile.current === ' ' ? ' ' : tile.current}</span>
                </span>
                <span className="split-flap__flap split-flap__flap--back" key={`b-${i}-${tile.tick}`}>
                  <span className="split-flap__char">{tile.next === ' ' ? ' ' : tile.next}</span>
                </span>
              </>
            )}
          </span>
        ))}
      </span>
    </>
  )
}
