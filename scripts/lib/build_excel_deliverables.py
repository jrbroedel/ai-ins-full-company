#!/usr/bin/env python3
"""Build 2 — four Excel deliverables, READ-ONLY from the frozen canonical artifact.
Generates no new numbers: every cell is an artifact field or a documented calc/formula
over artifact fields. See ADR 0043."""
import json, hashlib, os
from pathlib import Path
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
from openpyxl.comments import Comment

# Repo-relative: this file lives at scripts/lib/ ; repo root is two levels up.
ROOT = Path(__file__).resolve().parents[2]
CANON = str(ROOT / "sample-data" / "canonical")
DATA = f"{CANON}/canonical_dataset.json"
MANIFEST = f"{CANON}/canonical_manifest.json"
OUT = f"{CANON}/deliverables"
EXPECT_SHA = "0a3d67e8774e8cd15fba1c8ab9fa484cd433ac71665a04ca040d9db96b3a9811"

# ---- fail-closed sha256 verify ----
h = hashlib.sha256(open(DATA, "rb").read()).hexdigest()
man = json.load(open(MANIFEST))
assert h == EXPECT_SHA == man["dataset_sha256"], f"SHA MISMATCH {h}"
D = json.load(open(DATA))
SUM = D["summary"]
SUBS = D["submissions"]
CLAIMS = D["policy_period_claims"]
MA = D["monthly_aggregates"]
SYNDS = D["parameters"]["syndicates"]  # ordered 10
GWP = SUM["gwp_bound"]
print(f"sha256 OK · subs={len(SUBS)} binds={SUM['binds']} claims={len(CLAIMS)}")

# class number -> label
CLASS_LABEL = {}
for r in D["rating_snapshot"]["base_rates"]:
    CLASS_LABEL[r["rating_vehicle_class"]] = r["rating_class_label"]

os.makedirs(OUT, exist_ok=True)

# ---------- shared styling ----------
# Styling layer follows the MGA Program Master conventions: Arial throughout,
# navy title banners, blue section headers, semantic tab colours, 1-dp percentages.
FN = "Arial"
NAVY = "1F3864"; BLUE = "2E5A88"; LIGHT = "D9E1F2"; GREY = "EDEDED"
TOTFILL = "D9E1F2"; MEMOFILL = "FFF2CC"
def font(sz=10, b=False, color="000000"): return Font(name=FN, size=sz, bold=b, color=color)
HFONT = Font(name=FN, size=10, bold=True, color="FFFFFF")
TITLEF = Font(name=FN, size=14, bold=True, color=NAVY)
BANNERF = Font(name=FN, size=13, bold=True, color="FFFFFF")
SUBF = Font(name=FN, size=9, italic=True, color="595959")
thin = Side(style="thin", color="BFBFBF")
BORDER = Border(left=thin, right=thin, top=thin, bottom=thin)
CUR = '#,##0.00;(#,##0.00);-'; INT = '#,##0'; PCT2 = '0.0%;(0.0%);-'; RATE = '0.0000'
CTR = Alignment(horizontal="center", vertical="center")
LEFT = Alignment(horizontal="left", vertical="center")
RIGHT = Alignment(horizontal="right", vertical="center")
WRAP = Alignment(horizontal="left", vertical="top", wrap_text=True)

def hdr(ws, row, headers, start=1):
    for i, hh in enumerate(headers):
        c = ws.cell(row=row, column=start + i, value=hh)
        c.font = HFONT; c.fill = PatternFill("solid", fgColor=BLUE)
        c.alignment = CTR; c.border = BORDER
    ws.freeze_panes = ws.cell(row=row + 1, column=1)

def title(ws, text, sub=None, span=1):
    # A1 = navy banner (white Arial 13 bold), merged across the sheet's columns.
    last_col = get_column_letter(max(span, 1))
    a1 = ws["A1"]; a1.value = text; a1.font = BANNERF
    a1.fill = PatternFill("solid", fgColor=NAVY); a1.alignment = LEFT
    if span > 1:
        ws.merge_cells(f"A1:{last_col}1")
    ws.row_dimensions[1].height = 22
    if sub:
        a2 = ws["A2"]; a2.value = sub; a2.font = SUBF
        if span > 1:
            ws.merge_cells(f"A2:{last_col}2")

