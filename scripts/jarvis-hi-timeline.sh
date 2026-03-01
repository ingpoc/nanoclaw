#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DB_PATH="${DB_PATH:-$ROOT_DIR/store/messages.db}"
LOG_PATH="${LOG_PATH:-$ROOT_DIR/logs/nanoclaw.log}"
LANE="andy-developer"
CHAT_JID=""
MESSAGE_ID=""
TEXT=""
MATCH_MODE="exact"
NTH="1"
WINDOW_MINUTES="360"
BEFORE_SECONDS="30"
AFTER_MINUTES="20"
LOG_LINES="20000"
SINCE=""
UNTIL=""
JSON_MODE=0
JSON_OUT=""

usage() {
  cat <<'USAGE'
Usage: scripts/jarvis-hi-timeline.sh [options]

Build an event timeline anchored on a specific user message in Andy-Developer.
If neither --message-id nor --text is provided, it anchors on the latest user message.

Options:
  --lane <folder>           Lane folder (default: andy-developer)
  --chat-jid <jid>          Chat JID override (instead of resolving lane)
  --message-id <id>         Exact message ID to anchor
  --text <value>            Message text filter for anchor (optional)
  --match <mode>            Match mode: exact|contains|regex (default: exact)
  --nth <n>                 Choose nth latest candidate (default: 1)
  --window-minutes <n>      Anchor search window if --since omitted (default: 360)
  --before-seconds <n>      Timeline window before anchor (default: 30)
  --after-minutes <n>       Timeline window after anchor (default: 20)
  --since <iso>             Anchor search lower bound (UTC ISO)
  --until <iso>             Anchor search upper bound (UTC ISO; default: now)
  --log-lines <n>           Log tail lines to scan (default: 20000)
  --db <path>               SQLite DB path (default: store/messages.db)
  --log <path>              Runtime log path (default: logs/nanoclaw.log)
  --json                    Emit full JSON timeline
  --json-out <path>         Write JSON payload to file
  -h, --help                Show help
USAGE
}

is_pos_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane) LANE="$2"; shift 2 ;;
    --chat-jid) CHAT_JID="$2"; shift 2 ;;
    --message-id) MESSAGE_ID="$2"; shift 2 ;;
    --text) TEXT="$2"; shift 2 ;;
    --match) MATCH_MODE="$2"; shift 2 ;;
    --nth) NTH="$2"; shift 2 ;;
    --window-minutes) WINDOW_MINUTES="$2"; shift 2 ;;
    --before-seconds) BEFORE_SECONDS="$2"; shift 2 ;;
    --after-minutes) AFTER_MINUTES="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    --log-lines) LOG_LINES="$2"; shift 2 ;;
    --db) DB_PATH="$2"; shift 2 ;;
    --log) LOG_PATH="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --json-out) JSON_OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if ! is_pos_int "$NTH"; then
  echo "Invalid --nth: $NTH"
  exit 1
fi
if ! is_pos_int "$WINDOW_MINUTES"; then
  echo "Invalid --window-minutes: $WINDOW_MINUTES"
  exit 1
fi
if ! is_pos_int "$BEFORE_SECONDS"; then
  echo "Invalid --before-seconds: $BEFORE_SECONDS"
  exit 1
fi
if ! is_pos_int "$AFTER_MINUTES"; then
  echo "Invalid --after-minutes: $AFTER_MINUTES"
  exit 1
fi
if ! is_pos_int "$LOG_LINES"; then
  echo "Invalid --log-lines: $LOG_LINES"
  exit 1
fi
if [[ "$MATCH_MODE" != "exact" && "$MATCH_MODE" != "contains" && "$MATCH_MODE" != "regex" ]]; then
  echo "Invalid --match: $MATCH_MODE (expected exact|contains|regex)"
  exit 1
fi

if [ ! -f "$DB_PATH" ]; then
  echo "DB not found: $DB_PATH"
  exit 1
fi

