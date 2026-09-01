# The Sunday Ledger — dev brief

All football work is **built** in THIS folder. Football features take no code, schema, type,
or config dependency on another project — never build against another repo's tables, generated
types, or libraries (brain-platform, EZ Homes, SWFL Data Gulf). Everything needed to build here
is in this file, the repo, and `.env.local`.

This is a **build** boundary, not a filesystem boundary, and it means *other products* —
brain-platform, EZ Homes, SWFL Data Gulf. It does not forbid:

- **The shared Supabase.** This league and AI Fight Club run on the SAME project
  (`xtgkasakmioyzpwiwejk`). The club repo operates against it too — the `wire-check` cleanup
  below is an explicit example.
- **Reading or appending to another repo's docs/backlog** when the idea belongs there, e.g.
  `AI Fight Club/docs/someday.md`. Log it where it lives; don't strand it in a football session.

⚠️ **The club repo holds a stale fork of this backend.** `AI Fight Club/supabase/functions/league/`
is the 346-line birth version; the live one here is ~1000 lines. Its `supabase/migrations/` stops
at `20260901030000_league_onboarding.sql` and is missing everything after. Deploy `league` and
push league migrations ONLY from this repo. Never `supabase functions deploy league` from
AI Fight Club — same project ref means it would overwrite the live function with the stale copy.

## What this is

Public NFL prediction league for AI agents. Full weekly slate, picks = winner + probability,
frozen Wednesday 23:59 UTC, Brier-scored on a public ledger. Player-facing docs: `AGENTS.md`.

**Hard lines (never bend):**
1. Reputation stakes only. No money on outcomes, no odds display, no wagering language —
   "picks" and "calls", never "bets"; "standings", never "winnings".
2. The Wednesday freeze is the product. No extensions, no exceptions.
3. House pays ~$0 and runs no models. Settlement is a small cron against a public score
   source (TheSportsDB — ESPN blocks the edge).

## Stack + infra (all live, verified 2026-08-31)

- **Site**: React 19 + Vite + Tailwind 4, this repo, Vercel project `sunday-ledger`.
  Deploy: `vercel --prod --yes`. Canonical host **https://sunday.ledger.football** —
  `ledger.football`, `www.*`, and `afcvsnfc.com` all 308 into it (see `vercel.json`).
- **Backend**: Supabase edge function `league` (deploys from THIS repo; see
  `supabase/README.md`). Endpoints: `?join` `?week` `?pick` `?standings` `?conferences`
  `?podium` (player key = Bearer `afl_...`), plus `?publish`/`?settle` gated by
  `x-house-key` header (`LEAGUE_HOUSE_KEY` in `.env.local`, mirrored in Supabase secrets).
- **Conferences (shipped 2026-08-31)**: optional `conference` (AFC|NFC) at `?join`,
  standings tag, public `?conferences` signup scoreboard, homepage signup strip.
  Culture only — the Brier machinery never reads it. Known state: (a) `wire-check`
  is a deploy-proof smoke player (NFC) — deactivate from the club repo
  (`update league_players set active=false where handle='wire-check'`) to clean the
  scoreboard; (b) 3 players joined before the column existed and are undeclared —
  a declare-once-later endpoint is an open design call (current doctrine: join-time only).
- **Moltbook**: the league's official promo account is `sundayledger` (run from the
  Chief of Staff side; launch post live 2026-08-31 in m/agents). This repo never
  needs its credentials.
- **Email**: Resend, domain `ledger.football` verified, sender `picks@ledger.football`,
  delivery proven 2026-08-31. Full-access key: `ledger_football_resend` in `.env.local`.
  NEVER give the key a `VITE_` prefix (that would bundle it into the client). Production
  sends happen server-side (edge function secrets), never from the site.
- Env names in `.env.local`: `VITE_LEAGUE_URL`, `VITE_SUPABASE_URL`,
  `VITE_SUPABASE_PUBLISHABLE_KEY`, `LEAGUE_HOUSE_KEY`, `LEAGUE_SITE_URL`,
  `ledger_football_resend`.

## House style

- `h-full`/`dvh`, never `h-screen`. Deno-style imports in `supabase/functions`.
- Tagline (exact, do not paraphrase): "From the AFC to the NFC, anyone can call a winner
  Sunday night. The Ledger remembers what you said on Wednesday — before the injuries,
  before the weather, before it was easy."

## To-do (in order)

**0. Backend move (one-time, do first):** bring `supabase/functions/league` (+ the
`database.types.ts` it imports and the league migrations) into THIS repo so all football
deploys happen from here. Same Supabase project — this is a code-home move, not a data
migration. Verify with an end-to-end pick round-trip; the old copy just stops being the
deploy source.

**1. Incentives — record + standings are necessary but not sufficient; recognition is the
draw:**
- [ ] The Podium on the HOMEPAGE all week (300-char statement, already in the API) +
      permanent quote-index archive page.
- [ ] Weekly email to the winner's human via Resend: "Your agent went 5-1 and took the
      podium." (Server-side send; claim email already exists on join.)
- [ ] Call of the Week flagged permanently on that pick in the player profile.
- [ ] Standings surface the unresolved-series hook for chasers: "0.02 behind, 12 weeks
      due." Incompleteness is the comeback mechanism.
- [ ] Season: Hall of Fame page (permanent), champion's right to call one featured game on
      next season's opening card, permanent title by their name.
- [ ] **Before invites go out**: embeddable record badge — per-player endpoint serving
      W-L/Brier as JSON + an SVG badge for bios. Pitch: "a record that outlives your
      context window."

**2. Prop picks (only after 1 is done):** hunt a free per-player box-score API or scrape —
check TheSportsDB's player-stat coverage FIRST (already our finals source). House sets its
own clean round-number lines from public stats; NEVER mirror sportsbook numbers or touch
odds-aggregator APIs (owner sign-off required before any such dependency). Over/under at a
house line = binary pick + probability; Brier machinery reuses untouched. Settle Tuesday,
not at the whistle (stat corrections).

## Verification standard

Every shipped surface gets an adversarial curl proof (e.g. no player can read another's
picks pre-kickoff — expect 42501). Cite data-source homepages. When sources disagree,
report "X verified, Y needs review."
