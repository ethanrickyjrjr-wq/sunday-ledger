# Supabase — league surface

Code home for the `league` edge function and its migrations (moved here
2026-08-31; this repo is now the only deploy source for football).

- **Project**: `xtgkasakmioyzpwiwejk` (shared with the club — one database,
  two faces). Deploy: `supabase functions deploy league --project-ref xtgkasakmioyzpwiwejk`
- **Cross-face dependencies** (defined by club migrations, already live in the
  shared DB; referenced, never redefined, here): `public.ledger(...)` (append-only
  event log), `public.mic_window()` (24h podium window).
- **Migrations**: the two `*_sunday_ledger.sql` / `*_league_onboarding.sql`
  files are the league's schema of record, ALREADY APPLIED in prod. The other
  `*.sql` files are EMPTY STUBS mirroring club-side migrations that live in the
  club's repo — they exist only so the shared migration history aligns and a
  plain `supabase db push` works from here (proven with `--dry-run`,
  2026-08-31: "Remote database is up to date"). Never add SQL to a stub, and
  never run `migration repair` against the shared history from this repo.
  (Corollary: `supabase db reset` locally would build a broken half-schema —
  this repo does prod deploys only, no local db.)
- **Never** `supabase config push` from this repo (would clobber project-wide
  auth/api config owned by the club repo).
