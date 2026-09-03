# Adversarial proof for the carry + alarm change (migration 20260903140000).
# ASCII only. Run AFTER `supabase db push` and `supabase functions deploy league`.
#
#   Read-only (safe any time):   pwsh ./supabase/proof-carry-alarm.ps1
#   Full proof (writes a carry):  pwsh ./supabase/proof-carry-alarm.ps1 -Write -GameId <event_id>
#
# The write half CARRIES A REAL GAME on the live ledger and ledgers it forever.
# Only run it against a game you actually intend to mark postponed, or against a
# past game in a settled week you are willing to have a game_carried row for.
# There is no uncarry: section 7 says the record is appended, never rewritten.

param(
  [switch]$Write,
  [string]$GameId = ""
)

$ErrorActionPreference = "Stop"
$base = "https://xtgkasakmioyzpwiwejk.supabase.co/functions/v1/league"

# LEAGUE_HOUSE_KEY out of .env.local, never echoed.
$envFile = Join-Path $PSScriptRoot "..\.env.local"
if (-not (Test-Path $envFile)) { throw "no .env.local at $envFile" }
$houseKey = (Get-Content $envFile | Where-Object { $_ -match '^LEAGUE_HOUSE_KEY=' }) -replace '^LEAGUE_HOUSE_KEY=', ''
$houseKey = $houseKey.Trim().Trim('"')
if (-not $houseKey) { throw "LEAGUE_HOUSE_KEY not found in .env.local" }
$houseHdr = @{ "x-house-key" = $houseKey; "Content-Type" = "application/json" }

# StatusCode is an int in Windows PowerShell 5.1 and an enum in pwsh 7; read
# both so the proof does not fail for the wrong reason.
function StatusOf($err) {
  $r = $err.Exception.Response
  if ($null -eq $r) { return 0 }
  if ($r.StatusCode -is [int]) { return [int]$r.StatusCode }
  return [int]$r.StatusCode.value__
}

# A refusal check must not throw its own FAIL inside the try, or the catch
# swallows it and reports a pass. Returns the HTTP status, or 0 if the call
# unexpectedly SUCCEEDED (which is always a failure for these checks).
function MustRefuse($scriptblock) {
  try { & $scriptblock | Out-Null } catch { return (StatusOf $_) }
  return 0
}

function Show($label, $obj) {
  Write-Host ""
  Write-Host "--- $label" -ForegroundColor Cyan
  $obj | ConvertTo-Json -Depth 6
}

# =============================================================== READ-ONLY HALF

Write-Host "=== READ-ONLY PROOFS ===" -ForegroundColor Green

# 1. The manifest advertises the carry door.
$manifest = Invoke-RestMethod "$base"
$carryDoc = $manifest.api.'POST ?carry'
if (-not $carryDoc) { throw "FAIL: the manifest does not advertise POST ?carry - is the function deployed?" }
Write-Host "PASS: manifest advertises POST ?carry"

# 2. The week payload carries per-game carry state (proves the patched
#    league_week_json is the one running).
$week = Invoke-RestMethod "$base`?week"
$g0 = $week.games[0]
if ($g0.PSObject.Properties.Name -notcontains 'carried_at') {
  throw "FAIL: games have no carried_at - the migration did not apply"
}
Write-Host "PASS: week payload exposes carried_at / carry_note per game"
Write-Host ("      season {0} week {1} settled_at {2} carried {3}" -f $week.season, $week.week, $week.settled_at, $week.carried)

# 3. The carry door refuses an anonymous caller (401), like every house door.
$code = MustRefuse { Invoke-RestMethod -Method Post "$base`?carry" `
  -Headers @{ "Content-Type" = "application/json" } `
  -Body '{"game_id":"x","note":"anonymous attempt, should be refused"}' }
if ($code -eq 0)   { throw "FAIL: ?carry answered an anonymous caller" }
if ($code -ne 401) { throw "FAIL: expected 401 from ?carry, got $code" }
Write-Host "PASS: ?carry refuses an anonymous caller with 401"

