#!/usr/bin/env python3
"""
recalc.py — force LibreOffice to recalculate an .xlsx and write the cached
formula values back into the file, IN PLACE.

WHY
---
openpyxl writes formula cells as <f>…</f><v></v> — an EMPTY cached-value
element. Excel treats an empty <v> on a numeric formula cell as corrupt content
and prompts to "repair"; openpyxl and LibreOffice tolerate it. Running the file
through LibreOffice with recalculation forced rewrites every <v></v> with the
computed number, so Excel opens it clean.

WHAT IT TOUCHES
---------------
Only the single .xlsx passed on the command line. It performs NO database access
and never reads the canonical artifact — it is a pure spreadsheet post-processor,
so the build's read-only-artifact / prod-name discipline is unaffected.

HOW
---
LibreOffice --convert-to recalculates on load only when the OOXML recalc mode is
"Always". We stamp a throwaway user profile (registrymodifications.xcu,
OOXMLRecalcMode = 0 = Always) and point soffice at it via -env:UserInstallation,
so recalculation is forced regardless of the machine's default. The converted
file is written to a temp dir and then moved back over the original.

Usage:
  python3 scripts/recalc.py <file.xlsx>
Prints a single JSON status line, e.g.
  {"status": "success", "file": "...", "total_errors": 0, "empty_v": 0}
Exit code 0 on success (status=success AND total_errors=0 AND empty_v=0), else 1.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

SOFFICE = shutil.which("soffice") or shutil.which("libreoffice")

# Excel error tokens a recalculated cell might hold.
_ERR = re.compile(r"#(REF|DIV/0|VALUE|NAME|N/A|NULL|NUM)!|Err:\d+")

# registrymodifications.xcu fragment: OOXMLRecalcMode = 0 (Always recalculate).
_RECALC_XCU = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<oor:items xmlns:oor="http://openoffice.org/2001/registry" '
    'xmlns:xs="http://www.w3.org/2001/XMLSchema" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
    ' <item oor:path="/org.openoffice.Office.Calc/Formula/Load">'
    '<prop oor:name="OOXMLRecalcMode" oor:op="fuse"><value>0</value></prop></item>\n'
    ' <item oor:path="/org.openoffice.Office.Calc/Formula/Load">'
    '<prop oor:name="ODFRecalcMode" oor:op="fuse"><value>0</value></prop></item>\n'
    '</oor:items>\n'
)


def _count_empty_v(path):
    with zipfile.ZipFile(path) as z:
        n = 0
        for name in z.namelist():
            if name.startswith("xl/worksheets/") and name.endswith(".xml"):
                n += z.read(name).decode("utf-8", "replace").count("<v></v>")
    return n


def _count_errors(path):
    # Count cells whose recalculated value is an Excel error token.
    import openpyxl
    wb = openpyxl.load_workbook(path, data_only=True)
    n = 0
    for ws in wb.worksheets:
        for row in ws.iter_rows():
            for c in row:
                if isinstance(c.value, str) and _ERR.search(c.value):
                    n += 1
    wb.close()
    return n


def recalc_inplace(path):
    if SOFFICE is None:
        raise SystemExit("recalc: no soffice/libreoffice on PATH")
    path = os.path.abspath(path)
    if not path.lower().endswith(".xlsx") or not os.path.isfile(path):
        raise SystemExit(f"recalc: not an .xlsx file: {path}")

    with tempfile.TemporaryDirectory(prefix="recalc_") as td:
        profile = os.path.join(td, "profile")
        userdir = os.path.join(profile, "user")
        os.makedirs(userdir, exist_ok=True)
        with open(os.path.join(userdir, "registrymodifications.xcu"), "w") as f:
            f.write(_RECALC_XCU)
        outdir = os.path.join(td, "out")
        os.makedirs(outdir, exist_ok=True)
        cmd = [
            SOFFICE, "--headless", "--calc", "--nologo", "--norestore",
            f"-env:UserInstallation=file://{profile}",
            "--convert-to", "xlsx:Calc MS Excel 2007 XML",
            "--outdir", outdir, path,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        produced = os.path.join(outdir, os.path.basename(path))
        if proc.returncode != 0 or not os.path.isfile(produced):
            return {"status": "error", "file": path, "returncode": proc.returncode,
                    "stderr": proc.stderr.strip()[:500]}
        shutil.move(produced, path)  # overwrite the original in place

    empty_v = _count_empty_v(path)
    total_errors = _count_errors(path)
    status = "success" if (empty_v == 0 and total_errors == 0) else "failed"
    return {"status": status, "file": path, "total_errors": total_errors,
            "empty_v": empty_v}


def main(argv):
    if len(argv) != 1:
        print(json.dumps({"status": "error", "msg": "usage: recalc.py <file.xlsx>"}))
        return 2
    result = recalc_inplace(argv[0])
    print(json.dumps(result))
    return 0 if result.get("status") == "success" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
