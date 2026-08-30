"""
Read-only snapshot exporter for the investor dashboard (demo only).

WHAT THIS IS
------------
A long-lived loop that, every few seconds, reads luxauto_demo, assembles a
single JSON document describing the demo funnel, and overwrites one blob
(demo-dashboard/snapshot.json) in the luxautosa91a2e1 storage account. A
separate static dashboard polls that blob. This process is the ONLY writer of
that blob; the dashboard is a pure reader.

WHAT THIS IS NOT
----------------
It is not a source of business logic and it invents nothing. Every number in
the JSON comes from a real query against the current seed. "Motion" and variety
on the dashboard are the generator's job (a separate component that mutates the
database); when the seed is static this snapshot is static too, and that is the
honest behaviour - an empty tile stays 0/null rather than being filled in here.

READ-ONLY CONTRACT
------------------
This component must never INSERT, UPDATE, DELETE, or run DDL against the
database. Two independent guards enforce that:
  1. It only ever issues SELECTs (see the QUERIES below - there is no other SQL).
  2. The psycopg2 session is opened read-only (set_session(readonly=True)), so
     even a mistaken write would be rejected by Postgres itself.
It connects to luxauto_demo, set EXPLICITLY by the wrapper - never to the
production luxauto database.

COMMISSION EXCLUSION (deliberate)
---------------------------------
Commission economics are kept off the investor dashboard. This file never reads
luxauto_premium_waterfall_view / luxauto_quote_commission_view /
luxauto_settlement_view and never emits any commission_rate, mga/broker rate,
net_premium_to_panel, gross_share, or commission_amount field. A grep test over
the emitted JSON is part of the acceptance check.

CREDENTIALS (reused VM pattern, nothing hardcoded)
--------------------------------------------------
  - Postgres: the wrapper (scripts/export-dashboard-snapshot.sh) sources
    scripts/lib/fetch-pg-credentials.sh - the same managed-identity -> IMDS ->
    Key Vault path every other admin job on this box uses - and exports
    PGHOST/PGUSER/PGPASSWORD/PGSSLMODE plus PGDATABASE=luxauto_demo. psycopg2
    reads those from the environment; no secret is passed on the command line.
  - Blob: the VM's managed identity has no Blob data-plane RBAC on this account
    (verified: AuthorizationPermissionMismatch), so - exactly mirroring the
    Postgres pattern - we fetch storage-account-name and storage-account-key
    from the SAME Key Vault via the SAME IMDS->Vault REST call fetch-pg-
    credentials.sh uses, and authenticate BlobServiceClient with the account
    key. No key is stored in the repo or passed as an argument.

SUPERVISION (systemd) - described, not installed
------------------------------------------------
In production this would run under a systemd unit shaped like the existing
luxauto-* timers, but as a long-lived Service (Restart=always) rather than a
Timer, since it is a continuous loop rather than a periodic one-shot. A sketch
lives at infra/systemd/luxauto-dashboard-exporter.service; it is intentionally
NOT enabled. Make it work by hand first (this file is directly runnable), then
decide on supervision. Running as the azureuser identity is what gives it the
managed-identity token for Key Vault, the same as the other admin jobs.

Env overrides (all optional; defaults match the demo):
  SNAPSHOT_INTERVAL_SECONDS   override the write cadence (default 4)
  DEMO_DASHBOARD_CONTAINER    override the blob container (default demo-dashboard)
  SNAPSHOT_BLOB_KEY           override the object key (default snapshot.json)
  LUXAUTO_KEY_VAULT           override the vault (default luxauto-kv-90a311)
  SNAPSHOT_ONCE=1             run exactly one cycle and exit (used for testing)
  SNAPSHOT_STDOUT=1           also print the assembled JSON to stdout each cycle
"""
import json
import logging
import os
import signal
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras
from azure.storage.blob import BlobServiceClient, ContentSettings

# --------------------------------------------------------------------------- #
# Configuration - named constants, not magic numbers scattered through the code.
# --------------------------------------------------------------------------- #
SNAPSHOT_INTERVAL_SECONDS = float(os.environ.get("SNAPSHOT_INTERVAL_SECONDS", "4"))
DEMO_DASHBOARD_CONTAINER = os.environ.get("DEMO_DASHBOARD_CONTAINER", "demo-dashboard")
SNAPSHOT_BLOB_KEY = os.environ.get("SNAPSHOT_BLOB_KEY", "snapshot.json")
KEY_VAULT = os.environ.get("LUXAUTO_KEY_VAULT", "luxauto-kv-90a311")
EXPECTED_DB = "luxauto_demo"

