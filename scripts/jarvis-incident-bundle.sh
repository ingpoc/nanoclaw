#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DB_PATH="${DB_PATH:-$ROOT_DIR/store/messages.db}"
LOG_PATH="${LOG_PATH:-$ROOT_DIR/logs/nanoclaw.log}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/data/diagnostics/incidents}"
INCIDENT_REGISTRY="${INCIDENT_REGISTRY:-$ROOT_DIR/.claude/progress/incident.json}"
WINDOW_MINUTES="${WINDOW_MINUTES:-180}"
LOG_LINES="${LOG_LINES:-2500}"
LANE=""
CHAT_JID=""
RUN_ID=""
INCIDENT_ID=""
INCIDENT_TITLE=""
TRACK=0
FORCE_TRACK=0
NO_TRACK=0
NO_ARCHIVE=0
JSON_MODE=0
JSON_OUT=""

usage() {
  cat <<'USAGE'
Usage: scripts/jarvis-incident-bundle.sh [options]

Collect a timestamped diagnostics bundle for a NanoClaw/Jarvis incident.

Options:
  --out-dir <path>         Output folder root (default: data/diagnostics/incidents)
  --incident-registry <p>  Incident registry JSON path (default: .claude/progress/incident.json)
  --incident-id <id>       Incident id for tracked mode (reuse/append)
  --title <text>           Incident title for new incident records
  --track                  Force tracking even without --incident-id
  --window-minutes <n>     Window passed to status/hotspots/reliability (default: 180)
  --log-lines <n>          Number of log lines to capture (default: 2500)
  --lane <folder>          Optional lane for trace (e.g. andy-developer)
  --chat-jid <jid>         Optional chat_jid for trace
  --run-id <id>            Optional run_id for trace
  --db <path>              SQLite DB path (default: store/messages.db)
  --log <path>             Runtime log path (default: logs/nanoclaw.log)
  --no-track               Do not update incident registry (overrides --incident-id/--track)
  --no-archive             Skip .tar.gz archive generation
  --json                   Emit manifest JSON to stdout
  --json-out <path>        Write manifest JSON to file
  -h, --help               Show help
USAGE
}

is_pos_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --incident-registry) INCIDENT_REGISTRY="$2"; shift 2 ;;
    --incident-id) INCIDENT_ID="$2"; shift 2 ;;
    --title) INCIDENT_TITLE="$2"; shift 2 ;;
    --track) FORCE_TRACK=1; shift ;;
    --window-minutes) WINDOW_MINUTES="$2"; shift 2 ;;
    --log-lines) LOG_LINES="$2"; shift 2 ;;
    --lane) LANE="$2"; shift 2 ;;
    --chat-jid) CHAT_JID="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --db) DB_PATH="$2"; shift 2 ;;
    --log) LOG_PATH="$2"; shift 2 ;;
    --no-track) NO_TRACK=1; shift ;;
    --no-archive) NO_ARCHIVE=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    --json-out) JSON_OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

for n in "$WINDOW_MINUTES" "$LOG_LINES"; do
  if ! is_pos_int "$n"; then
    echo "Expected positive integer, got: $n"
    exit 1
  fi
done

if [ -n "$INCIDENT_ID" ]; then
  TRACK=1
fi
if [ "$FORCE_TRACK" -eq 1 ]; then
  TRACK=1
fi
if [ "$NO_TRACK" -eq 1 ]; then
  TRACK=0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
bundle_id="incident-${timestamp}"
bundle_dir="$OUT_DIR/$bundle_id"
mkdir -p "$bundle_dir/commands" "$bundle_dir/logs" "$bundle_dir/db" "$bundle_dir/artifacts"

status_file="$bundle_dir/commands/status.tsv"
touch "$status_file"

run_capture() {
  local name="$1"
  shift
  local out="$bundle_dir/commands/${name}.txt"
  set +e
  "$@" >"$out" 2>&1
  local rc=$?
  set -e
  printf '%s\t%s\t%s\n' "$name" "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$status_file"
  echo "  - $name: exit=$rc"
  return 0
}