def tabcolors(wb, color):
    # Semantic tab colour per workbook; every README tab is green.
    for ws in wb.worksheets:
        ws.sheet_properties.tabColor = "548235" if ws.title == "README" else color

def widths(ws, wmap):
    for col, w in wmap.items():
        ws.column_dimensions[col].width = w

PROV = (f"Source: canonical_dataset.json (ADR 0043), sha256 {EXPECT_SHA[:16]}… — verified against "
        f"canonical_manifest.json. All figures derive read-only from that frozen artifact; no new "
        f"numbers generated. Styling follows the MGA Program Master conventions (Arial; navy title "
        f"banners; blue section headers; semantic tab colours; 1-dp percentages).")

def readme_tab(wb, title_text, lines):
    ws = wb.create_sheet("README", 0)
    ws.sheet_view.showGridLines = False
    ws["A1"] = title_text; ws["A1"].font = TITLEF
    ws["A2"] = PROV; ws["A2"].font = SUBF; ws["A2"].alignment = WRAP
    ws.merge_cells("A2:H6"); ws.row_dimensions[2].height = 70
    r = 8
    for lab, val in lines:
        ws.cell(row=r, column=1, value=lab).font = font(10, b=bool(val == ""))
        if val != "":
            c = ws.cell(row=r, column=3, value=val); c.font = font(10)
        r += 1
    widths(ws, {"A": 42, "B": 3, "C": 55})
    return ws

# ================================================================= 24-FILE BUILD
# 12 monthly underwriting BDX workbooks + 12 monthly sample-rater workbooks,
# bound business ONLY, rendered read-only from the frozen artifact (ADR 0044).

# ---------- label maps ----------
STATE = {
    "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas",
    "CA": "California", "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware",
    "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii",
    "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
    "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
    "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi",
    "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
    "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
    "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
    "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
    "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah",
    "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
    "WI": "Wisconsin", "WY": "Wyoming",
}
# loss_run.pattern -> Kent's Claims History label (exact strings from his sheet)
CLAIMS_LABEL = {
    "clean": "No at-fault claims - 5 yrs",
    "minor_comp": "Comp-only claims (glass/animal/weather)",
    "one_large": "1 at-fault claim over $100k",
    "theft_total": "1 theft / total loss claim",
    "two_claims": "2 at-fault claims - 5 yrs",
    "prior_nonrenewal": "Prior carrier non-renewal / cancellation",
    "three_plus_fault": "3 + at-fault claims - 5 yrs",
}
# Fixed capacity-panel order (7.5% of premium each = 75% to capacity).
SYND_ORDER = ["Beazley", "Hiscox", "Chaucer", "Ark", "Brit", "Canopius",
              "Apollo", "Antares", "MS Amlin", "Ascot"]
assert set(SYND_ORDER) == set(SYNDS), "syndicate panel mismatch vs artifact"

from datetime import date

def expiry(eff):
    """effective_date + 1 year, same month/day (Feb-29 -> Feb-28)."""
    y, m, d = map(int, eff.split("-"))
    try:
        return date(y + 1, m, d).isoformat()
    except ValueError:
        return date(y + 1, m, d - 1).isoformat()

def state_name(abbr):
    return STATE.get(abbr, abbr)

def claims_label(pattern):
    return CLAIMS_LABEL.get(pattern, pattern)

# vehicle_category -> Kent's EXACT Base Rates class label (DISPLAY ONLY; does not
# drive any premium — rating uses quote.rating_basis, untouched here).
VCLASS_DISPLAY = {
    "production_luxury": "02 - Sports / GT",
    "exotic": "03 - Supercar",
    "classic_collector": "07 - Post-War Classic (1946-1972)",
    "restomod_coachbuilt": "11 - Restomod / Coachbuilt / Bespoke",
    "pre_war_vintage": "06 - Vintage Pre-War (pre-1946)",
}