# The seven referral_action_t values, in severity order. The disposition legend
# on the dashboard must be stable, so every key is emitted every cycle even when
# its count is 0. This list is the single source of truth for that.
REFERRAL_ACTIONS = [
    "AUTO_PROCEED",
    "AUTO_PROCEED_WITH_FLAG",
    "INFORMATION_REQUEST",
    "MANUAL_REVIEW_REQUIRED",
    "MANUAL_REVIEW_SENIOR",
    "DECLINE_RECOMMENDED",
    "HARD_DECLINE_COMPLIANCE",
]

# Time-saving tile: a MODELED comparison (NOT a measured runtime). Both constants are
# named + parameterized here so retuning the appetite knobs is a one-line edit.
#   - HUMAN: Kent's figure for a human underwriter to work one car end-to-end.
#   - AI: a conservative, defensible modeled end-to-end automated pass (intake +
#     enrichment latency + referral eval + rating + quote). NOT a measured latency.
# Applied to ALL submissions (a human reviews every car that comes in, not just binds),
# so both sides are apples-to-apples. The denominator is read from the live
# applications_total, never hard-coded, so the saving scales if volume ever changes.
HUMAN_MINUTES_PER_SUBMISSION = 90   # 1.5 hr (human baseline)
AI_MINUTES_PER_SUBMISSION = 2       # modeled automated pass
FTE_HOURS_PER_YEAR = 2080           # for the optional human-scale framing

# ---- Playback (ADR 0047): the exporter is cursor-aware ---------------------- #
# The playback driver advances a single cursor (demo_playback_state.current_position,
# a timestamptz) and NEVER inserts into the book. Every tile reveals only rows whose
# authoritative time key <= cursor: applications.submitted_at (app-grain) or
# lower(effective_range) (policy-grain; == submitted-month for binds, 0 mismatches).
# Claims are revealed WITH their policy (ultimate development), NEVER by date_of_loss
# (which runs into 2027 and would recreate the emerged-basis bug killed in STEP FIVE).
# ADDITIVE/back-compat: if demo_playback_state is absent (or NULL), the cursor is a
# far-future sentinel so `<= cursor` reveals the whole $71M book == today's snapshot.
from datetime import datetime as _dt  # noqa: E402  (module already imports datetime)
FAR_FUTURE = _dt(9999, 12, 31, tzinfo=timezone.utc)
# The loss-ratio tile stays on the ULTIMATE basis over revealed policies, but is
# suppressed ("—") until enough policies are revealed: month 1 alone (506 binds)
# swings LR to ~0.86 (small-n), so the headline would bounce. From ~1,000 revealed
# binds it settles into a tight 0.52-0.63 band and lands 0.5600 at full playback.
LOSS_RATIO_MIN_REVEALED_BINDS = 1000


def _playback_cursor(cur):
    """Resolve the playback cursor. Far-future when there is no playback state, so
    every `<= cursor` filter reveals the whole book (back-compat / full snapshot)."""
    if not q1(cur, "SELECT to_regclass('public.demo_playback_state') IS NOT NULL AS ok")["ok"]:
        return FAR_FUTURE
    row = q1(cur, "SELECT current_position FROM demo_playback_state LIMIT 1")
    if not row or row["current_position"] is None:
        return FAR_FUTURE
    return row["current_position"]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s dashboard-exporter: %(message)s",
)
log = logging.getLogger("dashboard-exporter")


# --------------------------------------------------------------------------- #
# Key Vault access - the same IMDS -> Vault REST round-trip fetch-pg-
# credentials.sh performs, reimplemented in Python with the stdlib so this job
# needs neither the az CLI (absent on this box) nor the azure-keyvault SDK
# (not installed). No secret value is ever logged.
# --------------------------------------------------------------------------- #
def _imds_token(resource: str) -> str:
    url = (
        "http://169.254.169.254/metadata/identity/oauth2/token"
        "?api-version=2019-08-01&resource=" + urllib.parse.quote(resource, safe="")
    )
    req = urllib.request.Request(url, headers={"Metadata": "true"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)["access_token"]


def fetch_secret(name: str) -> str:
    """Read one Key Vault secret via managed identity. Mirrors fetch_secret in
    scripts/lib/fetch-pg-credentials.sh."""
    token = _imds_token("https://vault.azure.net")
    url = f"https://{KEY_VAULT}.vault.azure.net/secrets/{name}?api-version=7.4"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)["value"]