echo "== Jarvis Incident Bundle =="
echo "bundle: $bundle_dir"
echo "window: ${WINDOW_MINUTES}m"
echo "log lines: $LOG_LINES"
[ "$TRACK" -eq 1 ] && echo "incident registry: $INCIDENT_REGISTRY"
[ "$TRACK" -eq 0 ] && echo "incident tracking: disabled (debug-only bundle)"
[ -n "$LANE" ] && echo "lane: $LANE"
[ -n "$CHAT_JID" ] && echo "chat_jid: $CHAT_JID"
[ -n "$RUN_ID" ] && echo "run_id: $RUN_ID"
[ -n "$INCIDENT_ID" ] && echo "incident id: $INCIDENT_ID"
[ -n "$INCIDENT_TITLE" ] && echo "incident title: $INCIDENT_TITLE"

echo
echo "Collecting command snapshots:"
run_capture "preflight" scripts/jarvis-preflight.sh \
  --db "$DB_PATH" \
  --log "$LOG_PATH" \
  --json-out "$bundle_dir/commands/preflight.json"
run_capture "status" scripts/jarvis-status.sh \
  --db "$DB_PATH" \
  --window-minutes "$WINDOW_MINUTES" \
  --json-out "$bundle_dir/commands/status.json"
run_capture "reliability" scripts/jarvis-reliability.sh \
  --db "$DB_PATH" \
  --log "$LOG_PATH" \
  --window-minutes "$WINDOW_MINUTES" \
  --tail-lines "$LOG_LINES"
hotspots_window_hours="$(( (WINDOW_MINUTES + 59) / 60 ))"
run_capture "db-doctor" scripts/jarvis-db-doctor.sh \
  --db "$DB_PATH" \
  --json-out "$bundle_dir/commands/db-doctor.json"
run_capture "hotspots" scripts/jarvis-hotspots.sh \
  --db "$DB_PATH" \
  --log "$LOG_PATH" \
  --window-hours "$hotspots_window_hours" \
  --log-lines "$LOG_LINES" \
  --json-out "$bundle_dir/commands/hotspots.json"

if [ -n "$LANE" ] || [ -n "$CHAT_JID" ] || [ -n "$RUN_ID" ]; then
  trace_args=(scripts/jarvis-trace.sh --db "$DB_PATH" --log "$LOG_PATH" --window-minutes "$WINDOW_MINUTES" --log-lines "$LOG_LINES" --json-out "$bundle_dir/commands/trace.json")
  [ -n "$LANE" ] && trace_args+=(--lane "$LANE")
  [ -n "$CHAT_JID" ] && trace_args+=(--chat-jid "$CHAT_JID")
  [ -n "$RUN_ID" ] && trace_args+=(--run-id "$RUN_ID")
  run_capture "trace" "${trace_args[@]}"
fi

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "cwd=$ROOT_DIR"
  echo "db_path=$DB_PATH"
  echo "log_path=$LOG_PATH"
  echo "lane=$LANE"
  echo "chat_jid=$CHAT_JID"
  echo "run_id=$RUN_ID"
  echo "window_minutes=$WINDOW_MINUTES"
  echo "log_lines=$LOG_LINES"
} >"$bundle_dir/context.env"

{
  echo "# system"
  date -u +%Y-%m-%dT%H:%M:%SZ
  uname -a
  echo
  echo "# tool versions"
  command -v node >/dev/null 2>&1 && node -v || true
  command -v npm >/dev/null 2>&1 && npm -v || true
  command -v sqlite3 >/dev/null 2>&1 && sqlite3 --version || true
  command -v container >/dev/null 2>&1 && container --version || true
  echo
  echo "# git"
  git rev-parse HEAD
  git status --short
} >"$bundle_dir/system.txt" 2>&1

if command -v launchctl >/dev/null 2>&1; then
  (launchctl list | rg nanoclaw || true) >"$bundle_dir/launchctl-nanoclaw.txt"
fi

if command -v container >/dev/null 2>&1; then
  (container system status || true) >"$bundle_dir/container-system-status.txt" 2>&1
  (container builder status || true) >"$bundle_dir/container-builder-status.txt" 2>&1
  (container ls -a || true) >"$bundle_dir/container-ls-a.txt" 2>&1
fi

if [ -f "$LOG_PATH" ]; then
  tail -n "$LOG_LINES" "$LOG_PATH" >"$bundle_dir/logs/nanoclaw.tail.log" 2>/dev/null || true
fi

if [ -f "$DB_PATH" ] && command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$DB_PATH" ".schema worker_runs" >"$bundle_dir/db/worker_runs.schema.sql" 2>/dev/null || true
  sqlite3 "$DB_PATH" ".schema registered_groups" >"$bundle_dir/db/registered_groups.schema.sql" 2>/dev/null || true

  sqlite3 -header -separator '|' "$DB_PATH" "
