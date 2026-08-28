#!/bin/bash
# Replay Mode engine wrapper (ADR 0043, Build 3 — Slice 1: engine only).
#
# Pure playback over the frozen canonical artifact. Touches NO database — not
# luxauto_demo and never production luxauto — so, unlike the DB-backed admin
# jobs on this box, it sources NO credentials. It only reads the committed
# sample-data/canonical/canonical_dataset.json (sha256-pinned, fail-closed).
#
# Slice 1 is the headless engine + the reconciliation dump. Service packaging
# (a systemd unit) and the exporter/control-panel wiring are Slices 2-3 and are
# deliberately NOT part of this script.
#
# Usage:
#   scripts/replay-engine.sh                       # reconcile + refresh the dump
#   scripts/replay-engine.sh --month 6 --out /tmp/replay_state.json --live-ts
#   scripts/replay-engine.sh --reconcile           # gate only, no dump write

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE="$SCRIPT_DIR/lib/replay_engine.py"
DUMP="$REPO_ROOT/sample-data/canonical/replay_reconciliation.json"

if [[ $# -eq 0 ]]; then
  # Default: run the full 12-month gate and refresh the committed dump.
  exec python3 "$ENGINE" --reconcile --dump-out "$DUMP"
fi

exec python3 "$ENGINE" "$@"
