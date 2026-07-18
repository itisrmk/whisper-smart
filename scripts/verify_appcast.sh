#!/usr/bin/env bash
set -euo pipefail

# Validates appcast.xml so unsigned or malformed items can never ship.
# Every item at or above 0.2.21 (when Sparkle EdDSA signing was introduced
# and SUPublicEDKey started shipping in the app) must carry a non-empty
# sparkle:edSignature, or Sparkle clients will reject the update with
# "The update is improperly signed".

APPCAST="${1:-appcast.xml}"

if [[ ! -f "$APPCAST" ]]; then
  echo "Appcast not found: $APPCAST" >&2
  exit 1
fi

/usr/bin/python3 - "$APPCAST" <<'PY'
import sys
import xml.etree.ElementTree as ET

sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIGNING_INTRODUCED = (0, 2, 21)

def version_tuple(text):
    return tuple(int(part) for part in text.split("."))

path = sys.argv[1]
root = ET.parse(path).getroot()
items = root.findall("channel/item")
errors = []

if not items:
    errors.append("appcast has no <item> entries")

for item in items:
    title = (item.findtext("title") or "untitled item").strip()
    enclosure = item.find("enclosure")
    if enclosure is None:
        errors.append(f"{title}: missing <enclosure>")
        continue

    short_version = enclosure.get(f"{sparkle}shortVersionString", "")
    if not short_version:
        errors.append(f"{title}: missing sparkle:shortVersionString")
    if not enclosure.get(f"{sparkle}version"):
        errors.append(f"{title}: missing sparkle:version")
    if not enclosure.get("url"):
        errors.append(f"{title}: missing enclosure url")
    length = enclosure.get("length", "")
    if not length.isdigit() or int(length) <= 0:
        errors.append(f"{title}: enclosure length must be a positive integer, got '{length}'")

    try:
        exempt = version_tuple(short_version) < SIGNING_INTRODUCED
    except ValueError:
        exempt = False
    if not exempt and not enclosure.get(f"{sparkle}edSignature", "").strip():
        errors.append(
            f"{title}: missing sparkle:edSignature "
            f"(required for versions >= {'.'.join(map(str, SIGNING_INTRODUCED))}; "
            "clients with SUPublicEDKey reject unsigned updates)"
        )

if errors:
    print("Appcast validation FAILED:")
    for error in errors:
        print(f"  - {error}")
    sys.exit(1)

print(f"Appcast validation passed ({len(items)} items).")
PY