# --------------------------------------------------------------------------- #
# Database - a single read-only connection, reused across cycles. Reconnected on
# demand if a cycle finds it dead, so a transient DB blip does not kill the loop.
# --------------------------------------------------------------------------- #
def connect_db():
    dbname = os.environ.get("PGDATABASE")
    if dbname != EXPECTED_DB:
        # A guard, not politeness: connecting to production luxauto instead of
        # luxauto_demo is the one mistake this job must structurally refuse.
        raise RuntimeError(
            f"refusing to run: PGDATABASE is {dbname!r}, expected {EXPECTED_DB!r}. "
            f"Set PGDATABASE={EXPECTED_DB} explicitly (the wrapper does this)."
        )
    # psycopg2 reads PGHOST/PGUSER/PGPASSWORD/PGSSLMODE/PGDATABASE from the
    # environment when connect() is given no dsn.
    conn = psycopg2.connect()
    # Defence in depth: even if a query below were ever changed to attempt a
    # write, the server rejects it because the whole session is read-only.
    conn.set_session(readonly=True, autocommit=True)
    return conn


def q1(cur, sql, params=None):
    """Run a query expected to return exactly one row; return that row."""
    cur.execute(sql, params or ())
    return cur.fetchone()


# --------------------------------------------------------------------------- #
# Snapshot assembly - every value comes from a query here; nothing is invented.
# Returns a plain dict ready for json.dumps.
# --------------------------------------------------------------------------- #
def build_snapshot(conn) -> dict:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        # Playback cursor (ADR 0047). Every tile below reveals only rows with its
        # authoritative time key <= P["cur"]. Far-future when no playback -> full book.
        P = {"cur": _playback_cursor(cur)}

        # ---- tiles -------------------------------------------------------- #
        # Revealed applications (app-grain, applications.submitted_at). NULL
        # submitted_at (unsubmitted drafts) is naturally excluded by `<=`.
        apps_total = q1(
            cur,
            "SELECT count(*) AS n FROM applications WHERE submitted_at <= %(cur)s",
            P,
        )["n"]

        in_uw = q1(
            cur,
            "SELECT count(*) AS n FROM luxauto_underwriter_review_view v "
            "WHERE override_status = 'pending' AND EXISTS ("
            "  SELECT 1 FROM applications a WHERE a.application_id = v.application_id "
            "    AND a.submitted_at <= %(cur)s)",
            P,
        )["n"]

        # quotes are bound-only in this load; revealed via their application's submitted_at.
        quotes_issued = q1(
            cur,
            "SELECT count(*) AS n FROM quotes q WHERE q.status IN ('issued','bound') AND EXISTS ("
            "  SELECT 1 FROM applications a WHERE a.application_id = q.application_id "
            "    AND a.submitted_at <= %(cur)s)",
            P,
        )["n"]

        # 'bound' policies. NOTE (STEP 0): policy_status_t has no 'bound' member
        # (its values are active/cancelled/expired/nonrenewed); in this model a
        # policies row exists only once a policy is bound, so the presence of a
        # luxauto_policy_view row IS the bind. Count those revealed by effective month.
        bound = q1(
            cur,
            "SELECT count(*) AS n FROM luxauto_policy_view WHERE lower(effective_range) <= %(cur)s",
            P,
        )["n"]

        # Frozen disposition counts (ADR 0046): the SINGLE source for BOTH the
        # headline disposition_mix and bind_ratio, so the two can never disagree.
        # (Guarded: if the frozen table is absent, fall back honestly to empty.)
        frozen_mix = {"bind": 0, "refer": 0, "decline": 0}
        if q1(cur, "SELECT to_regclass('public.canonical_load_disposition') IS NOT NULL AS ok")["ok"]:
            cur.execute(
                "SELECT cld.artifact_disposition AS d, count(*) AS n "
                "FROM canonical_load_disposition cld "
                "JOIN applications a ON a.application_id = cld.application_id "
                "WHERE a.submitted_at <= %(cur)s "
                "GROUP BY cld.artifact_disposition",
                P,
            )
            for row in cur.fetchall():
                if row["d"] in frozen_mix:
                    frozen_mix[row["d"]] = int(row["n"])
                else:
                    log.warning("frozen disposition not in known set: %r", row["d"])
        frozen_total = sum(frozen_mix.values())
        # bind_ratio = bound / ALL submissions (frozen), NOT bound/quotes_issued -
        # quotes are bound-only in this load so that ratio is ~1.0 (ADR 0046).
        bind_ratio = round(frozen_mix["bind"] / frozen_total, 4) if frozen_total else 0

        # total_insured_value: prefer bound policy vehicles; fall back to the
        # appraised value on submitted applications' vehicles when nothing is
        # bound. The sibling tiv_basis names which basis produced the number.
        if bound > 0:
            tiv_basis = "bound"
            tiv = q1(
                cur,
                "SELECT COALESCE(SUM(pv.current_appraised_value), 0) AS s "
                "FROM luxauto_policy_vehicle_view pv "
                "JOIN luxauto_policy_view p ON p.policy_id = pv.policy_id "
                "WHERE lower(p.effective_range) <= %(cur)s",
                P,
            )["s"]
        else:
            tiv_basis = "submitted"
            tiv = q1(
                cur,
                "SELECT COALESCE(SUM(v.current_appraised_value), 0) AS s "
                "FROM vehicles v "
                "JOIN applications a ON a.application_id = v.application_id "
                "WHERE a.status = 'submitted' AND a.submitted_at <= %(cur)s",
                P,
            )["s"]

        # avg_premium: the softened WRITTEN premium on bound policies (ADR 0046),
        # NOT luxauto_quote_rating_view.indicative_premium (the un-softened re-rate
        # the hybrid load exists to avoid). Null-safe: AVG over no bound policies
        # -> SQL NULL -> Python None -> JSON null, which the dashboard renders as a dash.
        avg_premium = q1(
            cur,
            "SELECT ROUND(AVG(premium_amount), 2) AS a FROM luxauto_policy_view "
            "WHERE lower(effective_range) <= %(cur)s",
            P,
        )["a"]

        # ultimate_loss_ratio (ADR 0044/0046): the AUTHORITATIVE, PC-driving loss
        # ratio = Σ incurred (ALL 453 claims to full development, loss dates run into
        # 2027) / written GWP. This is the deck's 0.5600. It is DELIBERATELY NOT the
        # emerged-to-date basis (losses inside the 12-month window / cumulative GWP
        # ~0.30, = monthly_aggregates.cumulative_loss_ratio) which ADR 0044 marks
        # non-authoritative - so we never date-filter the claims here. Written GWP is
        # premium_amount off the bound book (NOT indicative_premium). Guarded: if the
        # claims table is absent, emit null rather than a fabricated ratio.
        written_gwp = q1(
            cur,
            "SELECT ROUND(SUM(premium_amount), 2) AS s FROM luxauto_policy_view "
            "WHERE lower(effective_range) <= %(cur)s",
            P,
        )["s"]
        incurred_losses = None
        ultimate_loss_ratio = None
        if q1(cur, "SELECT to_regclass('public.canonical_policy_period_claims') IS NOT NULL AS ok")["ok"]:
            # ULTIMATE incurred over the REVEALED policies: claims are revealed WITH
            # their policy (effective month <= cursor), NEVER filtered by date_of_loss.
            incurred_losses = q1(
                cur,
                "SELECT ROUND(SUM(c.incurred), 2) AS s "
                "FROM canonical_policy_period_claims c "
                "JOIN luxauto_policy_view p ON p.policy_id = c.policy_id "
                "WHERE lower(p.effective_range) <= %(cur)s",
                P,
            )["s"]
            # Gate the headline (tightening #1): suppress until enough policies are
            # revealed so month-1 small-n (~0.86) can't bounce the tile. incurred_losses
            # (the $ component) is still emitted for the tooltip.
            if incurred_losses is not None and written_gwp and bound >= LOSS_RATIO_MIN_REVEALED_BINDS:
                ultimate_loss_ratio = round(float(incurred_losses) / float(written_gwp), 4)

        tiles = {
            "applications_total": int(apps_total),
            "in_underwriting": int(in_uw),
            "quotes_issued": int(quotes_issued),
            "bound": int(bound),
            "bind_ratio": _num(bind_ratio),
            "total_insured_value": _num(tiv),
            "tiv_basis": tiv_basis,
            "avg_premium": _num(avg_premium),
            "ultimate_loss_ratio": _num(ultimate_loss_ratio),
            "incurred_losses": _num(incurred_losses),
            "written_gwp": _num(written_gwp),
        }

        # ---- disposition_mix (FROZEN verdict bind/refer/decline, ADR 0046) --- #
        # NOT the engine's referral action (which collapses refer+decline into
        # MANUAL_REVIEW and emits zero declines - ADR 0046 STEP 0). decision_log /
        # the referral view still drive reason codes, recent_activity and
        # pipeline_events below; only this headline mix reads the frozen table
        # (computed once above, shared with bind_ratio so the two cannot disagree).
        mix = dict(frozen_mix)

        # ---- by_state (states with >= 1 application) ---------------------- #
        cur.execute(
            "SELECT garaging_state AS state, count(DISTINCT application_id) AS n "
            "FROM luxauto_insured_view "
            "WHERE garaging_state IS NOT NULL AND submitted_at <= %(cur)s "
            "GROUP BY garaging_state HAVING count(DISTINCT application_id) >= 1 "
            "ORDER BY n DESC, garaging_state",
            P,
        )
        by_state = [
            {"state": r["state"].strip(), "applications": int(r["n"])}
            for r in cur.fetchall()
        ]

        # ---- by_state_bound (BOUND-policy count per garaging state, ADR 0046) --- #
        # The risk-footprint tile colors states by bound-policy count off the frozen
        # bound book (luxauto_policy_view), with FIXED frozen bin edges in the frontend
        # (ADR 0041 STEP THREE addendum). A DISTINCT key from by_state (application
        # counts) - additive, not an overwrite. Counts only; no premium read here.
        cur.execute(
            "SELECT garaging_state AS state, count(*) AS n "
            "FROM luxauto_policy_view "
            "WHERE garaging_state IS NOT NULL AND lower(effective_range) <= %(cur)s "
            "GROUP BY garaging_state ORDER BY n DESC, garaging_state",
            P,
        )
        by_state_bound = [
            {"state": r["state"].strip(), "bound_policy_count": int(r["n"])}
            for r in cur.fetchall()
        ]

        # ---- rate_trend (12-month two-line series, ADR 0046 STEP FOUR) ------- #
        # Line 1 rate_index = the modeled softening (price/risk) from
        # canonical_rate_index (a loaded generation parameter, kept in the DB so the
        # rate line reconciles to the deck's ~-24% rather than being re-derived).
        # Line 2 avg_bound_premium = AVG(premium_amount) off the frozen bound book,
        # grouped by the policy's EFFECTIVE month (lower(effective_range)) - the column
        # that foots to the artifact's monthly_aggregates to the cent. Premium only;
        # no indicative_premium. Guarded: empty if the rate-index table is absent.
        rate_trend = []
        if q1(cur, "SELECT to_regclass('public.canonical_rate_index') IS NOT NULL AS ok")["ok"]:
            cur.execute(
                "SELECT ri.month, ri.month_index, ri.softening_index AS rate_index, "
                "       pv.avg_bound_premium "
                "FROM canonical_rate_index ri "
                "LEFT JOIN ( "
                "  SELECT to_char(lower(effective_range),'YYYY-MM') AS ym, "
                "         ROUND(AVG(premium_amount), 2) AS avg_bound_premium "
                "  FROM luxauto_policy_view WHERE lower(effective_range) <= %(cur)s GROUP BY 1 "
                ") pv ON pv.ym = ri.month "
                "WHERE ri.month <= to_char(%(cur)s::timestamptz, 'YYYY-MM') "
                "ORDER BY ri.month_index",
                P,
            )
            rate_trend = [
                {
                    "month": r["month"],
                    "month_index": int(r["month_index"]),
                    "rate_index": _num(r["rate_index"]),
                    "avg_bound_premium": _num(r["avg_bound_premium"]),
                }
                for r in cur.fetchall()
            ]

        # ---- states (identity + synthetic flag only) ---------------------- #
        # synthetic is derived in SQL from the honest markers; no rating values.
        cur.execute(
            "SELECT state, filing_status::text AS filing_status, "
            "       serff_filing_tracking_number, "
            "       ( serff_filing_tracking_number LIKE 'DEMO-SYNTHETIC-%' "
            "         OR serff_filing_tracking_number = 'TBD-ILLUSTRATIVE' "
            "         OR rate_manual_reference ILIKE '%not a filed manual%' ) AS synthetic "
            "FROM state_rating_table_versions ORDER BY state"
        )
        states = [
            {
                "state": r["state"].strip(),
                "filing_status": r["filing_status"],
                "serff_filing_tracking_number": r["serff_filing_tracking_number"],
                "synthetic": bool(r["synthetic"]),
            }
            for r in cur.fetchall()
        ]

        # ---- recent_activity (<= 12, most recent first) ------------------- #
        # One item per application: its rollup disposition from the referral
        # view, the garaging_state from the insured view, and the reason_code of
        # the fired rule that DROVE that disposition (the decision_log row whose
        # action_taken equals the rollup). has_quote lets AUTO_PROCEED that
        # reached a quote read "Quote issued" without inventing that fact.
        cur.execute(
            """
            SELECT r.evaluated_at                         AS at,
                   r.application_id                       AS application_id,
                   i.garaging_state                       AS garaging_state,
                   r.most_severe_action::text             AS action,
                   dr.reason_code                         AS reason_code,
                   EXISTS (SELECT 1 FROM quotes q
                           WHERE q.application_id = r.application_id
                             AND q.status IN ('issued','bound')) AS has_quote
            FROM luxauto_application_referral_view r
            JOIN luxauto_insured_view i ON i.application_id = r.application_id
            LEFT JOIN LATERAL (
                SELECT d.reason_code
                FROM decision_log d
                WHERE d.application_id = r.application_id
                  AND d.fired
                  AND d.action_taken = r.most_severe_action
                ORDER BY d.created_at DESC
                LIMIT 1
            ) dr ON true
            WHERE EXISTS (SELECT 1 FROM applications a
                          WHERE a.application_id = r.application_id
                            AND a.submitted_at <= %(cur)s)
            ORDER BY r.evaluated_at DESC
            LIMIT 12
            """,
            P,
        )
        recent = []
        for r in cur.fetchall():
            action = r["action"]
            reason = r["reason_code"]
            recent.append(
                {
                    "at": _iso(r["at"]),
                    "application_id": str(r["application_id"]),
                    "garaging_state": (r["garaging_state"] or "").strip() or None,
                    "action": action,
                    "reason_code": reason,
                    "human_label": human_label(action, reason, r["has_quote"]),
                }
            )

        # ---- pipeline_events (per-app REAL stage timeline, <= 40, newest first) --- #
        # A true per-application trace built ONLY from real timestamps: intake
        # (submitted_at), referral + disposition (the referral rollup evaluated_at -
        # the same real event, the disposition being its outcome), and quote
        # (quoted_at, null when the app never reached a quote). vehicle_display comes
        # from the vehicles base table (one row per app in v1), applicant_display
        # from the insured view's synthetic name.
        #
        # DELIBERATELY ABSENT: any enrichment timestamp/event. The VIN/title/
        # household/sanctions integrations do not exist, so there is no honest
        # timestamp to emit; the frontend interpolates enrichment timing between
        # intake and referral for animation only and keeps its "simulated" marker.
        # This block reads NO commission/waterfall/settlement view.
        cur.execute(
            """
            SELECT i.application_id                         AS application_id,
                   i.garaging_state                         AS garaging_state,
                   i.first_name                             AS first_name,
                   i.last_name                              AS last_name,
                   i.submitted_at                           AS submitted_at,
                   r.most_severe_action::text               AS disposition,
                   r.evaluated_at                           AS evaluated_at,
                   q.quoted_at                              AS quoted_at,
                   q.indicative_premium                     AS indicative_premium,
                   v.year                                   AS veh_year,
                   v.make                                   AS veh_make,
                   v.model                                  AS veh_model
            FROM luxauto_insured_view i
            LEFT JOIN luxauto_application_referral_view r
                   ON r.application_id = i.application_id
            LEFT JOIN LATERAL (
                SELECT qr.quoted_at, qr.indicative_premium
                FROM luxauto_quote_rating_view qr
                WHERE qr.application_id = i.application_id
                ORDER BY qr.quoted_at DESC NULLS LAST
                LIMIT 1
            ) q ON true
            LEFT JOIN LATERAL (
                SELECT ve.year, ve.make, ve.model
                FROM vehicles ve
                WHERE ve.application_id = i.application_id
                ORDER BY ve.year DESC NULLS LAST
                LIMIT 1
            ) v ON true
            WHERE i.submitted_at IS NOT NULL AND i.submitted_at <= %(cur)s
            ORDER BY i.submitted_at DESC
            LIMIT 40
            """,
            P,
        )
        pipeline_events = []
        for r in cur.fetchall():
            name = " ".join(
                p for p in [(r["first_name"] or "").strip(), (r["last_name"] or "").strip()] if p
            )
            veh = " ".join(
                str(p) for p in [r["veh_year"], r["veh_make"], r["veh_model"]] if p
            )
            pipeline_events.append(
                {
                    "application_id": str(r["application_id"]),
                    "garaging_state": (r["garaging_state"] or "").strip() or None,
                    "applicant_display": name or None,
                    "vehicle_display": veh or None,
                    "disposition": r["disposition"],
                    "stages": {
                        "intake": {"at": _iso(r["submitted_at"])},
                        "referral": {"at": _iso(r["evaluated_at"])},
                        "disposition": {"at": _iso(r["evaluated_at"])},
                        "quote": {"at": _iso(r["quoted_at"])},  # null if no quote
                        # NO "enrichment" key: that stage has no real timestamp.
                    },
                    "premium": _num(r["indicative_premium"]),
                }
            )

        # ---- time_saving (MODELED comparison, ADR 0046 STEP SIX) ------------- #
        # Underwriting time saved by automation across the whole book. Derived from
        # the LIVE applications_total (never hard-coded) and the two named modeled
        # constants above, so it scales with volume. basis='modeled' is explicit:
        # the AI minutes are a defensible assumption, NOT a measured runtime.
        ts_subs = int(apps_total)
        ts_human_hours = round(ts_subs * HUMAN_MINUTES_PER_SUBMISSION / 60, 1)
        ts_ai_hours = round(ts_subs * AI_MINUTES_PER_SUBMISSION / 60, 1)
        time_saving = {
            "submissions": ts_subs,
            "human_minutes_per_submission": HUMAN_MINUTES_PER_SUBMISSION,
            "ai_minutes_per_submission": AI_MINUTES_PER_SUBMISSION,
            "human_hours": ts_human_hours,
            "ai_hours": ts_ai_hours,
            "hours_saved": round(ts_human_hours - ts_ai_hours, 1),
            "human_fte_years": round(ts_human_hours / FTE_HOURS_PER_YEAR, 1),
            "multiple": round(HUMAN_MINUTES_PER_SUBMISSION / AI_MINUTES_PER_SUBMISSION),
            "basis": "modeled",
        }

        # ---- playback (ADR 0047): the current reveal cursor, additive ------- #
        # active=false (cursor far-future / no playback state) means the snapshot is
        # the full $71M book. When active, cursor is the demo-time position revealed.
        pb_cur = P["cur"]
        playback = {
            "active": pb_cur != FAR_FUTURE,
            "cursor": (_iso(pb_cur) if pb_cur != FAR_FUTURE else None),
        }

    return {
        "generated_at": _iso(datetime.now(timezone.utc)),
        "tiles": tiles,
        "playback": playback,
        "disposition_mix": mix,
        "by_state": by_state,
        "by_state_bound": by_state_bound,
        "rate_trend": rate_trend,
        "time_saving": time_saving,
        "states": states,
        "recent_activity": recent,
        "pipeline_events": pipeline_events,
        "meta": {
            "synthetic": True,
            "enrichment_simulated": True,  # VIN/title/household/sanctions not live
            "source_db": EXPECTED_DB,
        },
    }