if [ -z "$SINCE" ]; then
  SINCE="$(python3 - "$WINDOW_MINUTES" <<'PY'
import datetime
import sys
mins = int(sys.argv[1])
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=mins)).isoformat())
PY
)"
fi

if [ -z "$UNTIL" ]; then
  UNTIL="$(python3 <<'PY'
import datetime
print(datetime.datetime.now(datetime.timezone.utc).isoformat())
PY
)"
fi

timeline_json="$(python3 - "$DB_PATH" "$LOG_PATH" "$LANE" "$CHAT_JID" "$MESSAGE_ID" "$TEXT" "$MATCH_MODE" "$NTH" "$SINCE" "$UNTIL" "$BEFORE_SECONDS" "$AFTER_MINUTES" "$LOG_LINES" <<'PY'
import datetime
import json
import os
import re
import sqlite3
import sys

(
    db_path,
    log_path,
    lane,
    chat_jid,
    message_id,
    text_query,
    match_mode,
    nth_raw,
    since_raw,
    until_raw,
    before_seconds_raw,
    after_minutes_raw,
    log_lines_raw,
) = sys.argv[1:14]

nth = int(nth_raw)
before_seconds = int(before_seconds_raw)
after_minutes = int(after_minutes_raw)
log_lines = int(log_lines_raw)

ansi_re = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")
log_time_re = re.compile(r"^\[(\d{2}):(\d{2}):(\d{2})\.(\d{3})\]")
pid_re = re.compile(r"\((\d+)\):")

keywords = [
    "Shutdown signal received",
    "Database initialized",
    "State loaded",
    "Connected to WhatsApp",
    "Scheduler loop started",
    "Worker progress poller started",
    "IPC watcher started",
    "Recovery: found unprocessed messages",
    "NanoClaw running",
    "New messages",
    "Processing messages",
    "Spawning container agent",
    "Worker dispatch queued",
    "Worker run queued from worker chat context",
    "Worker run marked running after container spawn",
    "Skipping duplicate worker run execution",
    "Auto-failed queued worker run before spawn",
    "Auto-failed running worker run with no container",
    "Ignored invalid worker status transition",
    "Worker completion contract accepted",
    "Agent output:",
    "Message sent",
    "Container timed out with no output",
    "Container completed (streaming mode)",
]


def parse_iso(value: str | None) -> datetime.datetime | None:
    if not value:
        return None
    try:
        dt = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def dt_to_iso(dt: datetime.datetime | None) -> str | None:
    if dt is None:
        return None
    return dt.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", (value or "").strip()).lower()


def preview(value: str, limit: int = 140) -> str:
    text = re.sub(r"\s+", " ", (value or "").strip())
    return text[:limit]


def parse_reason(error_details: str | None) -> str | None:
    if not error_details:
        return None
    try:
        parsed = json.loads(error_details)
    except Exception:
        return None
    if isinstance(parsed, dict):
        reason = parsed.get("reason")
        if isinstance(reason, str) and reason:
            return reason
    return None


since_dt = parse_iso(since_raw)
until_dt = parse_iso(until_raw)
now_utc = datetime.datetime.now(datetime.timezone.utc)
if since_dt is None:
    since_dt = now_utc - datetime.timedelta(hours=6)
if until_dt is None:
    until_dt = now_utc
if until_dt < since_dt:
    since_dt, until_dt = until_dt, since_dt

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

resolved_chat = chat_jid
if lane and not resolved_chat:
    cur.execute("SELECT jid FROM registered_groups WHERE folder = ? LIMIT 1", (lane,))
    row = cur.fetchone()
    if row:
        resolved_chat = row["jid"]

resolved_lane = lane
if resolved_chat and not resolved_lane:
    cur.execute("SELECT folder FROM registered_groups WHERE jid = ? LIMIT 1", (resolved_chat,))
    row = cur.fetchone()
    if row:
        resolved_lane = row["folder"]

