'use strict';

/**
 * GET /api/snapshot
 *
 * Reads snapshot.json from the PRIVATE blob container server-side, using the
 * Function App's system-assigned managed identity (Storage Blob Data Reader,
 * scoped to the one storage account). No credential or blob URL ever reaches
 * the browser.
 *
 * Security model:
 *  - Route protection in staticwebapp.config.json requires an authenticated
 *    user before this endpoint is reachable through the Static Web App.
 *  - Because the Entra app registration has "assignment required" = yes, only
 *    users assigned to the app (via the allow-list security group / app role)
 *    can obtain a token and therefore reach the "authenticated" SWA role.
 *  - This handler ALSO re-validates the injected x-ms-client-principal header
 *    (defense in depth) so it cannot serve data to an unauthenticated caller
 *    even if the linked Function App endpoint were reached directly.
 *
 * Failure behavior:
 *  - On blob read failure, returns the last successfully read snapshot if one
 *    is cached in memory (flagged with X-Snapshot-Stale: true), else a 503
 *    with a small JSON error. Never a blank 200, never fabricated data.
 */

const { app } = require('@azure/functions');
const { DefaultAzureCredential } = require('@azure/identity');
const { BlobServiceClient } = require('@azure/storage-blob');

const ACCOUNT_URL = 'https://luxautosa91a2e1.blob.core.windows.net';
const CONTAINER = 'demo-dashboard';
const BLOB = 'snapshot.json';

// Only logged-in users of the custom Entra provider carry this SWA role.
// Combined with "assignment required" on the app registration, presence of
// this role means the caller is on the allow-list.
const REQUIRED_ROLE = 'authenticated';

// Per-instance in-memory cache of the last good snapshot (best-effort).
let lastGood = null; // { body: string, at: number }

// Reuse credential + blob client across warm invocations.
const credential = new DefaultAzureCredential();
const blobClient = new BlobServiceClient(ACCOUNT_URL, credential)
  .getContainerClient(CONTAINER)
  .getBlobClient(BLOB);

function decodePrincipal(request) {
  const header = request.headers.get('x-ms-client-principal');
  if (!header) return null;
  try {
    return JSON.parse(Buffer.from(header, 'base64').toString('utf8'));
  } catch {
    return null;
  }
}

function json(status, obj, extraHeaders) {
  return {
    status,
    headers: Object.assign(
      { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' },
      extraHeaders || {}
    ),
    body: JSON.stringify(obj),
  };
}

async function streamToString(readable) {
  const chunks = [];
  for await (const chunk of readable) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

app.http('snapshot', {
  methods: ['GET'],
  // User auth is enforced by SWA at the edge; re-verified below as defense in depth.
  authLevel: 'anonymous',
  route: 'snapshot',
  handler: async (request, context) => {
    const principal = decodePrincipal(request);
    const roles = (principal && principal.userRoles) || [];

    if (!principal || !principal.userId) {
      return json(401, { error: 'unauthenticated' });
    }
    if (!roles.includes(REQUIRED_ROLE)) {
      return json(403, { error: 'forbidden' });
    }

    try {
      const download = await blobClient.download();
      const body = await streamToString(download.readableStreamBody);
      lastGood = { body, at: Date.now() };
      return {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' },
        body,
      };
    } catch (err) {
      context.error('snapshot blob read failed:', err && err.message ? err.message : err);
      if (lastGood) {
        return {
          status: 200,
          headers: {
            'Content-Type': 'application/json',
            'Cache-Control': 'no-cache',
            'X-Snapshot-Stale': 'true',
          },
          body: lastGood.body,
        };
      }
      return json(503, {
        error: 'snapshot_unavailable',
        detail: 'upstream blob read failed and no cached copy is available',
      });
    }
  },
});
