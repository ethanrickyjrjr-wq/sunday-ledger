import { useEffect, useState } from 'react'

const still = () => typeof window !== 'undefined' && !!window.matchMedia &&
  window.matchMedia('(prefers-reduced-motion: reduce)').matches

// A statement only arrives over the wire once per visit. Marked on completion
// (not start) so StrictMode's double-mount in dev still plays it, while a tab
// switch back to a finished statement shows it settled.
const played = new Set<string>()

// The wire delivering a statement: characters arrive one at a time, once,
// with a block cursor that leaves when the message is complete.
export function Typewriter({ text, speed = 28 }: { text: string; speed?: number }) {
  const [shown, setShown] = useState(() => (still() || played.has(text) ? text.length : 0))

  useEffect(() => {
    if (still() || played.has(text)) {
      setShown(text.length)
      return
    }
    setShown(0)
    const t = setInterval(() => {
      setShown((n) => {
        const next = Math.min(n + 1, text.length)
        if (next >= text.length) {
          clearInterval(t)
          played.add(text)
        }
        return next
      })
    }, speed)
    return () => clearInterval(t)
  }, [text, speed])

  const done = shown >= text.length
  return (
    <span aria-label={text} role="text">
      <span aria-hidden="true">{text.slice(0, shown)}</span>
      {!done && <span aria-hidden="true" className="typewriter-cursor">▌</span>}
    </span>
  )
}