if not resolved_chat:
    payload = {
        "error": "chat_not_resolved",
        "message": "Could not resolve chat_jid from lane; provide --chat-jid.",
        "inputs": {
            "lane": lane or None,
            "chat_jid": chat_jid or None,
        },
    }
    print(json.dumps(payload, ensure_ascii=True))
    sys.exit(0)

cur.execute(
    """
    SELECT id, chat_jid, sender, sender_name, content, timestamp, is_bot_message
    FROM messages
    WHERE chat_jid = ?
      AND is_bot_message = 0
      AND timestamp >= ?
      AND timestamp <= ?
    ORDER BY timestamp DESC
    LIMIT 1200
    """,
    (resolved_chat, since_dt.isoformat(), until_dt.isoformat()),
)
user_rows = [dict(r) for r in cur.fetchall()]

pattern = None
if match_mode == "regex":
    try:
        pattern = re.compile(text_query, flags=re.IGNORECASE)
    except re.error as exc:
        payload = {
            "error": "invalid_regex",
            "message": str(exc),
            "inputs": {"text": text_query, "match_mode": match_mode},
        }
        print(json.dumps(payload, ensure_ascii=True))
        sys.exit(0)

anchor = None
anchor_mode = "latest_user"
anchor_candidates = []

if message_id:
    cur.execute(
        """
        SELECT id, chat_jid, sender, sender_name, content, timestamp, is_bot_message
        FROM messages
        WHERE chat_jid = ?
          AND id = ?
          AND is_bot_message = 0
        LIMIT 1
        """,
        (resolved_chat, message_id),
    )
    row = cur.fetchone()
    if row:
        anchor = dict(row)
        anchor_mode = "message_id"
else:
    text_norm = normalize_text(text_query)
    if text_norm:
        for row in user_rows:
            content = row.get("content") or ""
            content_norm = normalize_text(content)
            matched = False
            if match_mode == "exact":
                matched = content_norm == text_norm
            elif match_mode == "contains":
                matched = text_norm in content_norm
            elif pattern is not None:
                matched = bool(pattern.search(content))
            if matched:
                anchor_candidates.append(row)
        if len(anchor_candidates) >= nth:
            anchor = anchor_candidates[nth - 1]
            anchor_mode = "text_match"
    else:
        if len(user_rows) >= nth:
            anchor = user_rows[nth - 1]
            anchor_mode = "latest_user"

if anchor is None:
    cur.execute(
        """
        SELECT id, timestamp, sender_name, content
        FROM messages
        WHERE chat_jid = ?
          AND is_bot_message = 0
        ORDER BY timestamp DESC
        LIMIT 8
        """,
        (resolved_chat,),
    )
    recent = [dict(r) for r in cur.fetchall()]
    if message_id:
        reason_text = f"No user message found with id='{message_id}' in chat."
    elif normalize_text(text_query):
        reason_text = f"No matching message found for text='{text_query}' (mode={match_mode}, nth={nth}) in search window."
    else:
        reason_text = f"No user message found for nth={nth} in search window."
    payload = {
        "error": "anchor_not_found",
        "message": reason_text,
        "inputs": {
            "lane": resolved_lane or lane or None,
            "chat_jid": resolved_chat,
            "message_id": message_id or None,
            "text": text_query or None,
            "match_mode": match_mode,
            "nth": nth,
            "since": dt_to_iso(since_dt),
            "until": dt_to_iso(until_dt),
        },
        "recent_user_messages": [
            {
                "id": r["id"],
                "timestamp": r["timestamp"],
                "sender_name": r.get("sender_name"),
                "content_preview": preview(r.get("content") or "", 120),
            }
            for r in recent
        ],
    }
    print(json.dumps(payload, ensure_ascii=True))
    sys.exit(0)

anchor_ts = parse_iso(anchor.get("timestamp"))
if anchor_ts is None:
    payload = {
        "error": "invalid_anchor_timestamp",
        "message": f"Anchor message timestamp is invalid: {anchor.get('timestamp')}",
        "anchor": anchor,
    }
    print(json.dumps(payload, ensure_ascii=True))
    sys.exit(0)