def vclass_label(sub):
    cat = sub["vehicle"]["vehicle_category"]
    assert cat in VCLASS_DISPLAY, f"unmapped vehicle_category {cat!r}"
    return VCLASS_DISPLAY[cat]

def money(sub):
    return sub["policy"]["money"]

# ---------- month grouping (bound business only, by policy effective month) ----------
MONTHS = [m["month"] for m in MA]
MA_BY = {m["month"]: m for m in MA}
BOUND = [s for s in SUBS if s.get("policy")]
BOUND_BY_MONTH = {mon: [] for mon in MONTHS}
for s in BOUND:
    BOUND_BY_MONTH[s["policy"]["effective_date"][:7]].append(s)
for mon in BOUND_BY_MONTH:
    BOUND_BY_MONTH[mon].sort(key=lambda s: s["seq"])

BDX_ROW_GWP = {}   # policy_number -> GWP written into the month's BDX bordereau

# ================================================================= BDX (per month)
def build_bdx_month(mon):
    ma = MA_BY[mon]
    rows_m = BOUND_BY_MONTH[mon]
    wb = openpyxl.Workbook(); wb.remove(wb.active)

    # ---- Bordereau sheet ----
    bx = wb.create_sheet("Bordereau")
    cols = ["Certificate/Policy Ref", "Named Insured", "Effective Date", "Expiry Date",
            "Vehicle Year", "Make", "Model", "VIN", "Vehicle Class", "Agreed Value (USD)",
            "Garaging State", "Gross Written Premium", "Broker Commission 12.5%",
            "MGA (Torque) Commission 12.5%", "Net to Capacity 75%"] + list(SYND_ORDER) + \
           ["Policy Fee", "Inspection Fee", "Total Fees"]
    NC = len(cols)  # 28
    GWP_COL = 12    # L
    title(bx, f"Underwriting Bordereau — {mon}  (Bound business only)",
          "One row per bound policy incepting this month. Premium bordereau convention: "
          "declines and referrals never appear. Figures read-only from the frozen artifact.",
          span=NC)
    HR = 4; hdr(bx, HR, cols)
    for j, s in enumerate(rows_m):
        r = HR + 1 + j
        pol = s["policy"]; mo = pol["money"]; v = s["vehicle"]; a = s["applicant"]
        shares = mo["syndicate_shares"]
        vals = [pol["policy_number"], f'{a["first_name"]} {a["last_name"]}',
                pol["effective_date"], expiry(pol["effective_date"]),
                v["year"], v["make"], v["model"], v["vin"], vclass_label(s),
                v["agreed_value"], state_name(s["garaging_state"]), pol["bound_premium"],
                mo["commission_broker"], mo["commission_torque"], mo["markets_total"]] + \
               [shares[name] for name in SYND_ORDER] + \
               [mo["policy_fee"], mo["inspection_fee"], mo["fee_income_total"]]
        for i, val in enumerate(vals):
            c = bx.cell(row=r, column=1 + i, value=val); c.font = font(10)
            if (1 + i) == 10 or (1 + i) >= 12:   # money columns (agreed value + all $ cols)
                c.number_format = CUR
            if r % 2 == 0:
                c.fill = PatternFill("solid", fgColor=GREY)
        BDX_ROW_GWP[pol["policy_number"]] = pol["bound_premium"]
    last = HR + len(rows_m)
    bx.auto_filter.ref = f"A{HR}:{get_column_letter(NC)}{last}"
    # ---- totals + explicit commission rounding line (foots commission cols to GWP) ----
    CL = lambda i: get_column_letter(i)
    tr = last + 1
    bx.cell(row=tr, column=1, value="TOTAL").font = font(10, b=True)
    for i in [10] + list(range(12, NC + 1)):   # agreed value + all $ columns
        c = bx.cell(row=tr, column=i, value=f"=SUM({CL(i)}{HR+1}:{CL(i)}{last})")
        c.font = font(10, b=True); c.number_format = CUR
        c.fill = PatternFill("solid", fgColor=TOTFILL); c.border = BORDER
    synd_sum = f"SUM({CL(16)}{tr}:{CL(25)}{tr})"   # Σ ten syndicate column totals
    comm = f"M{tr}+N{tr}+{synd_sum}"               # broker + torque + Σ syndicates
    block = [
        ("Commission (Broker + Torque + Σ10 syndicates)", f"={comm}"),
        ("Commission rounding adjustment", f"=L{tr}-({comm})"),
        ("Footed commission (Broker+Torque+Σ10+adj) == GWP", f"={comm}+L{tr+2}"),
    ]
    for bi, (lab, formula) in enumerate(block):
        rr = tr + 1 + bi
        cL = bx.cell(row=rr, column=1, value=lab); cL.font = font(10, b=True)
        cv = bx.cell(row=rr, column=12, value=formula)   # value under the GWP column (L)
        cv.font = font(10, b=True); cv.number_format = CUR
        cv.fill = PatternFill("solid", fgColor=TOTFILL); cv.border = BORDER
    wmap = {"A": 34, "B": 22, "C": 13, "D": 13, "E": 11, "F": 16, "G": 20, "H": 20,
            "I": 26, "J": 16, "K": 16, "L": 18, "M": 18, "N": 22, "O": 18}
    for i in range(NC):
        wmap.setdefault(get_column_letter(1 + i), 12)
    widths(bx, wmap)

    # ---- Reconciliation sheet ----
    rc = wb.create_sheet("Reconciliation")
    rc.sheet_view.showGridLines = False
    title(rc, f"Bordereau Reconciliation — {mon}",
          "Bordereau totals tie to monthly_aggregates and foot to GWP.", span=3)
    hdr(rc, 4, ["Metric", "Bordereau total (live)", "Artifact (monthly_aggregates)"])
    L = lambda i: get_column_letter(i)
    rng = lambda i: f"Bordereau!{L(i)}{HR+1}:{L(i)}{last}"
    # fixed row map so avg/foot can reference the cells above
    lines = [
        ("Bound policy count", f"=COUNTA({rng(1)})", ma["binds"], INT),        # r5
        ("Gross written premium", f"=SUM({rng(12)})", ma["gwp"], CUR),         # r6
        ("Average bound premium", "=B6/B5", ma["avg_bound_premium"], CUR),      # r7
        ("Broker commission 12.5%", f"=SUM({rng(13)})", None, CUR),            # r8
        ("MGA (Torque) commission 12.5%", f"=SUM({rng(14)})", None, CUR),      # r9
        ("Net to capacity 75%", f"=SUM({rng(15)})", None, CUR),               # r10
    ]
    for si, name in enumerate(SYND_ORDER):                                     # r11..r20
        lines.append((f"  {name} (7.5%)", f"=SUM({rng(16+si)})", None, CUR))
    lines += [
        ("Policy fee income", f"=SUM({rng(26)})", None, CUR),                 # r21
        ("Inspection fee income", f"=SUM({rng(27)})", None, CUR),             # r22
        ("Total fee income", f"=SUM({rng(28)})", None, CUR),                  # r23
        ("Foot: Broker + Torque + Net-to-capacity", "=B8+B9+B10", None, CUR),      # r24
        ("Commission rounding adjustment", "=B6-(B8+B9+B10)", None, CUR),           # r25
        ("Footed commission (Broker+Torque+Net+adj) == GWP", "=B24+B25", None, CUR),# r26
    ]
    for k, (lab, f, art, fmt) in enumerate(lines):
        r = 5 + k
        cL = rc.cell(row=r, column=1, value=lab)
        cL.font = font(10, b=lab.startswith("Foot") or "adjustment" in lab.lower() or "count" in lab.lower())
        cf = rc.cell(row=r, column=2, value=f); cf.font = font(10); cf.number_format = fmt
        if lab.startswith("Foot") or "adjustment" in lab.lower():
            cf.fill = PatternFill("solid", fgColor=TOTFILL)
        if art is not None:
            ca = rc.cell(row=r, column=3, value=art); ca.font = font(10); ca.number_format = fmt
            ca.fill = PatternFill("solid", fgColor=MEMOFILL)
        for cc in range(1, 4):
            rc.cell(row=r, column=cc).border = BORDER
    widths(rc, {"A": 34, "B": 22, "C": 28})

    # ---- README ----
    readme_tab(wb, f"Underwriting BDX — {mon}", [
        ("Scope", f"Bound business only ({ma['binds']} policies incepting {mon})."),
        ("Gross written premium", f'${ma["gwp"]:,.2f}'),
        ("Commission stack", "12.5% Broker + 12.5% MGA (Torque) + 75% to capacity (7.5% ×10 syndicates)."),
        ("Verifies against", f"rater_sample_{mon}.xlsx (its GWP == that policy's Bordereau row)."),
    ])
    tabcolors(wb, "1F4E79")  # Bordereau + Reconciliation navy; README green (in helper)
    p = f"{OUT}/bdx_underwriting_{mon}.xlsx"; wb.save(p)
    # ---- hard reconcile (fail loud) ----
    py_gwp = round(sum(s["policy"]["bound_premium"] for s in rows_m), 2)
    broker_t = round(sum(s["policy"]["money"]["commission_broker"] for s in rows_m), 2)
    torque_t = round(sum(s["policy"]["money"]["commission_torque"] for s in rows_m), 2)
    synd_t = round(sum(sh for s in rows_m for sh in s["policy"]["money"]["syndicate_shares"].values()), 2)
    adjustment = round(py_gwp - (broker_t + torque_t + synd_t), 2)
    footed = round(broker_t + torque_t + synd_t + adjustment, 2)
    assert len(rows_m) == ma["binds"], f"{mon}: count {len(rows_m)} != {ma['binds']}"
    assert abs(py_gwp - ma["gwp"]) < 0.01, f"{mon}: GWP {py_gwp} != {ma['gwp']}"
    assert footed == py_gwp, f"{mon}: footed commission {footed} != GWP {py_gwp}"
    return p, len(rows_m), py_gwp, adjustment

