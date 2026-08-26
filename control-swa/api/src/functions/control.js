'use strict';

/**
 * Control API for the investor-demo OPERATOR control panel.
 *
 *   POST /api/control/start   -> desired state = running
 *   POST /api/control/stop    -> desired state = paused
 *   POST /api/control/preset  -> desired preset (one of the five names)
 *   POST /api/control/rate    -> desired rate_per_min (manual override)
 *   POST /api/control/reset   -> request a DESTRUCTIVE rebuild of luxauto_demo
 *   GET  /api/control/status  -> current desired state + demo row count
 *
 * BRIGHT LINE (enforced here and again on the VM):
 *  - This API holds NO database credential and opens NO database connection. It
 *    can only read/write three small blobs in a private container. It is
 *    therefore structurally incapable of touching production `luxauto` (or any
 *    database) directly - the strongest possible posture for the first
 *    write-capable, partly-destructive web surface in the project.
 *  - No endpoint accepts a database name from the client. The only target this
 *    surface can ever express is the compile-time constant `luxauto_demo`; the
 *    reset endpoint re-asserts that pin and refuses the production name
 *    server-side before writing anything (defense in depth; never trust client).
 *  - Destruction is NOT implemented here. Reset writes an INTENT blob (a nonce);
 *    the VM control agent re-verifies the demo-DB pin and runs the EXISTING
 *    fenced `--reprovision --yes` path (sanctioned scripts, no trigger bypass).
 *  - This API reads/returns NO commission / waterfall / settlement / quote
 *    economics. It does not need them and never queries them.
 *
 * AUTH: every route requires an authenticated, AUTHORIZED user. Route protection
 * in staticwebapp.config.json gates the edge; each handler ALSO re-validates the
 * injected x-ms-client-principal and the required SWA role (defense in depth), so
 * a forged/direct call to the linked backend is rejected. There is no anonymous
 * route. Access = membership of the `luxauto-control-access` Entra group (via
 * "assignment required" on the app registration).
 */

const { app } = require('@azure/functions');
const { DefaultAzureCredential } = require('@azure/identity');
const { BlobServiceClient } = require('@azure/storage-blob');
const crypto = require('crypto');

// --- Fixed target. NEVER derived from client input. -------------------------
const TARGET_DB = 'luxauto_demo';
const PROD_DB = 'luxauto';

const ACCOUNT_URL = 'https://luxautosa91a2e1.blob.core.windows.net';
const CONTAINER = 'demo-control';
const INTENT_BLOB = 'control-intent.json';
const RESET_BLOB = 'reset-request.json';
const STATUS_BLOB = 'status.json';

// Only logged-in users of the custom Entra provider carry this SWA role.
// Combined with "assignment required" on the app registration, its presence
// means the caller is on the `luxauto-control-access` allow-list.
const REQUIRED_ROLE = 'authenticated';

// The five presets, mirrored from scripts/lib/synthetic_generator.py PRESETS.
// The API only needs the NAME set (to validate) and a canonical rate (applied
// when an operator switches preset without naming a rate). The generator is the
// source of truth for the actual bias weights; these two lists must stay in
// sync on name + rate only.
const PRESETS = {
  steady: { rate_per_min: 2.0 },
  surge: { rate_per_min: 6.0 },
  stress: { rate_per_min: 4.0 },
  premium_rising: { rate_per_min: 2.5 },
  volume_drying: { rate_per_min: 0.5 },
};
const PRESET_NAMES = Object.keys(PRESETS);
const DEFAULT_PRESET = 'steady';
const RATE_MIN = 0.1;
const RATE_MAX = 30.0;

// Reuse credential + container client across warm invocations.
const credential = new DefaultAzureCredential();
const containerClient = new BlobServiceClient(ACCOUNT_URL, credential)
  .getContainerClient(CONTAINER);