window_start = anchor_ts - datetime.timedelta(seconds=before_seconds)
window_end = anchor_ts + datetime.timedelta(minutes=after_minutes)

cur.execute(
    """
    SELECT id, chat_jid, sender, sender_name, content, timestamp, is_bot_message
    FROM messages
    WHERE chat_jid = ?
      AND timestamp >= ?
      AND timestamp <= ?
    ORDER BY timestamp ASC
    """,
    (resolved_chat, window_start.isoformat(), window_end.isoformat()),
)
window_chat_rows = [dict(r) for r in cur.fetchall()]

cur.execute(
    """
    SELECT message_id, run_id, processed_at
    FROM processed_messages
    WHERE chat_jid = ? AND message_id = ?
    LIMIT 1
    """,
    (resolved_chat, anchor["id"]),
)
processed_row = cur.fetchone()
processed = dict(processed_row) if processed_row else None

cur.execute(
    """
    SELECT run_id, group_folder, status, phase, started_at, completed_at,
           result_summary, error_details, dispatch_repo, dispatch_branch, context_intent
    FROM worker_runs
    WHERE group_folder LIKE 'jarvis-worker-%'
      AND (
        (started_at >= ? AND started_at <= ?)
        OR
        (completed_at IS NOT NULL AND completed_at >= ? AND completed_at <= ?)
      )
    ORDER BY started_at ASC
    LIMIT 300
    """,
    (
        window_start.isoformat(),
        window_end.isoformat(),
        window_start.isoformat(),
        window_end.isoformat(),
    ),
)
worker_runs = [dict(r) for r in cur.fetchall()]

log_events = []
if os.path.isfile(log_path):
    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    tail = lines[-log_lines:] if log_lines > 0 else lines
    anchor_date = anchor_ts.astimezone(datetime.timezone.utc).date()
    center = anchor_ts

    for idx, raw in enumerate(tail):
        clean = ansi_re.sub("", raw.rstrip("\n"))
        m = log_time_re.match(clean)
        if not m:
            continue
        hh, mm, ss, ms = (int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)))
        candidates = []
        for day_offset in (-1, 0, 1):
            d = anchor_date + datetime.timedelta(days=day_offset)
            cand = datetime.datetime(
                d.year, d.month, d.day, hh, mm, ss, ms * 1000, tzinfo=datetime.timezone.utc
            )
            candidates.append(cand)
        event_ts = min(candidates, key=lambda dt: abs((dt - center).total_seconds()))
        if event_ts < window_start or event_ts > window_end:
            continue
        text_after = clean
        if "): " in clean:
            text_after = clean.split("): ", 1)[1]
        keep = any(k in text_after for k in keywords)
        if not keep:
            continue
        pid_match = pid_re.search(clean)
        log_events.append(
            {
                "ts": dt_to_iso(event_ts),
                "source": "log",
                "kind": "log_event",
                "detail": {
                    "pid": pid_match.group(1) if pid_match else None,
                    "line": text_after,
                },
            }
        )

events = []
events.append(
    {
        "ts": anchor["timestamp"],
        "source": "db",
        "kind": "anchor_user_message",
        "detail": {
            "id": anchor["id"],
            "sender_name": anchor.get("sender_name"),
            "content": preview(anchor.get("content") or "", 240),
        },
    }
)

for row in window_chat_rows:
    if row["id"] == anchor["id"]:
        continue
    kind = "chat_bot_message" if row.get("is_bot_message") else "chat_user_message"
    events.append(
        {
            "ts": row["timestamp"],
            "source": "db",
            "kind": kind,
            "detail": {
                "id": row["id"],
                "sender_name": row.get("sender_name"),
                "content": preview(row.get("content") or "", 220),
            },
        }
    )

