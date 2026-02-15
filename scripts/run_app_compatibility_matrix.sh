#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_DIR="$REPO_ROOT/docs/reports"
mkdir -p "$REPORT_DIR"

DATE_STAMP="$(date +%F)"
TIME_STAMP="$(date +"%Y-%m-%d %H:%M:%S %Z")"
REPORT_PATH="$REPORT_DIR/app-compatibility-$DATE_STAMP.md"

/usr/bin/python3 - "$REPORT_PATH" "$TIME_STAMP" <<'PY'
import os
import plistlib
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
timestamp = sys.argv[2]

targets = [
    ("Mail", "com.apple.mail"),
    ("Slack", "com.tinyspeck.slackmacgap"),
    ("Notion", "notion.id"),
    ("Google Docs (Chrome)", "com.google.Chrome"),
    ("VS Code", "com.microsoft.VSCode"),
    ("Cursor", "com.todesktop.230313mzl4w4u92"),
    ("Terminal", "com.apple.Terminal"),
]

search_roots = [
    Path("/Applications"),
    Path("/System/Applications"),
    Path.home() / "Applications",
]

bundle_index = {}
for root in search_roots:
    if not root.exists():
        continue
    for app in root.rglob("*.app"):
        info_plist = app / "Contents" / "Info.plist"
        if not info_plist.exists():
            continue
        try:
            with open(info_plist, "rb") as fh:
                info = plistlib.load(fh)
        except Exception:
            continue
        bundle_id = info.get("CFBundleIdentifier")
        if isinstance(bundle_id, str) and bundle_id and bundle_id not in bundle_index:
            bundle_index[bundle_id] = str(app)

rows = []
for app_name, bundle_id in targets:
    path = bundle_index.get(bundle_id)
    installed = "Yes" if path else "No"
    location = path if path else "—"
    launch_status = "Pending manual check" if path else "Not installed"
    dictation_status = "Pending manual check" if path else "Not installed"
    injection_status = "Pending manual check" if path else "Not installed"
    rows.append((app_name, bundle_id, installed, location, launch_status, dictation_status, injection_status))

content = []
content.append("# App Compatibility Sweep")
content.append("")
content.append(f"Generated: {timestamp}")
content.append("")
content.append("| App | Bundle ID | Installed | Location | Launch | Dictation | Injection |")
content.append("| --- | --- | --- | --- | --- | --- | --- |")
for row in rows:
    content.append(
        f"| {row[0]} | `{row[1]}` | {row[2]} | {row[3]} | {row[4]} | {row[5]} | {row[6]} |"
    )

content.append("")
content.append("## Notes")
content.append("- This report auto-discovers installed app targets.")
content.append("- `Launch`, `Dictation`, and `Injection` remain manual verification checkpoints.")
content.append("- Use this report as the artifact for Phase 1 compatibility sweep tracking.")
content.append("")

report_path.write_text("\n".join(content), encoding="utf-8")
print(f"Compatibility matrix written to {report_path}")
PY

echo "$REPORT_PATH"