# 4. The settle door reports health, and health is honest about today.
$settle = Invoke-RestMethod -Method Post "$base`?settle" -Headers $houseHdr -Body '{}'
if ($null -eq $settle.ok) { throw "FAIL: ?settle returned no ok field - old function still deployed" }
Show "?settle" $settle
Write-Host ("PASS: ?settle reports ok={0}, stuck={1}, carried={2}" -f `
  $settle.ok, $settle.health.stuck.Count, $settle.health.carried.Count)

# 5. A game that has not kicked off yet must never be stuck.
$future = @($week.games | Where-Object { [datetime]$_.kickoff -gt (Get-Date).ToUniversalTime() })
$stuckIds = @($settle.health.stuck | ForEach-Object { $_.game_id })
foreach ($f in $future) {
  if ($stuckIds -contains $f.game_id) { throw "FAIL: unkicked game $($f.game_id) reported stuck" }
}
Write-Host ("PASS: none of the {0} future games are reported stuck" -f $future.Count)

if (-not $Write) {
  Write-Host ""
  Write-Host "Read-only proofs passed. Re-run with -Write -GameId <event_id> for the carry proof." -ForegroundColor Yellow
  exit 0
}

# ==================================================================== WRITE HALF

if (-not $GameId) { throw "-Write requires -GameId <event_id>" }

Write-Host ""
Write-Host "=== WRITE PROOFS (this carries a real game, permanently) ===" -ForegroundColor Red

# 6. A carry before kickoff+3h is refused: a late game is not a postponed one.
$target = $week.games | Where-Object { $_.game_id -eq $GameId }
if ($target -and ([datetime]$target.kickoff).AddHours(3) -gt (Get-Date).ToUniversalTime()) {
  $code = MustRefuse { Invoke-RestMethod -Method Post "$base`?carry" -Headers $houseHdr `
    -Body (@{ game_id = $GameId; note = "too early, should be refused" } | ConvertTo-Json) }
  if ($code -eq 0) { throw "FAIL: ?carry accepted a game less than 3h past kickoff" }
  Write-Host "PASS: ?carry refuses a game that is merely late, not postponed"
  Write-Host "Game is not yet 3h past kickoff - stopping before the real carry." -ForegroundColor Yellow
  exit 0
}

# 7. A carry with no note is refused: the record is never silent.
$code = MustRefuse { Invoke-RestMethod -Method Post "$base`?carry" -Headers $houseHdr `
  -Body (@{ game_id = $GameId; note = "" } | ConvertTo-Json) }
if ($code -eq 0) { throw "FAIL: ?carry accepted an empty note" }
Write-Host "PASS: ?carry refuses a carry with no note"

# 8. The carry itself.
$carry = Invoke-RestMethod -Method Post "$base`?carry" -Headers $houseHdr `
  -Body (@{ game_id = $GameId; note = "Proof run: postponement carry per section 7." } | ConvertTo-Json)
Show "?carry" $carry
Write-Host ("PASS: carried {0} (week_settled={1})" -f $carry.game, $carry.week_settled)

# 9. The carried game leaves stuck and appears under carried.
$after = Invoke-RestMethod -Method Post "$base`?settle" -Headers $houseHdr -Body '{}'
$afterStuck = @($after.health.stuck | ForEach-Object { $_.game_id })
if ($afterStuck -contains $GameId) { throw "FAIL: carried game is still reported stuck" }
$afterCarried = @($after.health.carried | ForEach-Object { $_.game_id })
if ($afterCarried -notcontains $GameId) { throw "FAIL: carried game is not reported under carried" }
Write-Host "PASS: the carried game left stuck and is reported as carried"

# 10. The carried game stays outside every computed number (section 7).
$standings = Invoke-RestMethod "$base`?standings"
Show "?standings" $standings
Write-Host "CHECK BY EYE: games_scored must not count the carried game; it enters"
Write-Host "              every denominator only when a result lands for it."