# ================================================================= RATER SAMPLE (per month)
def build_rater_sample(mon):
    rows_m = BOUND_BY_MONTH[mon]
    s = rows_m[0]  # lowest seq (already sorted)
    pol = s["policy"]; q = s["quote"]; rb = q["rating_basis"]; mo = pol["money"]; v = s["vehicle"]
    a = s["applicant"]; ref = pol["policy_number"]
    av = rb["agreed_value"]; br = rb["base_rate_per_100"]; tf = rb["territory_factor"]
    gu = rb["gross_up_divisor"]; soft = q["softening_index"]
    base_lc = av / 100 * br
    adj_lc = base_lc * tf
    indicative = round(adj_lc / gu, 2)
    gwp = round(indicative * soft, 2)
    # HARD ASSERTS
    assert indicative == q["base_premium"], f"{mon}: indicative {indicative} != base_premium {q['base_premium']}"
    assert gwp == pol["bound_premium"], f"{mon}: GWP {gwp} != bound_premium {pol['bound_premium']}"
    assert gwp == BDX_ROW_GWP.get(ref), f"{mon}: rater GWP {gwp} != BDX row {BDX_ROW_GWP.get(ref)} for {ref}"

    wb = openpyxl.Workbook(); wb.remove(wb.active)
    rs = wb.create_sheet("Rater")
    title(rs, f"Sample Rater — {mon}  ({ref})",
          "Indicative rating build for one bound account; renders the artifact's own rating chain "
          "as values. GWP equals this policy's row in the month's underwriting BDX.", span=3)

    def section(r, label):
        c = rs.cell(row=r, column=1, value=label)
        c.font = Font(name=FN, size=11, bold=True, color="FFFFFF")
        c.fill = PatternFill("solid", fgColor=BLUE)
        for cc in (2, 3):
            rs.cell(row=r, column=cc).fill = PatternFill("solid", fgColor=BLUE)
        rs.merge_cells(start_row=r, start_column=1, end_row=r, end_column=3)
        return r + 1

    def line(r, lab, val, how="", fmt=None, italic=False):
        cl = rs.cell(row=r, column=1, value=lab); cl.font = Font(name=FN, size=10, italic=italic)
        cv = rs.cell(row=r, column=2, value=val)
        cv.font = Font(name=FN, size=10, bold=isinstance(val, (int, float)))
        if fmt:
            cv.number_format = fmt
        ch = rs.cell(row=r, column=3, value=how); ch.font = Font(name=FN, size=9, italic=True, color="595959")
        for cc in range(1, 4):
            rs.cell(row=r, column=cc).border = BORDER
        return r + 1

    r = 4
    r = section(r, "1 · RISK INPUTS (facts on file)")
    r = line(r, "Named insured", f'{a["first_name"]} {a["last_name"]}')
    r = line(r, "Certificate / policy ref", ref)
    r = line(r, "Effective date", pol["effective_date"])
    r = line(r, "Vehicle", f'{v["year"]} {v["make"]} {v["model"]}')
    r = line(r, "VIN", v["vin"])
    r = line(r, "Vehicle class", vclass_label(s), "Kent Base Rates class")
    r = line(r, "Agreed value (USD)", av, "Stated agreed value", CUR)
    r = line(r, "Garaging state", state_name(s["garaging_state"]))
    r = line(r, "Claims history (5-yr)", claims_label(s["loss_run"]["pattern"]), "Kent Claims History band")
    r = line(r, "Driver, mileage, security, deductible and sub-limit inputs are not captured in the "
                "indicative dataset.", "", "", None, italic=True)

    r += 1
    r = section(r, "2 · INDICATIVE RATING BUILD (artifact chain)")
    r = line(r, "Agreed value (USD)", av, "A", CUR)
    r = line(r, "Base rate per $100", br, "B = class base rate", RATE)
    r = line(r, "Base PD loss cost", round(base_lc, 2), "A ÷ 100 × B", CUR)
    r = line(r, "State territory factor", tf, "T = garaging-state factor", RATE)
    r = line(r, "Adjusted loss cost", round(adj_lc, 2), "(A÷100×B) × T", CUR)
    r = line(r, "Gross-up divisor", gu, "G = expense/profit gross-up", RATE)
    r = line(r, "INDICATIVE TECHNICAL PREMIUM", indicative, "ROUND(adjusted ÷ G, 2)", CUR)
    r = line(r, "Market softening index (month)", soft, "S = month softening", RATE)
    r = line(r, "GROSS WRITTEN PREMIUM", gwp, "ROUND(indicative × S, 2)", CUR)

    r += 1
    r = section(r, "3 · COMMISSION")
    r = line(r, "Total commission 25%", mo["commission_total"], "Broker + MGA", CUR)
    r = line(r, "Broker commission 12.5%", mo["commission_broker"], "12.5% of GWP", CUR)
    r = line(r, "MGA (Torque) commission 12.5%", mo["commission_torque"], "12.5% of GWP", CUR)
    r = line(r, "Net to capacity 75%", mo["markets_total"], "75% of GWP", CUR)
    for name in SYND_ORDER:
        r = line(r, f"  {name}", mo["syndicate_shares"][name], "7.5% of GWP", CUR)

    r += 1
    r = section(r, "4 · FEES")
    r = line(r, "Policy fee", mo["policy_fee"], "Per-policy fee", CUR)
    r = line(r, "Inspection fee", mo["inspection_fee"], "Applies when agreed value ≥ $1M", CUR)
    r = line(r, "TOTAL DUE (GWP + fees)", round(gwp + mo["fee_income_total"], 2),
             "GWP + total fees", CUR)

    widths(rs, {"A": 40, "B": 20, "C": 34})

    readme_tab(wb, f"Sample Rater — {mon}", [
        ("Sample account", f"Lowest-seq bound policy incepting {mon}: {ref}."),
        ("Indicative technical premium", f'${indicative:,.2f}  (== quote base premium)'),
        ("Gross written premium", f'${gwp:,.2f}  (== this policy\'s row in bdx_underwriting_{mon}.xlsx)'),
        ("Note", "Rating build shown as values; declines/refers never appear (bound business only)."),
    ])
    tabcolors(wb, "1F4E79")  # Rater navy; README green (in helper)
    p = f"{OUT}/rater_sample_{mon}.xlsx"; wb.save(p)
    return p, ref, gwp, indicative, q["base_premium"], pol["bound_premium"]

