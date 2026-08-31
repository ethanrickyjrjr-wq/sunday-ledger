import type { CSSProperties } from 'react'

// The freeze clock. The Wednesday deadline is the product, so it gets the
// board treatment: ink tiles, Departure Mono, and one odometer roll per digit
// change. Unlike SplitFlap (a one-shot reveal), this ticks — that ongoing
// motion is the point: the board is counting on you.

const styles = `
.flap-clock{display:inline-flex;align-items:baseline;gap:.5em;font-family:var(--font-flap);font-variant-numeric:tabular-nums}
.flap-clock__group{display:inline-flex;align-items:baseline;gap:.14em}
.flap-clock__tile{position:relative;display:inline-flex;align-items:center;justify-content:center;width:1.05em;height:1.35em;overflow:hidden;border-radius:2px;background:linear-gradient(180deg,color-mix(in srgb,var(--color-ink) 86%,white),var(--color-ink));box-shadow:0 -.05em .1em rgba(0,0,0,.38) inset,0 .1em .2em rgba(26,23,18,.25);color:var(--color-paper)}
.flap-clock__tile:before{content:'';position:absolute;z-index:2;top:calc(50% - .5px);left:0;width:100%;height:1px;background:linear-gradient(90deg,transparent,rgba(0,0,0,.55) 50%,transparent);pointer-events:none}
.flap-clock__char{display:block;animation:flap-roll .28s cubic-bezier(.23,1,.32,1) both}
@keyframes flap-roll{from{transform:translateY(-105%)}to{transform:translateY(0)}}
.flap-clock__unit{font-size:.5em;letter-spacing:.1em;color:var(--color-ink-dim)}
@media (prefers-reduced-motion:reduce){.flap-clock__char{animation:none!important}}
`

function Group({ value, unit, pad = 2 }: { value: number; unit: string; pad?: number }) {
  const chars = String(value).padStart(pad, '0').split('')
  return (
    <span className="flap-clock__group" aria-hidden="true">
      {chars.map((c, i) => (
        <span className="flap-clock__tile" key={i}>
          {/* keyed on the char so a change remounts it and rolls it in */}
          <span className="flap-clock__char" key={c}>{c}</span>
        </span>
      ))}
      <span className="flap-clock__unit">{unit}</span>
    </span>
  )
}

export function FlapClock({
  days, hours, minutes, seconds, className = '', style = {},
}: {
  days: number; hours: number; minutes: number; seconds: number
  className?: string; style?: CSSProperties
}) {
  const label = `${days} days ${hours} hours ${minutes} minutes ${seconds} seconds`
  return (
    <>
      <style>{styles}</style>
      <span className={`flap-clock ${className}`.trim()} style={style} role="timer" aria-label={label}>
        {days > 0 && <Group value={days} unit="D" pad={1} />}
        <Group value={hours} unit="H" />
        <Group value={minutes} unit="M" />
        <Group value={seconds} unit="S" />
      </span>
    </>
  )
}
