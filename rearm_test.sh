#!/usr/bin/env bash
# Exercise rearm.sh without GitHub. Fake gh, curl, and sleep sit on PATH.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
PASS=0
FAIL=0

assert() {
  local name=$1
  if eval "$2"; then
    PASS=$((PASS + 1))
    echo "ok  ${name}"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL ${name}"
    echo "    $2" >&2
  fi
}

sum_sleeps() {
  if [ -f "$SLEEP_LOG" ]; then
    awk '{s+=$1} END {print s+0}' "$SLEEP_LOG"
  else
    echo 0
  fi
}

dispatch_count() {
  if [ -f "$GH_LOG" ]; then
    grep -c '^workflow run' "$GH_LOG" || true
  else
    echo 0
  fi
}

# Run rearm.sh. Extra args are env assignments (KEY=value).
run_rearm() {
  local tmp runs created feed fail_left inject
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin"
  runs=$1
  created=$2
  feed=$3
  fail_left=${4:-0}
  inject=${5:-0}
  shift 5 || true

  SLEEP_LOG=$tmp/sleep GH_LOG=$tmp/ghlog FAIL_FILE=$tmp/fail
  export SLEEP_LOG GH_LOG FAIL_FILE
  echo "$fail_left" > "$FAIL_FILE"
  printf '%s' "$runs" > "$tmp/runs.json"
  printf '%s' "$feed" > "$tmp/feed.json"
  cat > "$tmp/run.json" <<EOF
{"createdAt":"${created}"}
EOF
  echo "$inject" > "$tmp/inject"

  cat > "$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$SLEEP_LOG"
if [ "$(cat "$INJECT_FILE")" = "1" ]; then
  printf '%s' "$INJECT_RUNS" > "$RUNS_FILE"
  echo 0 > "$INJECT_FILE"
fi
EOF
  cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [ "${CURL_FAIL:-0}" = "1" ]; then
  exit 22
fi
cat "$FEED_FILE"
EOF
  cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "run" ] && [ "$2" = "list" ]; then
  cat "$RUNS_FILE"
  exit 0
fi
if [ "$1" = "run" ] && [ "$2" = "view" ]; then
  cat "$RUN_FILE"
  exit 0
fi
if [ "$1" = "workflow" ] && [ "$2" = "run" ]; then
  echo "workflow run $*" >> "$GH_LOG"
  left=$(cat "$FAIL_FILE")
  if [ "$left" -gt 0 ]; then
    echo $((left - 1)) > "$FAIL_FILE"
    exit 1
  fi
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 1
EOF
  chmod +x "$tmp/bin/sleep" "$tmp/bin/curl" "$tmp/bin/gh"

  set +e
  PATH="$tmp/bin:$PATH" \
    RUNS_FILE="$tmp/runs.json" \
    RUN_FILE="$tmp/run.json" \
    FEED_FILE="$tmp/feed.json" \
    INJECT_FILE="$tmp/inject" \
    INJECT_RUNS='[{"databaseId":100,"status":"in_progress"},{"databaseId":200,"status":"in_progress"}]' \
    GH_TOKEN=fake \
    GITHUB_REPOSITORY=AustinOutside/agiblog-feed \
    RUN_ID=100 \
    PAGES_URL=https://example.test/feeds.json \
    WORKFLOW=build.yml \
    REF=main \
    INTERVAL=1800 \
    CHUNK=60 \
    "$@" \
    bash "$ROOT/rearm.sh" > "$tmp/out" 2>"$tmp/err"
  code=$?
  set -e
  OUT=$(cat "$tmp/out")
  ERR=$(cat "$tmp/err")
  CODE=$code
  SLEEPS=$(sum_sleeps)
  DISPATCHES=$(dispatch_count)
  rm -rf "$tmp"
}

iso_ago() {
  date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ
}

echo "rearm.sh"
empty='[]'
self='[{"databaseId":100,"status":"in_progress"}]'
newer='[{"databaseId":100,"status":"completed"},{"databaseId":150,"status":"in_progress"}]'
fresh=$(iso_ago "60 seconds ago")
old=$(iso_ago "3 hours ago")
future=$(iso_ago "1 hour")
feed_fresh=$(printf '{"generated":"%s","feeds":{}}' "$fresh")
feed_old=$(printf '{"generated":"%s","feeds":{}}' "$old")
feed_future=$(printf '{"generated":"%s","feeds":{}}' "$future")

run_rearm "$newer" "$fresh" "$feed_fresh" 0 0
assert "newer run exits without sleeping or dispatching" "[ \"$CODE\" -eq 0 ] && [ \"$SLEEPS\" -eq 0 ] && [ \"$DISPATCHES\" -eq 0 ]"

run_rearm "$self" "$fresh" "$feed_fresh" 0 0
assert "fresh run waits out the rest of the interval" "[ \"$CODE\" -eq 0 ] && [ \"$SLEEPS\" -ge 1700 ] && [ \"$SLEEPS\" -le 1760 ] && [ \"$DISPATCHES\" -eq 1 ]"

run_rearm "$self" "$old" "$feed_old" 0 0
assert "stale run dispatches after a short delay" "[ \"$CODE\" -eq 0 ] && [ \"$SLEEPS\" -eq 20 ] && [ \"$DISPATCHES\" -eq 1 ]"

run_rearm "$self" "$old" "$feed_fresh" 0 0
assert "fresh file beats an old run start" "[ \"$CODE\" -eq 0 ] && [ \"$SLEEPS\" -ge 1700 ] && [ \"$SLEEPS\" -le 1760 ] && [ \"$DISPATCHES\" -eq 1 ]"

run_rearm "$self" "$fresh" "$feed_future" 0 0
assert "future timestamp does not stretch the wait" "[ \"$CODE\" -eq 0 ] && [ \"$SLEEPS\" -eq 1800 ] && [ \"$DISPATCHES\" -eq 1 ]"

CURL_FAIL=1 run_rearm "$self" "$fresh" "$feed_old" 0 0
assert "unreadable file falls back to this run's age" "[ \"$CODE\" -eq 0 ] && [ \"$SLEEPS\" -ge 1700 ] && [ \"$SLEEPS\" -le 1760 ] && [ \"$DISPATCHES\" -eq 1 ]"
CURL_FAIL=0

run_rearm "$self" "$old" "$feed_old" 0 1
assert "a run that appears during the wait is not duplicated" "[ \"$CODE\" -eq 0 ] && [ \"$DISPATCHES\" -eq 0 ]"

run_rearm "$self" "$old" "$feed_old" 2 0
assert "dispatch retries then succeeds" "[ \"$CODE\" -eq 0 ] && [ \"$DISPATCHES\" -eq 3 ] && [ \"$SLEEPS\" -eq 26 ]"

run_rearm "$self" "$old" "$feed_old" 10 0
assert "dispatch gives up after repeated failures" "[ \"$CODE\" -eq 1 ] && [ \"$DISPATCHES\" -eq 4 ]"

run_rearm "$empty" "not-a-date" "not-json" 0 0
assert "unreadable clocks still wait one interval" "[ \"$CODE\" -eq 0 ] && [ \"$SLEEPS\" -eq 1800 ] && [ \"$DISPATCHES\" -eq 1 ]"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