def human_label(action: str, reason_code, has_quote: bool) -> str:
    """Plain-language label built ONLY from real fields. When no clean mapping
    exists, the reason_code is used verbatim rather than inventing wording."""
    reason = (reason_code or "").strip()
    if action == "AUTO_PROCEED":
        # Only claim a quote when one actually exists for this application.
        return "Quote issued" if has_quote else "Auto-proceed — cleared, no referral"
    if action == "AUTO_PROCEED_WITH_FLAG":
        return _with_reason("Auto-proceed with flag", reason)
    if action == "INFORMATION_REQUEST":
        return _with_reason("Information requested", reason)
    if action == "MANUAL_REVIEW_REQUIRED":
        return _with_reason("Referred to underwriter", reason)
    if action == "MANUAL_REVIEW_SENIOR":
        return _with_reason("Referred to senior underwriter", reason)
    if action == "DECLINE_RECOMMENDED":
        return _with_reason("Decline recommended", reason)
    if action == "HARD_DECLINE_COMPLIANCE":
        return "Declined — compliance hold"
    # Unknown action: surface it plainly instead of guessing a friendly phrase.
    return _with_reason(action, reason)


def _with_reason(prefix: str, reason: str) -> str:
    return f"{prefix} — {reason}" if reason else prefix


# --------------------------------------------------------------------------- #
# JSON number/timestamp helpers - keep Decimal/None/datetime rendering honest.
# --------------------------------------------------------------------------- #
def _num(v):
    """Decimal -> float for JSON; None stays None (-> null)."""
    if v is None:
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return v
    # Render whole numbers without a trailing .0 where it reads better, but keep
    # it simple: json handles float fine and the dashboard formats display.
    return f