# ================================================================= DRIVER
# Remove the four superseded interim files (ADR 0044).
for _old in ("01_submissions_export", "02_monthly_raters", "03_underwriting_bdx", "04_claims_bdx"):
    _fp = f"{OUT}/{_old}.xlsx"
    if os.path.exists(_fp):
        os.remove(_fp); print(f"removed interim: {_old}.xlsx")

RECON = []   # per-month reconciliation report rows
paths = []
for mon in MONTHS:
    bp, bcount, bgwp, badj = build_bdx_month(mon)
    rp, ref, rgwp, rind, base_prem, bound_prem = build_rater_sample(mon)
    ma = MA_BY[mon]
    RECON.append({
        "month": mon,
        "bdx_count": bcount, "ma_binds": ma["binds"], "count_ok": bcount == ma["binds"],
        "bdx_gwp": bgwp, "ma_gwp": ma["gwp"], "gwp_ok": abs(bgwp - ma["gwp"]) < 0.01,
        "adjustment": badj,
        "rater_ref": ref, "rater_gwp": rgwp, "bdx_row_gwp": BDX_ROW_GWP.get(ref),
        "rater_gwp_ok": rgwp == BDX_ROW_GWP.get(ref),
        "rater_ind": rind, "base_premium": base_prem, "ind_ok": rind == base_prem,
    })
    paths += [bp, rp]

