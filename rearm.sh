#!/usr/bin/env bash
# Schedule the next feed build.
#
# GitHub's scheduler was creating a run of this repo every 4–6 hours and
# dropping the rest. workflow_dispatch starts immediately, and the built-in
# GITHUB_TOKEN is allowed to send it, so each publish arms the next one.
# A newer run takes over. Crons only restart this chain after it dies.

set -euo pipefail

INTERVAL="${INTERVAL:-1800}"
STALE_DELAY="${STALE_DELAY:-20}"
CHUNK="${CHUNK:-60}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
WORKFLOW="${WORKFLOW:-build.yml}"
REF="${REF:-main}"
PAGES_URL="${PAGES_URL:?PAGES_URL is required}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

case "$INTERVAL" in
  ''|*[!0-9]*) INTERVAL=1800 ;;
esac
case "$STALE_DELAY" in
  ''|*[!0-9]*) STALE_DELAY=20 ;;
esac
case "$CHUNK" in
  ''|*[!0-9]*) CHUNK=60 ;;
esac
case "$RUN_ID" in
  ''|*[!0-9]*) echo "RUN_ID must be numeric" >&2; exit 1 ;;
esac
if [ "$INTERVAL" -lt 60 ]; then INTERVAL=60; fi
if [ "$INTERVAL" -gt 1800 ]; then INTERVAL=1800; fi
if [ "$STALE_DELAY" -lt 1 ]; then STALE_DELAY=1; fi
if [ "$STALE_DELAY" -gt 60 ]; then STALE_DELAY=60; fi
if [ "$CHUNK" -lt 1 ]; then CHUNK=1; fi

# Prints how many newer runs are still in flight. Returns non-zero if the
# listing itself failed. "completed" includes cancelled runs; those are done.
active_newer() {
  local json
  json=$(gh run list --workflow "$WORKFLOW" --repo "$REPO" --limit 50 --json databaseId,status) || return 1
  RUN_ID="$RUN_ID" python3 -c '
import json, os, sys
me = int(os.environ["RUN_ID"])
rows = json.load(sys.stdin)
print(sum(1 for r in rows if int(r["databaseId"]) > me and r.get("status") != "completed"))
' <<<"$json"
}

# Retry a command that must succeed before we either bow out or dispatch.
retry() {
  local attempt=1
  local max=4
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      return 1
    fi
    echo "Command failed (attempt ${attempt}/${max}): $*" >&2
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

if ! newer=$(retry active_newer); then
  echo "Could not list workflow runs" >&2
  exit 1
fi
if [ "$newer" != "0" ]; then
  echo "A newer run is already active (${newer}). It will schedule the next build."
  exit 0
fi

now=$(date -u +%s)
age=""

# Record one timestamp's age and keep the smallest non-negative age.
note() {
  local label=$1 value=$2 epoch a
  epoch=$(date -u -d "$value" +%s 2>/dev/null) || { echo "${label}: unreadable (${value})"; return 0; }
  a=$((now - epoch))
  echo "${label}: ${value} (${a}s old)"
  if [ "$a" -lt 0 ]; then a=0; fi
  if [ -z "$age" ] || [ "$a" -lt "$age" ]; then age=$a; fi
}

if created_json=$(gh run view "$RUN_ID" --repo "$REPO" --json createdAt); then
  created=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("createdAt") or "")' <<<"$created_json" || true)
  if [ -n "$created" ]; then
    note "This run" "$created"
  fi
else
  echo "Could not read this run's start time" >&2
fi

if body=$(curl -fsS --max-time 20 "$PAGES_URL"); then
  generated=$(python3 -c 'import json,sys; print((json.load(sys.stdin).get("generated") or ""))' <<<"$body" || true)
  if [ -n "${generated:-}" ]; then
    note "Live feeds.json" "$generated"
  else
    echo "Live feeds.json has no generated timestamp"
  fi
else
  echo "Could not read live feeds.json; using this run's age only"
fi

if [ -z "$age" ]; then
  delay=$INTERVAL
elif [ "$age" -ge "$INTERVAL" ]; then
  # This run has already been waiting longer than the interval (queued behind
  # another rearm, or restarted by the watchdog). Publish again soon.
  delay=$STALE_DELAY
else
  delay=$((INTERVAL - age))
fi

echo "Sleeping ${delay}s (interval ${INTERVAL}s, age ${age:-unknown}s)"

remain=$delay
while [ "$remain" -gt 0 ]; do
  if newer=$(active_newer 2>/dev/null) && [ "$newer" != "0" ]; then
    echo "A newer run arrived while waiting (${newer}). It will schedule the next build."
    exit 0
  fi
  step=$CHUNK
  if [ "$remain" -lt "$step" ]; then step=$remain; fi
  echo "Waiting ${remain}s before the next feed build"
  sleep "$step"
  remain=$((remain - step))
done

if ! newer=$(retry active_newer); then
  echo "Could not list workflow runs after waiting" >&2
  exit 1
fi
if [ "$newer" != "0" ]; then
  echo "A newer run arrived while waiting (${newer}). It will schedule the next build."
  exit 0
fi

echo "Dispatching ${WORKFLOW} on ${REF}"
if ! retry gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$REF"; then
  echo "Failed to dispatch the next build" >&2
  exit 1
fi
echo "Dispatched the next build"
