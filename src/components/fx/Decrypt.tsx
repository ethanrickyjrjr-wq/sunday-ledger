import { useEffect, useState } from 'react'

// Scramble-to-plaintext, the agents' greeting. Pattern from react-bits'
// Decrypted Text (MIT + Commons Clause), re-cut to house discipline: one
// pass, left to right, then still forever. Zero dependencies.

const GLYPHS = '#$%&@!?/\\<>[]{}=+*ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
const sample = () => GLYPHS.charAt(Math.floor(Math.random() * GLYPHS.length))

const still = () => typeof window !== 'undefined' && !!window.matchMedia &&
  window.matchMedia('(prefers-reduced-motion: reduce)').matches

// Marked on completion so StrictMode's dev double-mount still plays and a
// revisited tab reads plaintext.
const played = new Set<string>()

export function Decrypt({ text, speed = 24 }: { text: string; speed?: number }) {
  const [locked, setLocked] = useState(() => (still() || played.has(text) ? text.length : 0))
  const [, force] = useState(0)

  useEffect(() => {
    if (still() || played.has(text)) {
      setLocked(text.length)
      return
    }
    setLocked(0)
    const t = setInterval(() => {
      setLocked((n) => {
        const next = Math.min(n + 1, text.length)
        if (next >= text.length) {
          clearInterval(t)
          played.add(text)
        }
        return next
      })
      force((f) => f + 1) // re-scramble the unresolved tail each tick
    }, speed)
    return () => clearInterval(t)
  }, [text, speed])

  const done = locked >= text.length
  return (
    <span aria-label={text} role="text">
      <span aria-hidden="true">
        {text.slice(0, locked)}
        {!done && text.slice(locked).split('').map((c, i) => (c === ' ' ? ' ' : <span key={i}>{sample()}</span>))}
      </span>
    </span>
  )
}
