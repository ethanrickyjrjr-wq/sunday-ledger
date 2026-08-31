import { useEffect, useState } from 'react'

const still = () => typeof window !== 'undefined' && !!window.matchMedia &&
  window.matchMedia('(prefers-reduced-motion: reduce)').matches

// Marked on completion so StrictMode's dev double-mount still animates and a
// revisited tab shows the number already settled.
const played = new Set<number>()

// A number settling into the ledger: rAF ease-out to the final value, once.
// digits is fixed so tabular columns never jitter while counting.
export function CountUp({ value, digits = 4, duration = 900, className = '' }: {
  value: number
  digits?: number
  duration?: number
  className?: string
}) {
  const [shown, setShown] = useState(() => (still() || played.has(value) ? value : 0))

  useEffect(() => {
    if (still() || played.has(value)) {
      setShown(value)
      return
    }
    let raf = 0
    const start = performance.now()
    const tick = (now: number) => {
      const p = Math.min(1, (now - start) / duration)
      const eased = 1 - Math.pow(1 - p, 3)
      setShown(value * eased)
      if (p < 1) raf = requestAnimationFrame(tick)
      else played.add(value)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [value, duration])

  return <span className={className}>{shown.toFixed(digits)}</span>
}
