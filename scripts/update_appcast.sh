#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/update_appcast.sh \
    --version 0.2.18 \
    --build-version 202602152259 \
    --dmg-url https://github.com/ORG/REPO/releases/download/v0.2.18/Whisper-Smart-mac.dmg \
    --dmg-length 4701980 \
    [--notes-file /path/to/notes.md] \
    [--pub-date "Sun, 15 Feb 2026 22:59:42 +0000"] \
    [--output appcast.xml]
EOF
}

VERSION=""
BUILD_VERSION=""
DMG_URL=""
DMG_LENGTH=""
NOTES_FILE=""
OUTPUT="appcast.xml"
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"; shift 2 ;;
    --build-version)
      BUILD_VERSION="${2:-}"; shift 2 ;;
    --dmg-url)
      DMG_URL="${2:-}"; shift 2 ;;
    --dmg-length)
      DMG_LENGTH="${2:-}"; shift 2 ;;
    --notes-file)
      NOTES_FILE="${2:-}"; shift 2 ;;
    --pub-date)
      PUB_DATE="${2:-}"; shift 2 ;;
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

if [[ -z "$VERSION" || -z "$BUILD_VERSION" || -z "$DMG_URL" || -z "$DMG_LENGTH" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

NOTES_PATH="$NOTES_FILE"
if [[ -z "$NOTES_PATH" ]]; then
  NOTES_PATH="$(mktemp)"
  printf "Whisper Smart %s release." "$VERSION" >"$NOTES_PATH"
fi

/usr/bin/python3 - "$OUTPUT" "$VERSION" "$BUILD_VERSION" "$DMG_URL" "$DMG_LENGTH" "$NOTES_PATH" "$PUB_DATE" "$MIN_SYSTEM_VERSION" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET
from xml.dom import minidom

output, version, build_version, dmg_url, dmg_length, notes_path, pub_date, min_system = sys.argv[1:]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle_ns)
sparkle = f"{{{sparkle_ns}}}"

if os.path.exists(notes_path):
    with open(notes_path, "r", encoding="utf-8") as fh:
        notes_text = fh.read().strip()
else:
    notes_text = f"Whisper Smart {version} release."

if not notes_text:
    notes_text = f"Whisper Smart {version} release."

if os.path.exists(output):
    try:
        tree = ET.parse(output)
        root = tree.getroot()
        channel = root.find("channel")
        if channel is None:
            raise ValueError("appcast.xml missing <channel>")
    except Exception:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
else:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")

def set_text(tag: str, text: str):
    node = channel.find(tag)
    if node is None:
        node = ET.SubElement(channel, tag)
    node.text = text

set_text("title", "Whisper Smart Releases")
set_text("link", "https://github.com/itisrmk/whisper-smart/releases")
set_text("description", "Latest releases of Whisper Smart")
set_text("language", "en")

# Remove any existing item for this short version string.
for item in list(channel.findall("item")):
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    short_version = enclosure.attrib.get(f"{sparkle}shortVersionString", "")
    if short_version == version:
        channel.remove(item)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {version}"
ET.SubElement(item, "description").text = notes_text
ET.SubElement(item, "pubDate").text = pub_date

enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", dmg_url)
enclosure.set(f"{sparkle}shortVersionString", version)
enclosure.set(f"{sparkle}version", build_version)
enclosure.set("length", dmg_length)
enclosure.set("type", "application/octet-stream")

ET.SubElement(item, f"{sparkle}minimumSystemVersion").text = min_system

existing_items = list(channel.findall("item"))
for existing in existing_items:
    channel.remove(existing)
channel.append(item)
for existing in existing_items[:24]:
    channel.append(existing)

xml_bytes = ET.tostring(root, encoding="utf-8")
pretty = minidom.parseString(xml_bytes).toprettyxml(indent="  ", encoding="utf-8")
pretty_text = pretty.decode("utf-8")
collapsed = "\n".join(line for line in pretty_text.splitlines() if line.strip()) + "\n"
with open(output, "w", encoding="utf-8") as fh:
    fh.write(collapsed)

print(f"Updated {output} with version {version} (build {build_version})")
PY
