// torque-website Worker — server-side session auth for the client portal.
//
// Replaces the former client-side CRED_HASHES gate (ADR: worker-native session
// auth). Secrets (set via `wrangler secret put`, never committed):
//   CRED_HASHES_V2  JSON: { "<user>": { salt, hash, iterations } } — PBKDF2-SHA256,
//                   100000 iterations (Cloudflare cap), 16-byte salt, 32-byte key, base64. Generated
//                   by scripts/lib/gen-cred-hashes.mjs.
//   SESSION_SECRET  base64, 32 random bytes — HMAC-SHA256 key for session cookies.
//
// Session cookie: tq_sess = base64url({"u":user,"exp":unixSeconds}) + "." +
// base64url(HMAC-SHA256(payload)). HttpOnly; Secure; SameSite=Lax; Path=/;
// 12-hour expiry.

const COOKIE_NAME = "tq_sess";
const SESSION_SECONDS = 12 * 60 * 60;
const PROTECTED_PREFIXES = ["/portal"];
const LOGIN_REDIRECT = "/?login=1";
const FAIL_DELAY_MS = 500;

// Best-effort brute-force damping. NOTE: this state is per-isolate and
// advisory only — Cloudflare may run many isolates and evict them at any
// time, so this is damping, not a real rate limit. Acceptable for this
// audience per the standing decision (no KV / Durable Objects / new services).
const FAILS_BEFORE_LOCK = 10;
const LOCK_MS = 60 * 1000;
const failures = new Map(); // ip -> { count, lockedUntil }

const enc = new TextEncoder();

function b64urlEncode(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(str) {
  const pad = "=".repeat((4 - (str.length % 4)) % 4);
  const s = atob(str.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i += 1) out[i] = s.charCodeAt(i);
  return out;
}

function b64Decode(str) {
  const s = atob(str);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i += 1) out[i] = s.charCodeAt(i);
  return out;
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function hmacKey(env) {
  return crypto.subtle.importKey(
    "raw", b64Decode(env.SESSION_SECRET), { name: "HMAC", hash: "SHA-256" },
    false, ["sign"]
  );
}

async function signPayload(env, payloadBytes) {
  const key = await hmacKey(env);
  const sig = await crypto.subtle.sign("HMAC", key, payloadBytes);
  return new Uint8Array(sig);
}

async function mintCookie(env, user) {
  const payload = enc.encode(JSON.stringify({ u: user, exp: Math.floor(Date.now() / 1000) + SESSION_SECONDS }));
  const sig = await signPayload(env, payload);
  return `${b64urlEncode(payload)}.${b64urlEncode(sig)}`;
}

async function verifyCookie(env, cookieHeader) {
  if (!cookieHeader) return null;
  const m = cookieHeader.match(new RegExp(`(?:^|;\\s*)${COOKIE_NAME}=([^;]+)`));
  if (!m) return null;
  const parts = m[1].split(".");
  if (parts.length !== 2) return null;
  let payloadBytes, gotSig;
  try {
    payloadBytes = b64urlDecode(parts[0]);
    gotSig = b64urlDecode(parts[1]);
  } catch (e) {
    return null;
  }
  const wantSig = await signPayload(env, payloadBytes);
  if (!timingSafeEqual(gotSig, wantSig)) return null;
  let payload;
  try {
    payload = JSON.parse(new TextDecoder().decode(payloadBytes));
  } catch (e) {
    return null;
  }
  if (!payload || typeof payload.u !== "string" || typeof payload.exp !== "number") return null;
  if (Math.floor(Date.now() / 1000) >= payload.exp) return null;
  return payload;
}

function sessionCookieHeader(value, maxAge) {
  return `${COOKIE_NAME}=${value}; Max-Age=${maxAge}; Path=/; HttpOnly; Secure; SameSite=Lax`;
}

async function verifyCredential(env, username, password) {
  const creds = JSON.parse(env.CRED_HASHES_V2);
  const entry = creds[username];
  // Unknown user: still run a full PBKDF2 derivation against a fixed dummy
  // salt so response timing does not reveal whether the username exists.
  const salt = entry ? b64Decode(entry.salt) : new Uint8Array(16);
  const iterations = entry ? entry.iterations : 100000;
  const keyMaterial = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  const derived = new Uint8Array(await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations }, keyMaterial, 256
  ));
  if (!entry) return false;
  return timingSafeEqual(derived, b64Decode(entry.hash));
}