def _iso(dt) -> str:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat()


# --------------------------------------------------------------------------- #
# Blob - one BlobServiceClient built from the Key-Vault account key. The
# container is ensured (created private) once at startup; each cycle overwrites
# the same key, last-write-wins.
# --------------------------------------------------------------------------- #
def build_blob_service() -> BlobServiceClient:
    account = fetch_secret("storage-account-name")
    key = fetch_secret("storage-account-key")
    return BlobServiceClient(
        account_url=f"https://{account}.blob.core.windows.net", credential=key
    )


def ensure_container(svc: BlobServiceClient) -> None:
    """Create the output container if absent. Private by default - no public
    access is configured here and none should be added without sign-off."""
    container = svc.get_container_client(DEMO_DASHBOARD_CONTAINER)
    if not container.exists():
        # No public_access argument -> private container.
        container.create_container()
        log.info("created private container %r", DEMO_DASHBOARD_CONTAINER)
    else:
        log.info("container %r already present", DEMO_DASHBOARD_CONTAINER)


def write_snapshot(svc: BlobServiceClient, payload: bytes) -> None:
    blob = svc.get_blob_client(DEMO_DASHBOARD_CONTAINER, SNAPSHOT_BLOB_KEY)
    blob.upload_blob(
        payload,
        overwrite=True,
        content_settings=ContentSettings(
            content_type="application/json",
            cache_control="no-cache",
        ),
    )


