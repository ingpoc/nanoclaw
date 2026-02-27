#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_FILE="$ROOT_DIR/logs/nanoclaw.log"
LINES=200
FOLLOW=1
LANE_FILTER=""
SINCE=""
JSON_STREAM=0

usage() {
  cat <<'USAGE'
Usage: scripts/jarvis-watch.sh [options]

Options:
  --file <path>      Log file to watch (default: logs/nanoclaw.log)
  --lines <n>        Number of lines for initial summary and tail (default: 200)
  --lane <value>     Filter lines by lane folder/jid/name substring
  --since <iso>      Best-effort time filter (same-day HH:MM:SS extraction)
  --once             Print summary only, do not follow
  --json-stream      Emit one JSON object per matched event while following
  -h, --help         Show help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file) LOG_FILE="$2"; shift 2 ;;
    --lines) LINES="$2"; shift 2 ;;
    --lane) LANE_FILTER="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --once) FOLLOW=0; shift ;;
    --json-stream) JSON_STREAM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if ! [[ "$LINES" =~ ^[0-9]+$ ]]; then
  echo "Invalid --lines value: $LINES"
  exit 1
fi

if [ ! -f "$LOG_FILE" ]; then
  echo "Log file not found: $LOG_FILE"
  exit 1
fi

since_time=""
if [ -n "$SINCE" ]; then
  since_time="$(python3 - "$SINCE" <<'PY'
import datetime
import sys
raw = sys.argv[1]
try:
    dt = datetime.datetime.fromisoformat(raw.replace('Z', '+00:00'))
    print(dt.strftime('%H:%M:%S'))
except Exception:
    print('')
PY
)"
  if [ -z "$since_time" ]; then
    echo "Invalid --since value (expected ISO timestamp): $SINCE"
    exit 1
  fi
fi

snapshot_file="$(mktemp /tmp/jarvis-watch.XXXXXX.log)"
trap 'rm -f "$snapshot_file"' EXIT

tail -n "$LINES" "$LOG_FILE" >"$snapshot_file" || true

apply_filters() {
  local file="$1"
  if [ -n "$LANE_FILTER" ]; then
    rg -i "$LANE_FILTER" "$file" >"${file}.lane" || true
    mv "${file}.lane" "$file"
  fi

  if [ -n "$since_time" ]; then
    awk -v t="$since_time" '
      {
        if (match($0, /^\[([0-9]{2}:[0-9]{2}:[0-9]{2})\./, a)) {
          if (a[1] >= t) print $0;
        } else {
          print $0;
        }
      }
    ' "$file" >"${file}.since"
    mv "${file}.since" "$file"
  fi
}

count_pattern() {
  local label="$1"
  local regex="$2"
  local count
  count="$(grep -Eci "$regex" "$snapshot_file" || true)"
  printf '  %-30s %s\n' "$label" "$count"
}

classify_line() {
  local line="$1"
  local severity="INFO"
  local category="RUNTIME"

  if [[ "$line" == *"ERROR"* ]] || [[ "$line" == *"level\":50"* ]] || [[ "$line" == *"level=error"* ]]; then
    severity="ERROR"
  elif [[ "$line" == *"WARN"* ]] || [[ "$line" == *"level\":40"* ]] || [[ "$line" == *"level=warn"* ]]; then
    severity="WARN"
  fi

  if [[ "$line" =~ Stream[[:space:]]Errored[[:space:]]\(conflict\)|\"tag\":\ \"conflict\"|type\":\ \"replaced\" ]]; then
    category="WA_CONFLICT"
  elif [[ "$line" =~ dispatch[[:space:]_-]*block|invalid[[:space:]]dispatch[[:space:]]payload|worker[[:space:]]dispatch[[:space:]]ownership[[:space:]]violation ]]; then
    category="DISPATCH_BLOCK"
  elif [[ "$line" =~ Container[[:space:]]exited[[:space:]]with[[:space:]]error|code[[:space:]]137 ]]; then
    category="CONTAINER_EXIT_137"
  elif [[ "$line" =~ SqliteError|no[[:space:]]such[[:space:]]column:[[:space:]]dispatch_repo ]]; then
    category="SCHEMA_ERROR"
  elif [[ "$line" =~ running_without_container|Auto-failed[[:space:]]running[[:space:]]worker[[:space:]]run[[:space:]]with[[:space:]]no[[:space:]]container ]]; then
    category="RUNNING_WITHOUT_CONTAINER"
  elif [[ "$line" =~ New[[:space:]]messages|Processing[[:space:]]messages|Spawning[[:space:]]container[[:space:]]agent|Message[[:space:]]sent|IPC[[:space:]]message[[:space:]]sent ]]; then
    category="MESSAGE_PATH"
  fi

  if [ "$JSON_STREAM" -eq 1 ]; then
    python3 - "$severity" "$category" "$line" <<'PY'
import json
import sys
sev, cat, line = sys.argv[1:4]
print(json.dumps({"severity": sev, "category": cat, "line": line}, ensure_ascii=True))
PY
  else
    echo "[$severity][$category] $line"
  fi
}

apply_filters "$snapshot_file"

echo "== Jarvis Watch =="
echo "file: $LOG_FILE"
echo "window: last $LINES lines"
[ -n "$LANE_FILTER" ] && echo "lane filter: $LANE_FILTER"
[ -n "$since_time" ] && echo "since time (best effort): $since_time"
echo "Summary counts:"
count_pattern "errors" "ERROR|\\\"level\\\":50|level=error"
count_pattern "warnings" "WARN|\\\"level\\\":40|level=warn"
count_pattern "wa conflicts" "Stream Errored \\(conflict\\)|\\\"tag\\\": \\\"conflict\\\"|type\\\": \\\"replaced\\\""
count_pattern "dispatch blocks" "dispatch[ _-]*block|invalid dispatch payload|worker dispatch ownership violation"
count_pattern "container exit 137" "Container exited with error|code 137"
count_pattern "schema errors" "SqliteError|no such column: dispatch_repo"
count_pattern "running without container" "running_without_container|Auto-failed running worker run with no container"
count_pattern "message path events" "New messages|Processing messages|Spawning container agent|Message sent|IPC message sent"

if [ "$FOLLOW" -eq 0 ]; then
  exit 0
fi

echo
echo "Following log (Ctrl+C to stop)..."

if [ -n "$LANE_FILTER" ] || [ -n "$since_time" ]; then
  tail -n "$LINES" -F "$LOG_FILE" | while IFS= read -r line; do
    if [ -n "$LANE_FILTER" ]; then
      if ! printf '%s\n' "$line" | rg -qi "$LANE_FILTER"; then
        continue
      fi
    fi
    if [ -n "$since_time" ]; then
      ts="$(printf '%s\n' "$line" | sed -nE 's/^\[([0-9]{2}:[0-9]{2}:[0-9]{2})\..*/\1/p')"
      if [ -n "$ts" ] && [[ "$ts" < "$since_time" ]]; then
        continue
      fi
    fi
    classify_line "$line"
  done
else
  tail -n "$LINES" -F "$LOG_FILE" | while IFS= read -r line; do
    classify_line "$line"
  done
fi