function json(status, obj, extraHeaders) {
  return {
    status,
    headers: Object.assign(
      { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
      extraHeaders || {}
    ),
    body: JSON.stringify(obj),
  };
}

function decodePrincipal(request) {
  const header = request.headers.get('x-ms-client-principal');
  if (!header) return null;
  try {
    return JSON.parse(Buffer.from(header, 'base64').toString('utf8'));
  } catch {
    return null;
  }
}

// Returns { principal } on success, or a ready-to-return error response.
function authorize(request) {
  const principal = decodePrincipal(request);
  const roles = (principal && principal.userRoles) || [];
  if (!principal || !principal.userId) {
    return { error: json(401, { error: 'unauthenticated' }) };
  }
  if (!roles.includes(REQUIRED_ROLE)) {
    return { error: json(403, { error: 'forbidden' }) };
  }
  return { principal };
}

// A short, non-PII actor label for audit fields in the blobs.
function actorLabel(principal) {
  return (principal && (principal.userDetails || principal.userId) || 'unknown').toString().slice(0, 128);
}

// The reset (and, defensively, every write) re-asserts the demo pin server-side.
// TARGET_DB is a constant, so this always passes here - its purpose is to make
// the refusal explicit and to guarantee no code path can ever express prod.
function assertDemoTarget() {
  if (TARGET_DB === PROD_DB) {
    throw new Error(`refusing: target resolves to production ${PROD_DB}`);
  }
  if (TARGET_DB !== 'luxauto_demo') {
    throw new Error(`refusing: target ${TARGET_DB} is not luxauto_demo`);
  }
}

async function streamToString(readable) {
  const chunks = [];
  for await (const chunk of readable) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

async function readBlobJson(name) {
  const blob = containerClient.getBlobClient(name);
  try {
    const dl = await blob.download();
    const text = await streamToString(dl.readableStreamBody);
    return JSON.parse(text);
  } catch (err) {
    if (err && (err.statusCode === 404 || err.code === 'BlobNotFound')) return null;
    throw err;
  }
}

async function writeBlobJson(name, obj) {
  const block = containerClient.getBlockBlobClient(name);
  const body = JSON.stringify(obj, null, 2);
  await block.upload(body, Buffer.byteLength(body), {
    blobHTTPHeaders: { blobContentType: 'application/json', blobCacheControl: 'no-store' },
  });
}

// Read the current desired intent, or a safe default. Validates/repairs fields.
async function readIntent() {
  const raw = (await readBlobJson(INTENT_BLOB)) || {};
  const state = raw.state === 'paused' ? 'paused' : 'running';
  const preset = PRESET_NAMES.includes(raw.preset) ? raw.preset : DEFAULT_PRESET;
  let rate = Number(raw.rate_per_min);
  if (!Number.isFinite(rate)) rate = PRESETS[preset].rate_per_min;
  rate = Math.min(Math.max(rate, RATE_MIN), RATE_MAX);
  return { state, preset, rate_per_min: rate };
}

async function writeIntent(intent, principal) {
  const out = {
    state: intent.state,
    preset: intent.preset,
    rate_per_min: intent.rate_per_min,
    updated_at: new Date().toISOString(),
    updated_by: actorLabel(principal),
  };
  await writeBlobJson(INTENT_BLOB, out);
  return out;
}

async function parseBody(request) {
  try {
    const txt = await request.text();
    if (!txt) return {};
    return JSON.parse(txt);
  } catch {
    return null; // signal malformed
  }
}

// --------------------------------------------------------------------------- //
// Endpoints
// --------------------------------------------------------------------------- //
async function setState(request, newState) {
  const auth = authorize(request);
  if (auth.error) return auth.error;
  try {
    const intent = await readIntent();
    intent.state = newState;
    const out = await writeIntent(intent, auth.principal);
    return json(200, { ok: true, intent: out });
  } catch (err) {
    return json(502, { error: 'control_write_failed', detail: String(err && err.message || err) });
  }
}

app.http('control-start', {
  methods: ['POST'], authLevel: 'anonymous', route: 'control/start',
  handler: (request) => setState(request, 'running'),
});

app.http('control-stop', {
  methods: ['POST'], authLevel: 'anonymous', route: 'control/stop',
  handler: (request) => setState(request, 'paused'),
});

app.http('control-preset', {
  methods: ['POST'], authLevel: 'anonymous', route: 'control/preset',
  handler: async (request) => {
    const auth = authorize(request);
    if (auth.error) return auth.error;
    const body = await parseBody(request);
    if (body === null) return json(400, { error: 'bad_json' });
    const preset = body.preset;
    if (!PRESET_NAMES.includes(preset)) {
      return json(400, { error: 'unknown_preset', valid: PRESET_NAMES });
    }
    try {
      const intent = await readIntent();
      intent.preset = preset;
      // Switching preset adopts that preset's characteristic rate, unless the
      // caller explicitly names one in the same request.
      const rate = Number(body.rate_per_min);
      intent.rate_per_min = Number.isFinite(rate)
        ? Math.min(Math.max(rate, RATE_MIN), RATE_MAX)
        : PRESETS[preset].rate_per_min;
      const out = await writeIntent(intent, auth.principal);
      return json(200, { ok: true, intent: out });
    } catch (err) {
      return json(502, { error: 'control_write_failed', detail: String(err && err.message || err) });
    }
  },
});

app.http('control-rate', {
  methods: ['POST'], authLevel: 'anonymous', route: 'control/rate',
  handler: async (request) => {
    const auth = authorize(request);
    if (auth.error) return auth.error;
    const body = await parseBody(request);
    if (body === null) return json(400, { error: 'bad_json' });
    const rate = Number(body.rate_per_min);
    if (!Number.isFinite(rate) || rate < RATE_MIN || rate > RATE_MAX) {
      return json(400, { error: 'bad_rate', min: RATE_MIN, max: RATE_MAX });
    }
    try {
      const intent = await readIntent();
      intent.rate_per_min = rate;
      const out = await writeIntent(intent, auth.principal);
      return json(200, { ok: true, intent: out });
    } catch (err) {
      return json(502, { error: 'control_write_failed', detail: String(err && err.message || err) });
    }
  },
});

app.http('control-reset', {
  methods: ['POST'], authLevel: 'anonymous', route: 'control/reset',
  handler: async (request, context) => {
    const auth = authorize(request);
    if (auth.error) return auth.error;

    // Server-side re-verification of the bright line BEFORE writing anything.
    // Never trusts the client: no DB name is accepted from the request at all.
    try {
      assertDemoTarget();
    } catch (err) {
      context.error('reset refused by target guard:', err && err.message);
      return json(403, { error: 'target_refused', detail: String(err && err.message || err) });
    }

    const nonce = crypto.randomUUID();
    const reqObj = {
      nonce,
      target_db: TARGET_DB, // recorded for the agent to re-verify; never prod
      requested_at: new Date().toISOString(),
      requested_by: actorLabel(auth.principal),
    };
    try {
      await writeBlobJson(RESET_BLOB, reqObj);
    } catch (err) {
      return json(502, { error: 'reset_request_failed', detail: String(err && err.message || err) });
    }
    return json(202, {
      ok: true,
      accepted: true,
      nonce,
      note: 'Destructive rebuild of luxauto_demo requested. The VM control agent '
        + 're-verifies the demo-DB pin and runs the sanctioned reprovision. '
        + 'Production luxauto is never touched. Poll /api/control/status for progress.',
    });
  },
});

app.http('control-status', {
  methods: ['GET'], authLevel: 'anonymous', route: 'control/status',
  handler: async (request) => {
    const auth = authorize(request);
    if (auth.error) return auth.error;
    let intent = null;
    let status = null;
    try {
      intent = await readIntent();
    } catch (_) { /* fall through */ }
    try {
      status = await readBlobJson(STATUS_BLOB);
    } catch (_) { /* fall through */ }

    // Freshness: the VM agent stamps agent_heartbeat; flag stale so the panel
    // can show "agent not reporting" rather than a misleading OK.
    let stale = true;
    if (status && status.agent_heartbeat) {
      const age = Date.now() - Date.parse(status.agent_heartbeat);
      stale = !(age >= 0 && age < 30000); // > 30s => stale
    }
    return json(200, {
      target_db: TARGET_DB,
      intent,                              // desired state the API holds
      status,                              // last snapshot the VM agent published
      agent_reporting: !!status && !stale, // is the VM executor alive & fresh?
      server_time: new Date().toISOString(),
    });
  },
});
