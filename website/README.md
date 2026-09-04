# torque-website (website.ironcliffvertex.com)

Cloudflare Worker with static assets (not Pages). Deploy from this directory:

```
npx wrangler deploy
```

## Provenance

The original deploy directory (Dash's Windows machine) was unavailable, so this
tree was **reconstructed on 2026-09-04** from the two surviving sources:

- **Static assets** (`public/`): crawled to reference-closure from the live site
  at `https://website.ironcliffvertex.com`. 402 files: `index.html`,
  `assets/crest.svg`, and 400 scroll-animation frames
  (`frames/{desktop,mobile}/frame-0001..0200.webp`; range bounded by 404 probes
  at 0000 and 0201). Ten-file spot check verified byte-identical to live.
- **Worker script**: the Workers scripts API returned 204 No Content and service
  metadata showed `has_assets: true, has_modules: false`, zero bindings — the
  live deployment was **assets-only with no user script**. There was no script
  to recover; `wrangler.jsonc` reflects that baseline.

Notes:
- `/robots.txt` on the live site is Cloudflare zone-managed content
  ("Content Signals"), injected at the edge — deliberately not committed here.
- `approval-console.html` is mentioned in an index.html comment but returns 404
  live; it was never deployed.
- `/favicon.ico` and `/404.html` return 404 live; none committed.

This directory is the single deploy source for the site from this commit on.