if processed:
    events.append(
        {
            "ts": processed.get("processed_at"),
            "source": "db",
            "kind": "anchor_marked_processed",
            "detail": {
                "message_id": processed.get("message_id"),
                "run_id": processed.get("run_id"),
            },
        }
    )

for run in worker_runs:
    start_reason = parse_reason(run.get("error_details"))
    events.append(
        {
            "ts": run.get("started_at"),
            "source": "db",
            "kind": "worker_run_started",
            "detail": {
                "run_id": run.get("run_id"),
                "group_folder": run.get("group_folder"),
                "status": run.get("status"),
                "phase": run.get("phase"),
                "dispatch_repo": run.get("dispatch_repo"),
                "dispatch_branch": run.get("dispatch_branch"),
                "reason": start_reason,
            },
        }
    )
    if run.get("completed_at"):
        events.append(
            {
                "ts": run.get("completed_at"),
                "source": "db",
                "kind": "worker_run_completed",
                "detail": {
                    "run_id": run.get("run_id"),
                    "group_folder": run.get("group_folder"),
                    "status": run.get("status"),
                    "phase": run.get("phase"),
                    "reason": start_reason,
                },
            }
        )

events.extend(log_events)


def sort_key(ev):
    ts = parse_iso(ev.get("ts"))
    return (ts or datetime.datetime.min.replace(tzinfo=datetime.timezone.utc), ev.get("source", ""), ev.get("kind", ""))


events = sorted(events, key=sort_key)

anchor_reply = None
for row in window_chat_rows:
    if row.get("is_bot_message") and parse_iso(row.get("timestamp")) and parse_iso(row.get("timestamp")) >= anchor_ts:
        anchor_reply = row
        break

first_processing_log = next(
    (
        ev
        for ev in events
        if ev.get("source") == "log"
        and "Processing messages" in (ev.get("detail", {}).get("line") or "")
        and parse_iso(ev.get("ts"))
        and parse_iso(ev.get("ts")) >= anchor_ts
    ),
    None,
)
first_spawn_log = next(
    (
        ev
        for ev in events
        if ev.get("source") == "log"
        and "Spawning container agent" in (ev.get("detail", {}).get("line") or "")
        and parse_iso(ev.get("ts"))
        and parse_iso(ev.get("ts")) >= anchor_ts
    ),
    None,
)


def delta_ms(ts_value):
    dt = parse_iso(ts_value)
    if dt is None:
        return None
    return int((dt - anchor_ts).total_seconds() * 1000)


for ev in events:
    ev["delta_ms_from_anchor"] = delta_ms(ev.get("ts"))

summary = {
    "anchor_message_id": anchor["id"],
    "anchor_timestamp": anchor["timestamp"],
    "anchor_mode": anchor_mode,
    "anchor_text": preview(anchor.get("content") or "", 120),
    "window_start": dt_to_iso(window_start),
    "window_end": dt_to_iso(window_end),
    "time_to_first_processing_log_ms": delta_ms(first_processing_log.get("ts")) if first_processing_log else None,
    "time_to_first_spawn_log_ms": delta_ms(first_spawn_log.get("ts")) if first_spawn_log else None,
    "time_to_first_bot_reply_ms": delta_ms(anchor_reply.get("timestamp")) if anchor_reply else None,
    "time_to_mark_processed_ms": delta_ms(processed.get("processed_at")) if processed else None,
    "worker_runs_seen": len(worker_runs),
    "chat_messages_seen": len(window_chat_rows),
    "log_events_seen": len(log_events),
}

payload = {
    "script": "jarvis-message-timeline",
    "generated_at": dt_to_iso(datetime.datetime.now(datetime.timezone.utc)),
    "inputs": {
        "lane": lane or None,
        "chat_jid": chat_jid or None,
        "resolved_lane": resolved_lane or None,
        "resolved_chat_jid": resolved_chat,
        "message_id": message_id or None,
        "text": text_query or None,
        "match_mode": match_mode,
        "nth": nth,
        "since": dt_to_iso(since_dt),
        "until": dt_to_iso(until_dt),
        "before_seconds": before_seconds,
        "after_minutes": after_minutes,
        "log_lines": log_lines,
    },
    "summary": summary,
    "events": events,
}

