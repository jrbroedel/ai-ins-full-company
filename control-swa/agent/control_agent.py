"""
VM control agent for the investor-demo operator control panel (demo only).

WHAT THIS IS
------------
The single privileged executor that bridges the Entra-gated cloud control API to
the VM. The cloud API holds no database credential and cannot reach the VM; it
only writes small INTENT blobs. This agent, running on the VM under the same
managed identity / Key Vault path every admin job here uses, is the only thing
that:

  1. reflects the desired control INTENT into the LOCAL control file the
     synthetic generator reads each cycle
     (/home/azureuser/demo-control/generator-control.json), and
  2. executes the one destructive action - a full reprovision of luxauto_demo -
     by invoking the EXISTING sanctioned, fenced path
     (scripts/synthetic-generator.sh --reprovision --yes). It authors no
     destruction of its own, disables no audit trigger, uses no
     session_replication_role.

It also publishes a STATUS blob (desired state + a quick luxauto_demo row count +
generator liveness) that the cloud API's GET /status returns.

BRIGHT LINE (re-verified here, VM-side, immediately before acting)
------------------------------------------------------------------
Everything is pinned to luxauto_demo. The agent refuses to run unless
PGDATABASE == 'luxauto_demo' and refuses outright if it is (or resolves to)
production 'luxauto' - reusing the generator's own guard_target(). Before a
reset it re-checks the demo pin AND the reset request's recorded target, and the
reprovision path it calls re-guards again (env, live current_database(), and a
same-statement guard on the DROP). Belt, braces, and a second belt.

SAFETY: reset never fires by surprise
-------------------------------------
Reset is keyed on a one-shot NONCE. On first start the agent adopts whatever
nonce is currently in the reset blob as a baseline WITHOUT acting, so restarting
the agent can never re-run a stale reset. Only a NEW nonce (a fresh operator
click, after the agent is running) triggers a rebuild.

CREDENTIALS / IDENTITY
----------------------
  - Blobs: DefaultAzureCredential -> the VM's system-assigned managed identity
    via IMDS (needs Storage Blob Data Contributor on the demo-control container).
  - Postgres: the wrapper (control-agent.sh) sources fetch-pg-credentials.sh and
    pins PGDATABASE=luxauto_demo, exactly like the generator.

Env overrides (all optional):
  AGENT_INTERVAL_SECONDS   poll cadence (default 3.0)
  CONTROL_CONTAINER        blob container name (default 'demo-control')
  CONTROL_ACCOUNT_URL      blob account url (default the demo storage account)
  GEN_CONTROL_FILE         local control file path (inherited by the generator)
"""
import json
import logging
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

# Reuse the generator as the single source of truth for the guard, the connect
# path, the row-count query, the control-file path, and the preset/validation
# constants. Importing it runs no DB connection (that happens only in run_loop).
_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(_HERE))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts", "lib"))
import synthetic_generator as sg  # noqa: E402

from azure.identity import DefaultAzureCredential  # noqa: E402
from azure.storage.blob import BlobServiceClient  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s control-agent: %(message)s",
)
log = logging.getLogger("control-agent")

AGENT_INTERVAL = float(os.environ.get("AGENT_INTERVAL_SECONDS", "3.0"))
CONTAINER = os.environ.get("CONTROL_CONTAINER", "demo-control")
ACCOUNT_URL = os.environ.get(
    "CONTROL_ACCOUNT_URL", "https://luxautosa91a2e1.blob.core.windows.net"
)
INTENT_BLOB = "control-intent.json"
RESET_BLOB = "reset-request.json"
STATUS_BLOB = "status.json"

CONTROL_FILE = sg.CONTROL_FILE
NONCE_STATE_FILE = os.path.join(os.path.dirname(CONTROL_FILE), ".last-reset-nonce")
GENERATOR_UNIT = "luxauto-synthetic-generator.service"
REPROVISION_CMD = [
    os.path.join(_REPO_ROOT, "scripts", "synthetic-generator.sh"),
    "--reprovision", "--yes",
]

_STOP = False


def _handle_stop(signum, _frame):
    global _STOP
    _STOP = True
    log.info("received signal %s - will exit after this tick", signum)


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


# --------------------------------------------------------------------------- #
# Blob helpers (managed identity)
# --------------------------------------------------------------------------- #
def _container():
    cred = DefaultAzureCredential()
    return BlobServiceClient(ACCOUNT_URL, cred).get_container_client(CONTAINER)