total_bdx_gwp = round(sum(r["bdx_gwp"] for r in RECON), 2)
grand_ok = abs(total_bdx_gwp - SUM["gwp_bound"]) < 0.01

print("\n=== RECONCILIATION ===")
print(f"{'month':8} {'bdxCnt':>6} {'maBinds':>7} cnt {'bdxGWP':>14} {'maGWP':>14} gwp  {'raterRef':>20} rGWP=BDX indPrem=base {'commAdj':>8}")
allok = True
for r in RECON:
    allok &= r["count_ok"] and r["gwp_ok"] and r["rater_gwp_ok"] and r["ind_ok"]
    print(f"{r['month']:8} {r['bdx_count']:6d} {r['ma_binds']:7d} "
          f"{'Y' if r['count_ok'] else 'N'}  {r['bdx_gwp']:14,.2f} {r['ma_gwp']:14,.2f} "
          f"{'Y' if r['gwp_ok'] else 'N'}   {r['rater_ref']:>20} "
          f"{'Y' if r['rater_gwp_ok'] else 'N'}       {'Y' if r['ind_ok'] else 'N'}     {r['adjustment']:8.2f}")
print(f"\nSum of 12 BDX GWP totals = ${total_bdx_gwp:,.2f}  vs summary.gwp_bound "
      f"${SUM['gwp_bound']:,.2f}  ->  {'TIE' if grand_ok else 'MISMATCH'}")
print(f"ALL PER-MONTH CHECKS: {'PASS' if allok else 'FAIL'}")
if not (allok and grand_ok):
    raise SystemExit("RECONCILIATION FAILED — see 'N'/MISMATCH above.")

print(f"\nBUILT {len(paths)} files:")
for p in paths:
    print("  ", p)
