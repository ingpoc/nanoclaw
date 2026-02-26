#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DB_PATH="${DB_PATH:-$ROOT_DIR/store/messages.db}"
WINDOW_MINUTES="${WINDOW_MINUTES:-60}"
RECENT_LIMIT="${RECENT_LIMIT:-10}"
REASON_LIMIT="${REASON_LIMIT:-8}"

usage() {
  cat <<'EOF'
Usage: scripts/jarvis-status.sh [options]

Options:
  --window-minutes <n>  Sliding window in minutes (default: 60).
  --recent-limit <n>    Number of recent runs to print (default: 10).
  --reason-limit <n>    Number of top failure reasons to print (default: 8).
  --db <path>           SQLite DB path (default: store/messages.db).
  -h, --help            Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --window-minutes)
      WINDOW_MINUTES="$2"
      shift 2
      ;;
    --recent-limit)
      RECENT_LIMIT="$2"
      shift 2
      ;;
    --reason-limit)
      REASON_LIMIT="$2"
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

for value in "$WINDOW_MINUTES" "$RECENT_LIMIT" "$REASON_LIMIT"; do
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
    echo "Expected positive integer, got: $value"
    exit 1
  fi
done

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required"
  exit 1
fi

if [ ! -f "$DB_PATH" ]; then
  echo "DB not found: $DB_PATH"
  exit 1
fi

echo "== Jarvis Status =="
echo "db: $DB_PATH"
echo "window: last ${WINDOW_MINUTES}m"

lane_rows="$(sqlite3 -separator '|' "$DB_PATH" "
WITH window_runs AS (
  SELECT *
  FROM worker_runs
  WHERE julianday(started_at) >= julianday('now', '-${WINDOW_MINUTES} minutes')
)
SELECT
  group_folder,
  SUM(CASE WHEN status IN ('review_requested', 'done') THEN 1 ELSE 0 END) AS pass_count,
  SUM(CASE WHEN status IN ('failed', 'failed_contract') THEN 1 ELSE 0 END) AS fail_count,
  SUM(CASE WHEN status IN ('queued', 'running') THEN 1 ELSE 0 END) AS active_count,
  COUNT(*) AS total_count
FROM window_runs
WHERE group_folder LIKE 'jarvis-worker-%'
GROUP BY group_folder
ORDER BY group_folder;
")"

echo
echo "Lane summary:"
if [ -z "$lane_rows" ]; then
  echo "  (no worker runs in current window)"
else
  while IFS='|' read -r lane pass fail active total; do
    [ -z "$lane" ] && continue
    echo "  - $lane: pass=$pass fail=$fail active=$active runs=$total"
  done <<< "$lane_rows"
fi

reason_rows="$(sqlite3 -separator '|' "$DB_PATH" "
WITH window_runs AS (
  SELECT *
  FROM worker_runs
  WHERE julianday(started_at) >= julianday('now', '-${WINDOW_MINUTES} minutes')
),
failed_runs AS (
  SELECT *
  FROM window_runs
  WHERE status IN ('failed', 'failed_contract')
)
SELECT
  COALESCE(
    CASE
      WHEN json_valid(error_details) THEN
        COALESCE(NULLIF(json_extract(error_details, '$.reason'), ''), NULLIF(json_extract(error_details, '$.missing[0]'), ''))
      ELSE NULL
    END,
    NULLIF(result_summary, ''),
    'unknown'
  ) AS reason,
  COUNT(*) AS cnt
FROM failed_runs
GROUP BY reason
ORDER BY cnt DESC, reason
LIMIT ${REASON_LIMIT};
")"

echo
echo "Top failure reasons:"
if [ -z "$reason_rows" ]; then
  echo "  (no failures in current window)"
else
  while IFS='|' read -r reason cnt; do
    [ -z "$reason" ] && continue
    echo "  - $reason: $cnt"
  done <<< "$reason_rows"
fi

recent_rows="$(sqlite3 -separator '|' "$DB_PATH" "
SELECT
  run_id,
  group_folder,
  status,
  started_at,
  COALESCE(result_summary, '')
FROM worker_runs
WHERE julianday(started_at) >= julianday('now', '-${WINDOW_MINUTES} minutes')
ORDER BY started_at DESC
LIMIT ${RECENT_LIMIT};
")"

echo
echo "Recent runs:"
if [ -z "$recent_rows" ]; then
  echo "  (none)"
else
  while IFS='|' read -r run_id lane status started summary; do
    [ -z "$run_id" ] && continue
    if [ -n "$summary" ]; then
      echo "  - $run_id | $lane | $status | $started | $summary"
    else
      echo "  - $run_id | $lane | $status | $started"
    fi
  done <<< "$recent_rows"
fi