def read_blob_json(container, name):
    try:
        data = container.get_blob_client(name).download_blob().readall()
    except Exception as exc:
        # Missing blob is normal (nothing set yet); log others at debug.
        if "BlobNotFound" in str(exc) or "404" in str(exc):
            return None
        log.debug("read %s failed: %s", name, exc)
        return None
    try:
        return json.loads(data)
    except Exception as exc:
        log.warning("blob %s is not valid JSON: %s", name, exc)
        return None


def write_blob_json(container, name, obj):
    body = json.dumps(obj, indent=2).encode("utf-8")
    container.get_blob_client(name).upload_blob(body, overwrite=True)


# --------------------------------------------------------------------------- #
# Intent -> local control file
# --------------------------------------------------------------------------- #
def validate_intent(raw):
    """Coerce a raw intent blob into a valid, clamped control dict, or None."""
    if not isinstance(raw, dict):
        return None
    state = raw.get("state")
    if state not in sg.VALID_STATES:
        state = "running"
    preset = raw.get("preset")
    if preset not in sg.PRESETS:
        preset = sg.DEFAULT_PRESET
    try:
        rate = float(raw.get("rate_per_min", sg.PRESETS[preset]["rate_per_min"]))
    except (TypeError, ValueError):
        rate = sg.PRESETS[preset]["rate_per_min"]
    rate = min(max(rate, sg.RATE_MIN_PER_MIN), sg.RATE_MAX_PER_MIN)
    return {"state": state, "preset": preset, "rate_per_min": rate}


def current_control_file():
    try:
        with open(CONTROL_FILE) as f:
            return json.load(f)
    except Exception:
        return None


def write_control_file(ctrl):
    """Atomically write the local control file the generator reads."""
    os.makedirs(os.path.dirname(CONTROL_FILE), exist_ok=True)
    tmp = CONTROL_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(ctrl, f, indent=2)
    os.replace(tmp, CONTROL_FILE)


def reflect_intent(container):
    """Read the intent blob; if valid and different, write the local file."""
    raw = read_blob_json(container, INTENT_BLOB)
    if raw is None:
        return  # nothing set yet - never clobber the local file with a default
    ctrl = validate_intent(raw)
    if ctrl is None:
        return
    cur = current_control_file()
    if cur != ctrl:
        write_control_file(ctrl)
        log.info("applied intent -> local control file: %s", ctrl)


# --------------------------------------------------------------------------- #
# Reset (destructive) - nonce-gated, re-fenced, calls the sanctioned path only
# --------------------------------------------------------------------------- #
def _read_last_nonce():
    try:
        with open(NONCE_STATE_FILE) as f:
            return f.read().strip() or None
    except FileNotFoundError:
        return None


def _write_last_nonce(nonce):
    os.makedirs(os.path.dirname(NONCE_STATE_FILE), exist_ok=True)
    tmp = NONCE_STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(nonce or "")
    os.replace(tmp, NONCE_STATE_FILE)


def _guard_reset_target(reqobj):
    """VM-side re-verification of the bright line immediately before a reset.
    Refuses if the environment pin is not luxauto_demo, or if the request names
    anything other than luxauto_demo. Raises on refusal."""
    envdb = os.environ.get("PGDATABASE")
    if envdb == sg.PROD_DB:
        raise RuntimeError(f"REFUSING RESET: PGDATABASE is {envdb!r} (production)")
    if envdb != sg.EXPECTED_DB:
        raise RuntimeError(f"REFUSING RESET: PGDATABASE is {envdb!r}, expected {sg.EXPECTED_DB!r}")
    target = (reqobj or {}).get("target_db", sg.EXPECTED_DB)
    if target == sg.PROD_DB:
        raise RuntimeError(f"REFUSING RESET: request target_db is {target!r} (production)")
    if target != sg.EXPECTED_DB:
        raise RuntimeError(f"REFUSING RESET: request target_db is {target!r}, expected {sg.EXPECTED_DB!r}")


# Module-level record of the most recent reset outcome, surfaced in status.
_last_reset = {"nonce": None, "status": "none", "at": None, "detail_tail": None}