# --------------------------------------------------------------------------- #
# Main loop.
# --------------------------------------------------------------------------- #
_STOP = False


def _handle_stop(signum, _frame):
    global _STOP
    _STOP = True
    log.info("received signal %s - will exit after this cycle", signum)


def main() -> int:
    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    run_once = os.environ.get("SNAPSHOT_ONCE") == "1"
    echo_stdout = os.environ.get("SNAPSHOT_STDOUT") == "1"

    # Fail fast on credential/target problems - but note that these are set up
    # ONCE, outside the loop, so a bad config surfaces immediately rather than
    # every 4 seconds.
    conn = connect_db()
    log.info("connected read-only to %s", EXPECTED_DB)
    svc = build_blob_service()
    ensure_container(svc)

    # Resilience contract: keep the last good serialized snapshot. On any DB or
    # Blob error mid-cycle we log it and leave the previous good blob in place -
    # we never upload a partial/empty document that would blank the dashboard -
    # and try again next cycle.
    last_good = None

    while True:
        try:
            snapshot = build_snapshot(conn)
            payload = json.dumps(snapshot, indent=2, sort_keys=False).encode("utf-8")
            write_snapshot(svc, payload)
            last_good = payload
            if echo_stdout:
                sys.stdout.write(payload.decode("utf-8") + "\n")
                sys.stdout.flush()
            log.info(
                "wrote %s/%s (%d bytes) apps=%d in_uw=%d quotes=%d bound=%d",
                DEMO_DASHBOARD_CONTAINER,
                SNAPSHOT_BLOB_KEY,
                len(payload),
                snapshot["tiles"]["applications_total"],
                snapshot["tiles"]["in_underwriting"],
                snapshot["tiles"]["quotes_issued"],
                snapshot["tiles"]["bound"],
            )
        except psycopg2.Error as exc:
            # DB problem: the connection may be dead. Log, drop it so the next
            # cycle reconnects, and leave the previous blob untouched.
            log.error("DB error, keeping previous snapshot: %s", exc)
            try:
                conn.close()
            except Exception:
                pass
            try:
                conn = connect_db()
            except Exception as reconnect_exc:
                log.error("reconnect failed, will retry next cycle: %s", reconnect_exc)
        except Exception as exc:
            # Blob or serialization problem: log and keep the last good blob.
            log.error("write/build error, keeping previous snapshot: %s", exc)
            _ = last_good  # explicitly: we do NOT overwrite the good blob here

        if run_once or _STOP:
            break
        # Interruptible sleep so a SIGTERM does not wait out the full interval.
        slept = 0.0
        while slept < SNAPSHOT_INTERVAL_SECONDS and not _STOP:
            time.sleep(min(0.5, SNAPSHOT_INTERVAL_SECONDS - slept))
            slept += 0.5

    log.info("exiting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