print(json.dumps(payload, ensure_ascii=True))
PY
)"

if python3 - "$timeline_json" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
sys.exit(0 if "error" not in obj else 1)
PY
then
  :
else
  python3 - "$timeline_json" <<'PY'
import json
import sys
obj = json.loads(sys.argv[1])
print("== Jarvis Message Timeline ==")
print(f"error: {obj.get('error')}")
print(obj.get("message", ""))
recent = obj.get("recent_user_messages") or []
if recent:
    print("recent user messages:")
    for item in recent:
      print(f"  - {item.get('timestamp')} | {item.get('id')} | {item.get('content_preview')}")
PY
  exit 1
fi

echo "== Jarvis Message Timeline =="
python3 - "$timeline_json" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
summary = obj.get("summary", {})
inputs = obj.get("inputs", {})
events = obj.get("events", [])

def format_delta(ms):
    if ms is None:
        return "n/a"
    sign = "+" if ms >= 0 else "-"
    ms_abs = abs(ms)
    sec = ms_abs / 1000.0
    return f"{sign}{sec:.3f}s"

print(f"lane: {inputs.get('resolved_lane')}")
print(f"chat_jid: {inputs.get('resolved_chat_jid')}")
print(f"anchor: {summary.get('anchor_timestamp')} | id={summary.get('anchor_message_id')} | text={summary.get('anchor_text')}")
print(f"anchor mode: {summary.get('anchor_mode')}")
print(f"window: {summary.get('window_start')} -> {summary.get('window_end')}")
print("latency:")
print(f"  - to Processing messages log: {format_delta(summary.get('time_to_first_processing_log_ms'))}")
print(f"  - to Spawning container log: {format_delta(summary.get('time_to_first_spawn_log_ms'))}")
print(f"  - to first bot reply: {format_delta(summary.get('time_to_first_bot_reply_ms'))}")
print(f"  - to anchor marked processed: {format_delta(summary.get('time_to_mark_processed_ms'))}")
print("counts:")
print(f"  - chat messages in window: {summary.get('chat_messages_seen')}")
print(f"  - worker runs in window: {summary.get('worker_runs_seen')}")
print(f"  - log milestones in window: {summary.get('log_events_seen')}")
print("timeline:")
for ev in events:
    delta = format_delta(ev.get("delta_ms_from_anchor"))
    ts = ev.get("ts")
    kind = ev.get("kind")
    detail = ev.get("detail") or {}
    if kind in ("anchor_user_message", "chat_user_message", "chat_bot_message"):
        line = detail.get("content") or ""
    elif kind in ("worker_run_started", "worker_run_completed"):
        run_id = detail.get("run_id")
        status = detail.get("status")
        folder = detail.get("group_folder")
        reason = detail.get("reason")
        reason_txt = f" reason={reason}" if reason else ""
        line = f"run_id={run_id} lane={folder} status={status}{reason_txt}"
    elif kind == "anchor_marked_processed":
        line = f"message_id={detail.get('message_id')} run_id={detail.get('run_id')}"
    else:
        line = detail.get("line") or ""
    print(f"  - {delta} | {ts} | {kind} | {line}")
PY

if [ "$JSON_MODE" -eq 1 ]; then
  echo
  python3 - "$timeline_json" <<'PY'
import json
import sys
print(json.dumps(json.loads(sys.argv[1]), ensure_ascii=True, indent=2))
PY
fi

if [ -n "$JSON_OUT" ]; then
  python3 - "$timeline_json" <<'PY' >"$JSON_OUT"
import json
import sys
print(json.dumps(json.loads(sys.argv[1]), ensure_ascii=True, indent=2))
PY
fi
