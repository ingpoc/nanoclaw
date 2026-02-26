#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DB_PATH="${DB_PATH:-$ROOT_DIR/store/messages.db}"
TIMEOUT_SEC="${TIMEOUT_SEC:-180}"
POLL_SEC="${POLL_SEC:-2}"
WORKERS_FILTER="${WORKERS_FILTER:-}"

usage() {
  cat <<'EOF'
Usage: scripts/jarvis-worker-probe.sh [options]

Options:
  --workers <csv>  Probe only specific worker folders (example: jarvis-worker-1,jarvis-worker-2).
  --timeout <sec>  Timeout per worker lane (default: 180).
  --poll <sec>     Poll interval in seconds (default: 2).
  --db <path>      SQLite DB path (default: store/messages.db).
  -h, --help       Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workers)
      WORKERS_FILTER="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    --poll)
      POLL_SEC="$2"
      shift 2
      ;;
    --db)
      DB_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

for value in "$TIMEOUT_SEC" "$POLL_SEC"; do
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
    echo "Expected positive integer, got: $value"
    exit 1
  fi
done

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required"
  exit 1
fi

if [ ! -f "$DB_PATH" ]; then
  echo "DB not found: $DB_PATH"
  exit 1
fi

mapfile -t lane_rows < <(
  sqlite3 -separator '|' "$DB_PATH" \
    "SELECT folder, jid FROM registered_groups WHERE folder LIKE 'jarvis-worker-%' ORDER BY folder;"
)

if [ "${#lane_rows[@]}" -eq 0 ]; then
  echo "No jarvis-worker lanes registered."
  exit 1
fi

if [ -n "$WORKERS_FILTER" ]; then
  IFS=',' read -r -a requested_lanes <<< "$WORKERS_FILTER"
  filtered=()
  for lane in "${requested_lanes[@]}"; do
    lane_trimmed="$(echo "$lane" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    for row in "${lane_rows[@]}"; do
      folder="${row%%|*}"
      if [ "$folder" = "$lane_trimmed" ]; then
        filtered+=("$row")
      fi
    done
  done
  lane_rows=("${filtered[@]}")
fi

if [ "${#lane_rows[@]}" -eq 0 ]; then
  echo "No matching worker lanes found for filter: $WORKERS_FILTER"
  exit 1
fi

mkdir -p data/ipc/andy-developer/messages

echo "== Jarvis Worker Probe =="
echo "db: $DB_PATH"
echo "timeout: ${TIMEOUT_SEC}s per lane"
echo "poll: ${POLL_SEC}s"

overall_fail=0
total=0
passed=0

for row in "${lane_rows[@]}"; do
  folder="${row%%|*}"
  jid="${row#*|}"
  total=$((total + 1))

  ts="$(date +%s)"
  run_id="probe-${folder}-${ts}-$RANDOM"
  branch="jarvis-probe-${folder}-${ts}"
  probe_file="work/${folder}-probe-${ts}.txt"
  msg_file="data/ipc/andy-developer/messages/${ts}-${folder}-probe.json"

  RUN_ID="$run_id" \
  BRANCH="$branch" \
  PROBE_FILE="$probe_file" \
  CHAT_JID="$jid" \
  MSG_FILE="$msg_file" \
  node <<'NODE'
const fs = require('fs');

const dispatch = {
  run_id: process.env.RUN_ID,
  task_type: 'test',
  input: `Create file ${process.env.PROBE_FILE} with content "probe-ok". Run acceptance tests. Return exactly one <completion> JSON block. Use commit_sha "deadbeef". Set files_changed to ["${process.env.PROBE_FILE}"].`,
  repo: 'openclaw-gurusharan/nanoclaw',
  branch: process.env.BRANCH,
  acceptance_tests: [
    `test -f ${process.env.PROBE_FILE}`,
    `grep -q probe-ok ${process.env.PROBE_FILE}`,
  ],
  output_contract: {
    required_fields: [
      'run_id',
      'branch',
      'commit_sha',
      'files_changed',
      'test_result',
      'risk',
      'pr_skipped_reason',
    ],
  },
  priority: 'normal',
};

const message = {
  type: 'message',
  chatJid: process.env.CHAT_JID,
  text: JSON.stringify(dispatch),
};

fs.writeFileSync(process.env.MSG_FILE, JSON.stringify(message));
NODE

  echo
  echo "[PROBE] $folder ($jid)"
  echo "  run_id: $run_id"

  deadline=$((SECONDS + TIMEOUT_SEC))
  terminal=""
  result_line=""

  while [ "$SECONDS" -lt "$deadline" ]; do
    result_line="$(sqlite3 -separator '|' "$DB_PATH" "
      SELECT
        status,
        COALESCE(result_summary, ''),
        CASE
          WHEN json_valid(error_details) THEN
            COALESCE(NULLIF(json_extract(error_details, '$.reason'), ''), NULLIF(json_extract(error_details, '$.missing[0]'), ''))
          ELSE ''
        END,
        COALESCE(branch_name, ''),
        COALESCE(commit_sha, '')
      FROM worker_runs
      WHERE run_id='${run_id}'
      LIMIT 1;
    ")"

    if [ -n "$result_line" ]; then
      IFS='|' read -r status summary reason branch_name commit_sha <<< "$result_line"
      case "$status" in
        review_requested|done|failed|failed_contract)
          terminal="$status"
          break
          ;;
      esac
    fi

    sleep "$POLL_SEC"
  done

  if [ -z "$terminal" ]; then
    echo "  result: FAIL (timeout waiting for terminal status)"
    overall_fail=1
    continue
  fi

  if [ "$terminal" = "review_requested" ] || [ "$terminal" = "done" ]; then
    echo "  result: PASS ($terminal)"
    [ -n "${branch_name:-}" ] && echo "  branch: $branch_name"
    [ -n "${commit_sha:-}" ] && echo "  commit_sha: $commit_sha"
    passed=$((passed + 1))
  else
    error_hint="${reason:-${summary:-unknown}}"
    echo "  result: FAIL ($terminal)"
    echo "  reason: $error_hint"
    overall_fail=1
  fi
done

echo
echo "Probe summary: pass=$passed total=$total"
if [ "$overall_fail" -ne 0 ]; then
  exit 1
fi
