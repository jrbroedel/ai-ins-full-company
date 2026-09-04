# ADR 0050 — Worker-native session auth for website.ironcliffvertex.com

Status: Accepted — 2026-09-04. Deployed to the `torque-website` Cloudflare Worker.
Builds on the web-root baseline commit (reconstructed from the live site + Workers
API on 2026-09-04; see `website/README.md` for provenance).

## Context

The public site (Cloudflare Worker with static assets, NOT Pages) gated its client
portal purely in the browser: a `CRED_HASHES` set of 16-hex-char non-cryptographic
hashes shipped in `index.html`, checked client-side, revealing an in-page portal
section. Anyone reading page source could extract the hash list, and the "portal"
content was in the public HTML anyway. The credential sheet (26 broker users,
fixed passwords supplied by Kent) needed to actually authenticate server-side.

## Decision

Worker-native session auth, no new infrastructure:

- **Credential store**: Worker secret `CRED_HASHES_V2` — JSON of
  `{ user: { salt, hash, iterations } }`, PBKDF2-SHA256, **100,000 iterations**,
  16-byte per-user random salt, 32-byte derived key. Generated offline by
  `scripts/lib/gen-cred-hashes.mjs` (committed; contains no secrets).
  - Deviation from the build spec's 210,000 iterations: **Cloudflare Workers
    WebCrypto hard-caps PBKDF2 at 100,000 iterations** (production throws
    `NotSupportedError` above that; local workerd does not enforce the cap).
    100,000 is the platform maximum and is what ships.
- **Login**: `POST /api/login` (JSON `{username, password}` from the landing-page
  modal). WebCrypto PBKDF2 verify, constant-time digest comparison; unknown
  usernames still burn a full PBKDF2 derivation, and failures share a
  byte-identical 401 body plus a ~500 ms delay, so username existence is not
  observable. Per-isolate advisory lockout (10 failures → 60 s) — damping only,
  by design (no KV/DO).
- **Session**: `tq_sess` cookie = `base64url({"u":user,"exp":unixSeconds}) "." 
  base64url(HMAC-SHA256(payload, SESSION_SECRET))`; `HttpOnly; Secure;
  SameSite=Lax; Path=/`; 12-hour expiry. `SESSION_SECRET` is a 32-byte random
  Worker secret. `POST /api/logout` expires it; `GET /api/session` reports
  `{user, exp}` for page chrome.
- **Protection scope**: the old gate protected the portal *section embedded in*
  `index.html` — no distinct path existed. The portal content moved to
  `/portal/` (its own page, metered-viewing/approval-code flow intact), and the
  Worker 302-redirects any `/portal` / `/portal/*` request without a valid,
  unexpired cookie to `/?login=1` (the landing login modal auto-opens). Assets
  under the protected prefix route through the Worker via
  `run_worker_first: ["/portal", "/portal/*", "/api/*"]` and are served
  `Cache-Control: private, no-store`. Marketing landing, `assets/`, and the 400
  scroll-film frames under `frames/` stay public (the public film needs them).
- The client-side `CRED_HASHES` set, `tqHash` login check, and in-page portal
  are **removed from shipped JS entirely** — no hashes ship to the browser.
  (Note: only 20 of the 26 credential rows had ever been added to the old
  client-side hash list; all 26 work server-side now.)

## Alternatives rejected

- **Cloudflare Access / Entra convergence** — per Dash: no new infrastructure;
  fixed passwords supplied by Kent must work as issued.
- **KV/Durable-Object-backed sessions or rate limiting** — out of scope by the
  same constraint; stateless HMAC cookies need no storage, and the advisory
  per-isolate lockout is accepted for this audience.

## Rotation runbook

Credential rotation is data-only, no code change:

1. `node scripts/lib/gen-cred-hashes.mjs <new-credentials-file> > hashes.json`
2. `npx wrangler secret put CRED_HASHES_V2 < hashes.json` (from `website/`)
3. `npx wrangler deploy` (from `website/`) — new secret takes effect
4. Shred the plaintext file and `hashes.json`.

Rotating `SESSION_SECRET` (invalidates all live sessions): put a fresh 32-byte
base64 value the same way and redeploy.

## Verification

Nine-check suite (302 without cookie; public 200; three real logins incl. a
weak-password user; cookie grants 200; wrong-password 401; unknown-user 401
byte-identical; tampered signature 302; expired self-minted cookie 302; logout
expiry) passed locally under `wrangler dev` and re-passed against
`https://website.ironcliffvertex.com` post-deploy. Pre/post-deploy sha256
manifest over all 402 public URLs: only `/` changed (the intended auth wiring,
byte-equal to the committed source); `/portal/` with a session serves the
committed portal page byte-for-byte.
