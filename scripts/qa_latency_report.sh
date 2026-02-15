#!/usr/bin/env bash
set -euo pipefail

METRICS_FILE="${METRICS_FILE:-$HOME/Library/Application Support/WhisperSmart/metrics/dictation-sessions.json}"
LOOKBACK="${QA_LOOKBACK:-400}"
ENFORCE="${QA_ENFORCE_SLO:-0}"
ALLOW_EMPTY="${QA_ALLOW_EMPTY:-1}"
MIN_SAMPLES="${QA_MIN_SAMPLES:-15}"

/usr/bin/python3 - "$METRICS_FILE" "$LOOKBACK" "$ENFORCE" "$ALLOW_EMPTY" "$MIN_SAMPLES" <<'PY'
import json
import math
import os
import sys
from collections import defaultdict

metrics_file = sys.argv[1]
lookback = int(sys.argv[2])
enforce = sys.argv[3] == "1"
allow_empty = sys.argv[4] == "1"
min_samples = int(sys.argv[5])

def normalize_provider(provider: str) -> str:
    p = (provider or "").strip().lower()
    if "parakeet" in p:
        return "parakeet"
    if "openai" in p:
        return "openai"
    if "apple" in p:
        return "apple_speech"
    if "whisper" in p:
        return "whisper_local"
    return "other"

thresholds = {
    "apple_speech": (900, 1800),
    "parakeet": (1400, 2800),
    "whisper_local": (2000, 3600),
    "openai": (2600, 5000),
    "other": (2000, 4000),
}

if not os.path.exists(metrics_file):
    message = f"Latency QA report: no metrics file at {metrics_file}."
    if enforce and not allow_empty:
        print(message, file=sys.stderr)
        sys.exit(1)
    print(message)
    print("Latency QA report: skipped (no samples).")
    sys.exit(0)

try:
    with open(metrics_file, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception as exc:
    print(f"Latency QA report: failed to parse metrics file: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(payload, list):
    print("Latency QA report: malformed metrics payload (expected JSON array).", file=sys.stderr)
    sys.exit(1)

window = payload[: max(1, lookback)]
groups = defaultdict(list)
for item in window:
    if not isinstance(item, dict):
        continue
    provider = str(item.get("provider", "Unknown"))
    e2e = item.get("endToEndDurationMs")
    if isinstance(e2e, int) and e2e > 0:
        key = normalize_provider(provider)
        groups[key].append(e2e)

if not groups:
    message = "Latency QA report: metrics file has no usable end-to-end samples."
    if enforce and not allow_empty:
        print(message, file=sys.stderr)
        sys.exit(1)
    print(message)
    print("Latency QA report: skipped (no usable samples).")
    sys.exit(0)

def p95(values):
    sorted_values = sorted(values)
    idx = max(0, min(len(sorted_values) - 1, math.ceil(len(sorted_values) * 0.95) - 1))
    return sorted_values[idx]

print("Latency QA report (provider SLOs):")
print("provider           samples  avg_ms  p95_ms  avg_target  p95_target  status")

failures = []
for provider in sorted(groups.keys()):
    values = groups[provider]
    avg_ms = int(sum(values) / len(values))
    p95_ms = p95(values)
    target_avg, target_p95 = thresholds.get(provider, thresholds["other"])
    status = "PASS" if (avg_ms <= target_avg and p95_ms <= target_p95) else "FAIL"
    print(f"{provider:16} {len(values):7d} {avg_ms:7d} {p95_ms:7d} {target_avg:10d} {target_p95:11d}  {status}")

    if enforce and len(values) >= min_samples and status == "FAIL":
        failures.append(
            f"{provider}: avg={avg_ms}ms/p95={p95_ms}ms exceeds targets {target_avg}ms/{target_p95}ms"
        )

if failures:
    print("\nLatency SLO enforcement failures:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)

print("\nLatency QA report passed.")
PY
