#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Sets sparkle:edSignature (and optionally length) on an existing appcast item.
Used to repair published appcast entries that were created without a Sparkle
EdDSA signature.

Usage:
  bash scripts/set_appcast_signature.sh \
    --version 0.2.24 \
    --ed-signature BASE64_SPARKLE_SIGNATURE \
    [--dmg-length 4798044] \
    [--output appcast.xml]
EOF
}

VERSION=""
ED_SIGNATURE=""
DMG_LENGTH=""
OUTPUT="appcast.xml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"; shift 2 ;;
    --ed-signature)
      ED_SIGNATURE="${2:-}"; shift 2 ;;
    --dmg-length)
      DMG_LENGTH="${2:-}"; shift 2 ;;
    --output)
      OUTPUT="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "$VERSION" || -z "$ED_SIGNATURE" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

/usr/bin/python3 - "$OUTPUT" "$VERSION" "$ED_SIGNATURE" "$DMG_LENGTH" <<'PY'
import sys
import xml.etree.ElementTree as ET
from xml.dom import minidom

output, version, ed_signature, dmg_length = sys.argv[1:]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle_ns)
sparkle = f"{{{sparkle_ns}}}"

tree = ET.parse(output)
root = tree.getroot()
channel = root.find("channel")
if channel is None:
    raise SystemExit("appcast missing <channel>")

matched = False
for item in channel.findall("item"):
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    if enclosure.attrib.get(f"{sparkle}shortVersionString", "") != version:
        continue
    enclosure.set(f"{sparkle}edSignature", ed_signature)
    if dmg_length:
        enclosure.set("length", dmg_length)
    matched = True

if not matched:
    raise SystemExit(f"No appcast item found for version {version}")

xml_bytes = ET.tostring(root, encoding="utf-8")
pretty = minidom.parseString(xml_bytes).toprettyxml(indent="  ", encoding="utf-8")
pretty_text = pretty.decode("utf-8")
collapsed = "\n".join(line for line in pretty_text.splitlines() if line.strip()) + "\n"
with open(output, "w", encoding="utf-8") as fh:
    fh.write(collapsed)

print(f"Set edSignature on appcast item {version}")
PY