SELECT run_id, group_folder, status, started_at, completed_at,
       dispatch_repo, dispatch_branch, context_intent,
       dispatch_session_id, selected_session_id, effective_session_id
FROM worker_runs
ORDER BY started_at DESC
LIMIT 200;
" >"$bundle_dir/db/worker_runs_recent.tsv" 2>/dev/null || true

  sqlite3 -header -separator '|' "$DB_PATH" "
SELECT folder, jid, name
FROM registered_groups
ORDER BY folder;
" >"$bundle_dir/db/registered_groups.tsv" 2>/dev/null || true
fi

error_artifacts_dir="$ROOT_DIR/data/ipc/errors"
if [ -d "$error_artifacts_dir" ]; then
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    cp "$artifact" "$bundle_dir/artifacts/" 2>/dev/null || true
  done < <(ls -1t "$error_artifacts_dir"/dispatch-block-*.json 2>/dev/null | head -n 30)
fi

archive_path=""
if [ "$NO_ARCHIVE" -eq 0 ]; then
  archive_path="${bundle_dir}.tar.gz"
  tar -czf "$archive_path" -C "$OUT_DIR" "$bundle_id"
fi

manifest_json="$(python3 - "$bundle_dir" "$archive_path" "$status_file" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

bundle_dir, archive_path, status_path = sys.argv[1:4]
commands = []
non_zero = 0
if os.path.isfile(status_path):
    with open(status_path, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            name, rc, ts = parts[:3]
            rc_i = int(rc)
            if rc_i != 0:
                non_zero += 1
            commands.append({"name": name, "exit_code": rc_i, "timestamp": ts})

manifest = {
    "script": "jarvis-incident-bundle",
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "bundle_dir": bundle_dir,
    "archive_path": archive_path or None,
    "overall_status": "warn" if non_zero > 0 else "pass",
    "commands": commands,
    "non_zero_command_count": non_zero,
}
print(json.dumps(manifest, ensure_ascii=True, indent=2))
PY
)"

printf '%s\n' "$manifest_json" >"$bundle_dir/manifest.json"

tracking_payload=""
if [ "$TRACK" -eq 1 ]; then
  register_args=(
    scripts/jarvis-incident.sh
    --registry "$INCIDENT_REGISTRY"
    register-bundle
    --bundle-dir "$bundle_dir"
    --manifest "$bundle_dir/manifest.json"
    --json
  )
  [ -n "$INCIDENT_ID" ] && register_args+=(--incident-id "$INCIDENT_ID")
  [ -n "$INCIDENT_TITLE" ] && register_args+=(--title "$INCIDENT_TITLE")
  [ -n "$LANE" ] && register_args+=(--lane "$LANE")
  [ -n "$CHAT_JID" ] && register_args+=(--chat-jid "$CHAT_JID")
  [ -n "$RUN_ID" ] && register_args+=(--run-id "$RUN_ID")

  tracking_payload="$("${register_args[@]}")"
  printf '%s\n' "$tracking_payload" >"$bundle_dir/commands/incident-register.json"

  manifest_json="$(python3 - "$manifest_json" "$tracking_payload" <<'PY'
import json
import sys
manifest = json.loads(sys.argv[1])
tracking = json.loads(sys.argv[2])
manifest["incident_tracking"] = {
    "registry": tracking.get("registry"),
    "incident_id": tracking.get("incident_id"),
    "status": tracking.get("status"),
    "created": tracking.get("created"),
    "reopened": tracking.get("reopened"),
    "occurrence_count": tracking.get("occurrence_count"),
    "root_cause": tracking.get("root_cause"),
}
print(json.dumps(manifest, ensure_ascii=True, indent=2))
PY
)"
  printf '%s\n' "$manifest_json" >"$bundle_dir/manifest.json"
fi

echo
echo "Bundle complete."
echo "  - folder: $bundle_dir"
if [ -n "$archive_path" ]; then
  echo "  - archive: $archive_path"
fi
if [ "$TRACK" -eq 1 ]; then
  tracked_id="$(python3 - "$manifest_json" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
print(obj.get("incident_tracking", {}).get("incident_id", ""))
PY
)"
  [ -n "$tracked_id" ] && echo "  - incident id: $tracked_id"
fi

if [ "$JSON_MODE" -eq 1 ]; then
  echo
  echo "$manifest_json"
fi

if [ -n "$JSON_OUT" ]; then
  printf '%s\n' "$manifest_json" >"$JSON_OUT"
fi
