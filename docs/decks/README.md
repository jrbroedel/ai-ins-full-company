# Torque Underwriters — Investor Deck

Working-draft investor briefing (Kent's scaffold; investors are the ultimate audience).

## Files

- `torque-underwriters-investor-deck.pptx` — the deliverable. **This is the laundered, PowerPoint-safe file** (see build note). This is the one to open/share.
- `build_deck.js` — the generator (pptxgenjs). Produces the raw deck; **its raw output does not open in PowerPoint** — it must be round-tripped (below).
- `README.md` — this file.

## Build (two steps — both required)

```bash
# 1. generate the raw deck with pptxgenjs
node build_deck.js                     # -> torque-underwriters-investor-deck.pptx (raw)

# 2. MANDATORY: launder through LibreOffice into PowerPoint-compatible OOXML
soffice --headless \
  --convert-to pptx:"Impress MS PowerPoint 2007 XML" \
  --outdir out torque-underwriters-investor-deck.pptx
# -> out/torque-underwriters-investor-deck.pptx  == the committed artifact
```

Requires Node (with `pptxgenjs` available) and LibreOffice (`soffice`/`libreoffice`).

## Why step 2 is not optional

The pptxgenjs build in our tooling emits `.pptx` that **real PowerPoint refuses to open**, in two ways:

1. a phantom `slideMaster{N}` `[Content_Types].xml` override for every slide while only one master file exists → *"PowerPoint can't read the file."*
2. schema-invalid slide/chart DrawingML → *"PowerPoint found a problem with content"* (after repair, most slides are stripped).

**Every local check gives a false green** — LibreOffice renders it, python-pptx opens it, and the pptx skill's `validate.py` passes it — because none of them enforce PowerPoint's strict parser. The LibreOffice round-trip re-serializes the whole package with a PowerPoint-compatible writer and fixes **both** issues at once, preserving the visual design.

**Sanity check after step 2:** in the laundered `.pptx`, the number of `ppt/slideMasters/slideMaster*.xml` files must equal the number of `slideMasters/slideMaster*.xml` overrides in `[Content_Types].xml` (should be `1 == 1`). If they don't match, the round-trip didn't take.

Do **not** commit or deliver the raw pptxgenjs output — only the laundered file.