def maybe_run_reset(container):
    """If a NEW reset nonce is present, re-fence and run the sanctioned
    reprovision. Baseline-adopts any pre-existing nonce on first start so a
    restart never re-runs a stale reset."""
    global _last_reset
    req = read_blob_json(container, RESET_BLOB)
    if not req or "nonce" not in req:
        return
    nonce = str(req["nonce"])
    last = _read_last_nonce()

    if last is None:
        # First observation ever: adopt as baseline, do NOT act.
        _write_last_nonce(nonce)
        log.info("adopted existing reset nonce as baseline (no action): %s", nonce)
        return
    if nonce == last:
        return  # already processed

    log.warning("NEW reset nonce %s (requested_by=%s) - re-verifying fences",
                nonce, req.get("requested_by"))
    try:
        _guard_reset_target(req)
    except Exception as exc:
        log.error("reset refused: %s", exc)
        _last_reset = {"nonce": nonce, "status": "refused", "at": _now_iso(),
                       "detail_tail": str(exc)}
        _write_last_nonce(nonce)  # do not retry a refused request
        return

    _last_reset = {"nonce": nonce, "status": "running", "at": _now_iso(), "detail_tail": None}
    # Publish "running" promptly so the panel shows progress.
    try:
        publish_status(container, reset_in_progress=True)
    except Exception:
        pass

    log.warning("running sanctioned reprovision: %s", " ".join(REPROVISION_CMD))
    proc = subprocess.run(REPROVISION_CMD, cwd=_REPO_ROOT, env=os.environ.copy(),
                          capture_output=True, text=True)
    tail = "\n".join(((proc.stdout or "") + (proc.stderr or "")).strip().splitlines()[-8:])
    if proc.returncode == 0:
        log.info("reprovision OK (nonce %s)", nonce)
        _last_reset = {"nonce": nonce, "status": "ok", "at": _now_iso(), "detail_tail": tail}
    else:
        log.error("reprovision FAILED rc=%s (nonce %s)", proc.returncode, nonce)
        _last_reset = {"nonce": nonce, "status": "failed", "at": _now_iso(),
                       "detail_tail": tail}
    _write_last_nonce(nonce)  # processed either way; never loop on one request


# --------------------------------------------------------------------------- #
# Status publication
# --------------------------------------------------------------------------- #
def generator_liveness():
    # Prefer systemd if the unit is installed; fall back to a process check.
    try:
        r = subprocess.run(["systemctl", "is-active", GENERATOR_UNIT],
                           capture_output=True, text=True)
        state = (r.stdout or "").strip()
        if state in ("active", "activating"):
            return {"alive": True, "method": f"systemd:{state}"}
        if state in ("inactive", "failed", "deactivating"):
            return {"alive": False, "method": f"systemd:{state}"}
    except Exception:
        pass
    try:
        r = subprocess.run(["pgrep", "-f", "synthetic_generator.py"],
                           capture_output=True, text=True)
        return {"alive": bool(r.stdout.strip()), "method": "pgrep"}
    except Exception:
        return {"alive": None, "method": "unknown"}


def demo_counts():
    """A quick luxauto_demo row count via the guarded connect path. Returns the
    counts dict, or an {'error': ...} marker. Touches NO commission/quote
    economics - only table row counts."""
    try:
        conn = sg.connect()  # guards env + live current_database()
        try:
            with conn.cursor() as cur:
                return sg._counts(cur)
        finally:
            conn.close()
    except SystemExit as exc:  # guard refusal
        return {"error": f"guard: {exc}"}
    except Exception as exc:
        return {"error": str(exc)}


def publish_status(container, reset_in_progress=False):
    ctrl = current_control_file() or {}
    status = {
        "target_db": sg.EXPECTED_DB,
        "state": ctrl.get("state"),
        "preset": ctrl.get("preset"),
        "rate_per_min": ctrl.get("rate_per_min"),
        "demo_row_count": demo_counts(),
        "generator": generator_liveness(),
        "last_reset": dict(_last_reset, in_progress=bool(reset_in_progress)),
        "agent_heartbeat": _now_iso(),
        "agent_version": "1",
    }
    write_blob_json(container, STATUS_BLOB, status)
    return status


# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #
def main():
    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    # Fail fast if the environment is not pinned to the demo DB (guard reused
    # from the generator; checks env only here, live DB is checked per connect).
    sg.guard_target()

    container = _container()
    log.info("control agent up: container=%s account=%s control_file=%s interval=%.1fs",
             CONTAINER, ACCOUNT_URL, CONTROL_FILE, AGENT_INTERVAL)

    while not _STOP:
        try:
            reflect_intent(container)
            maybe_run_reset(container)
            publish_status(container)
        except Exception as exc:
            log.error("tick error (continuing): %s", exc)
        # Responsive sleep.
        slept = 0.0
        while slept < AGENT_INTERVAL and not _STOP:
            time.sleep(min(0.5, AGENT_INTERVAL - slept))
            slept += 0.5

    log.info("control agent exiting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