function uniformLoginFailure() {
  // Byte-identical body whether the username exists or not.
  return new Response(JSON.stringify({ ok: false, error: "Those credentials were not recognised." }), {
    status: 401,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" }
  });
}

async function readLoginBody(request) {
  const ct = (request.headers.get("Content-Type") || "").toLowerCase();
  if (ct.includes("application/json")) {
    const body = await request.json();
    return { username: body.username, password: body.password };
  }
  const form = await request.formData();
  return { username: form.get("username"), password: form.get("password") };
}

async function handleLogin(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") || "local";
  const rec = failures.get(ip);
  const now = Date.now();
  if (rec && rec.lockedUntil > now) {
    return new Response(JSON.stringify({ ok: false, error: "Too many attempts. Try again shortly." }), {
      status: 429, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "Retry-After": "60" }
    });
  }

  let username, password;
  try {
    ({ username, password } = await readLoginBody(request));
  } catch (e) {
    username = null;
  }
  username = typeof username === "string" ? username.trim().toLowerCase() : "";
  password = typeof password === "string" ? password : "";

  let ok = false;
  if (username && password) ok = await verifyCredential(env, username, password);

  if (!ok) {
    const count = ((rec && rec.lockedUntil <= now ? 0 : rec?.count) || 0) + 1;
    failures.set(ip, { count, lockedUntil: count >= FAILS_BEFORE_LOCK ? now + LOCK_MS : 0 });
    await new Promise((resolve) => setTimeout(resolve, FAIL_DELAY_MS));
    return uniformLoginFailure();
  }

  failures.delete(ip);
  const cookie = await mintCookie(env, username);
  return new Response(JSON.stringify({ ok: true, redirect: "/portal/" }), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Set-Cookie": sessionCookieHeader(cookie, SESSION_SECONDS)
    }
  });
}

function handleLogout() {
  return new Response(null, {
    status: 302,
    headers: {
      Location: "/",
      "Cache-Control": "no-store",
      "Set-Cookie": sessionCookieHeader("", 0)
    }
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/api/login") {
      if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
      return handleLogin(request, env);
    }

    if (path === "/api/logout") {
      if (request.method !== "POST" && request.method !== "GET") {
        return new Response("Method Not Allowed", { status: 405 });
      }
      return handleLogout();
    }

    if (path === "/api/session") {
      const session = await verifyCookie(env, request.headers.get("Cookie"));
      if (!session) {
        return new Response(JSON.stringify({ ok: false }), {
          status: 401, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" }
        });
      }
      return new Response(JSON.stringify({ ok: true, user: session.u, exp: session.exp }), {
        status: 200, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" }
      });
    }

    const isProtected = PROTECTED_PREFIXES.some(
      (prefix) => path === prefix || path.startsWith(prefix + "/")
    );
    if (isProtected) {
      const session = await verifyCookie(env, request.headers.get("Cookie"));
      if (!session) {
        return new Response(null, { status: 302, headers: { Location: LOGIN_REDIRECT, "Cache-Control": "no-store" } });
      }
      const assetResponse = await env.ASSETS.fetch(request);
      const response = new Response(assetResponse.body, assetResponse);
      // Protected content must not land in any shared cache.
      response.headers.set("Cache-Control", "private, no-store");
      return response;
    }

    return env.ASSETS.fetch(request);
  }
};
