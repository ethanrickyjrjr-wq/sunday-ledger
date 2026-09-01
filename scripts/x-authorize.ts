// One-shot X authorization — turns a Client ID into the refresh token the wire
// runs on. Run it once, by hand, after the app exists in the Developer Console.
//
//   deno run --allow-net --allow-env scripts/x-authorize.ts
//
// Nothing here is automated and nothing is written to the repo: the script
// prints a URL, you approve it in a browser as @sundayledgerai, and it prints
// the SQL to paste into the Supabase editor. The refresh token never touches
// .env.local or a GitHub secret — it rotates on every use and lives in the
// database (decision O, 20260901100000_x_wire.sql).
//
// Endpoints verified live against docs.x.com 2026-08-31:
//   authorize  https://x.com/i/oauth2/authorize   (response_type, client_id,
//              redirect_uri, scope, state, code_challenge, code_challenge_method)
//   token      https://api.x.com/2/oauth2/token   (form-encoded)
//
// offline.access is NOT optional: without it X issues no refresh token at all
// and the cron cannot run unattended.
const SCOPES = 'tweet.read tweet.write users.read offline.access'
const REDIRECT = 'http://127.0.0.1:3000/callback'
const PORT = 3000

const clientId = Deno.env.get('X_CLIENT_ID') ?? prompt('X Client ID:')?.trim()
if (!clientId) {
  console.error('no client id — copy it from console.x.com → your app → Keys and tokens')
  Deno.exit(1)
}
// Blank is correct for a public client; paste the secret for a confidential one.
const clientSecret = Deno.env.get('X_CLIENT_SECRET') ?? prompt('X Client Secret (blank if public client):')?.trim()

const b64url = (b: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

const verifier = b64url(crypto.getRandomValues(new Uint8Array(64)))
const challenge = b64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)))
const state = b64url(crypto.getRandomValues(new Uint8Array(16)))

const authorize = `https://x.com/i/oauth2/authorize?` + new URLSearchParams({
  response_type: 'code',
  client_id: clientId,
  redirect_uri: REDIRECT,
  scope: SCOPES,
  state,
  code_challenge: challenge,
  code_challenge_method: 'S256',
})

console.log('\n  Sign in as @sundayledgerai and approve:\n')
console.log(`  ${authorize}\n`)
console.log(`  Waiting for the callback on ${REDIRECT} …\n`)

const code = await new Promise<string>((resolve, reject) => {
  const server = Deno.serve({ port: PORT, hostname: '127.0.0.1', onListen: () => {} }, (req) => {
    const u = new URL(req.url)
    if (u.pathname !== '/callback') return new Response('waiting', { status: 404 })
    const err = u.searchParams.get('error')
    if (err) {
      reject(new Error(`${err}: ${u.searchParams.get('error_description') ?? ''}`))
      return new Response('Denied. Back to the terminal.', { headers: { 'content-type': 'text/plain' } })
    }
    // The state check is the CSRF wall; a mismatch means this callback is not
    // the one this run started.
    if (u.searchParams.get('state') !== state) {
      reject(new Error('state mismatch — start over'))
      return new Response('State mismatch.', { status: 400 })
    }
    const c = u.searchParams.get('code')
    if (!c) {
      reject(new Error('no code on the callback'))
      return new Response('No code.', { status: 400 })
    }
    queueMicrotask(() => { server.shutdown(); resolve(c) })
    return new Response('The Sunday Ledger is authorized. Back to the terminal.', {
      headers: { 'content-type': 'text/plain' },
    })
  })
})

const headers: Record<string, string> = { 'Content-Type': 'application/x-www-form-urlencoded' }
if (clientSecret) headers.Authorization = `Basic ${btoa(`${clientId}:${clientSecret}`)}`

const res = await fetch('https://api.x.com/2/oauth2/token', {
  method: 'POST',
  headers,
  body: new URLSearchParams({
    grant_type: 'authorization_code',
    code,
    client_id: clientId,
    redirect_uri: REDIRECT,
    code_verifier: verifier,
  }),
})
const out = await res.json().catch(() => ({})) as {
  refresh_token?: string; access_token?: string; scope?: string; expires_in?: number
  error?: string; error_description?: string
}
if (!res.ok || !out.refresh_token) {
  console.error(`\n  X refused the exchange (${res.status}) ${out.error ?? ''} ${out.error_description ?? ''}`)
  if (res.ok && !out.refresh_token) {
    console.error('  A token came back with NO refresh token — the app was authorized without')
    console.error('  offline.access. Check the scopes on the app and run this again.')
  }
  Deno.exit(1)
}

const sql = `insert into public.league_x_auth (only_row, refresh_token)
values (true, '${out.refresh_token.replace(/'/g, "''")}')
on conflict (only_row) do update set refresh_token = excluded.refresh_token,
  access_token = null, expires_at = null, rotated_at = now();`

console.log(`\n  Authorized. scopes: ${out.scope ?? '(none reported)'}\n`)
console.log('  Paste this into the Supabase SQL editor (project xtgkasakmioyzpwiwejk):\n')
console.log(sql)
console.log(`\n  Then set the app credentials as function secrets:\n`)
console.log(`  supabase secrets set X_CLIENT_ID=${clientId} X_CLIENT_SECRET=<secret> --project-ref xtgkasakmioyzpwiwejk\n`)
console.log('  This token rotates on every use. Do not commit it, and do not keep a copy —')
console.log('  the copy goes stale the first time the wire posts.\n')
