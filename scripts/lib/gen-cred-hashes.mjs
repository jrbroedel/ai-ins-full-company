#!/usr/bin/env node
// gen-cred-hashes.mjs — derive PBKDF2 credential hashes for the torque-website
// Worker (CRED_HASHES_V2 secret). Contains no secrets; the credentials file is
// supplied at runtime and must never be committed.
//
// Usage:  node scripts/lib/gen-cred-hashes.mjs /path/to/credentials.txt > out.json
//
// Input format: the credential sheet as issued — lines matching
//   <row#>  <username>  <password>
// (whitespace-delimited; header/separator/comment lines are ignored).
// Password is everything after the username, trimmed of line-ending whitespace
// only — no other normalization, per Kent: passwords are used exactly as listed.
//
// Output: JSON on stdout:
//   { "<username>": { "salt": "<b64>", "hash": "<b64>", "iterations": 100000 } }
//
// Parameters MUST match the Worker's WebCrypto verification
// (website/src/worker.js): PBKDF2-SHA256, 100000 iterations (Cloudflare Workers WebCrypto caps PBKDF2 at 100000), 16-byte random
// salt per user, 32-byte derived key.
//
// Credential rotation: regenerate the JSON with this script, then
//   npx wrangler secret put CRED_HASHES_V2 < out.json
// and redeploy. No code change needed.

import { pbkdf2Sync, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";

const ITERATIONS = 100000; // Cloudflare Workers WebCrypto rejects PBKDF2 above 100000
const SALT_BYTES = 16;
const KEY_BYTES = 32;

const path = process.argv[2];
if (!path) {
  console.error("usage: gen-cred-hashes.mjs <credentials-file>");
  process.exit(1);
}

const lines = readFileSync(path, "utf8").split(/\r?\n/);
const creds = new Map();
for (const line of lines) {
  const m = line.match(/^\s*\d+\s+(\S+)\s+(.*\S)\s*$/);
  if (!m) continue;
  const [, user, pass] = m;
  if (!/^[a-z]\.[a-z]+$/.test(user)) continue; // skip non-credential rows
  if (creds.has(user)) {
    console.error(`duplicate username: ${user}`);
    process.exit(1);
  }
  creds.set(user, pass);
}

if (creds.size === 0) {
  console.error("no credential rows parsed");
  process.exit(1);
}

const out = {};
for (const [user, pass] of creds) {
  const salt = randomBytes(SALT_BYTES);
  const hash = pbkdf2Sync(pass, salt, ITERATIONS, KEY_BYTES, "sha256");
  out[user] = {
    salt: salt.toString("base64"),
    hash: hash.toString("base64"),
    iterations: ITERATIONS
  };
}

console.error(`hashed ${creds.size} credentials`);
process.stdout.write(JSON.stringify(out) + "\n");
