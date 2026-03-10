#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT_DIR/.nanoclaw/session-pattern-analysis"
RUNS_DIR="$STATE_DIR/runs"
RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
PROMPT_FILE="$RUNS_DIR/${RUN_ID}-prompt.txt"
JSONL_FILE="$RUNS_DIR/${RUN_ID}.jsonl"
STDERR_FILE="$RUNS_DIR/${RUN_ID}.stderr.log"
LAST_MESSAGE_FILE="$RUNS_DIR/${RUN_ID}-result.json"
SUMMARY_FILE="$RUNS_DIR/${RUN_ID}-summary.md"
RUN_LOG_FILE="$RUNS_DIR/${RUN_ID}-run.json"
BASELINE_STATUS_FILE="$RUNS_DIR/${RUN_ID}-git-status.before"
FINAL_STATUS_FILE="$RUNS_DIR/${RUN_ID}-git-status.after"
STATUS_DIFF_FILE="$RUNS_DIR/${RUN_ID}-git-status.diff"
OUTPUT_SCHEMA_FILE="$ROOT_DIR/scripts/workflow/session-pattern-analysis-output-schema.json"
EXECUTION_MODE="direct-codex-exec"
SESSION_EXPORT_DIR_DEFAULT="${SESSION_EXPORT_DIR:-$HOME/Documents/remote-claude/Obsidian/Claude-Sessions}"

DRY_RUN=0
TOPIC=""
JSON_OUT=""
SUMMARY_OUT=""

usage() {
  cat <<'EOF'
Usage: scripts/workflow/start-session-pattern-analysis.sh --topic "<topic>" [options]

Run the Codex session-pattern analysis utility in headless mode.

Required:
  --topic "<topic>"          Topic or workflow area to analyze

Optional:
  --json-out <path>          Copy the structured JSON result to path
  --summary-out <path>       Copy the rendered Markdown summary to path
  --dry-run                  Print the codex command and exit
  -h, --help                 Show this help
EOF
}

json_escape() {
  python3 - <<'PY' "$1"
import json, sys
print(json.dumps(sys.argv[1]))
PY
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

resolve_codex_bin() {
  if [[ -n "${NANOCLAW_SESSION_PATTERN_CODEX_BIN:-}" ]]; then
    printf '%s\n' "$NANOCLAW_SESSION_PATTERN_CODEX_BIN"
    return 0
  fi

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  local fallback=""
  fallback="$(
    find "$HOME/.nvm/versions/node" -path '*/bin/codex' -type f 2>/dev/null \
      | sort \
      | tail -n 1
  )"

  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  echo "codex CLI is required but not found in PATH or under \$HOME/.nvm/versions/node" >&2
  exit 1
}

build_prompt() {
  cat >"$PROMPT_FILE" <<EOF
Analyze recurring workflow patterns for this topic: $TOPIC

You are the main orchestrator. This run is Codex-only and must stay read-only even though the execution sandbox is permissive to avoid permission stalls.

Rules:
1. Start with local evidence, not assumptions.
2. Use exported sessions from: $SESSION_EXPORT_DIR_DEFAULT
3. Inspect current repo instructions and workflow docs, especially:
   - docs/workflow/strategy/workflow-optimization-loop.md
   - docs/workflow/strategy/session-introspection-loop.md
   - docs/workflow/runtime/session-recall.md
   - docs/workflow/docs-discipline/skill-routing-preflight.md
   - CLAUDE.md
   - AGENTS.md
4. Use \`node scripts/workflow/session-context-audit.js --top 10\` when context waste or noisy transcripts may matter.
5. Spawn exactly one \`explorer\` helper lane to gather recurring-pattern evidence.
6. Spawn exactly one \`reviewer\` helper lane as a skeptic. The skeptic must judge each proposed optimization as \`accept\`, \`narrow\`, or \`reject\`.
7. Do not spawn \`worker\`.
8. Do not edit repo-tracked files, do not create issues, and do not mutate GitHub state.
9. Prefer targeted reads and compact summaries over large raw command output.
10. Report only recurring workflow debt, not product bugs.

Evidence standard:
- Require evidence from more than one session unless severity is obvious.
- Map every proposal to the smallest owning surface: CLAUDE.md, AGENTS.md, a specific workflow doc, or a script.
- Keep the final set to at most 3 recurring pains.

Return JSON matching the provided schema.
EOF
}

render_summary() {
  python3 - <<'PY' "$LAST_MESSAGE_FILE" "$SUMMARY_FILE"
import json, pathlib, sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
data = json.loads(src.read_text())

lines = []
lines.append(f"# Session Pattern Analysis")
lines.append("")
lines.append(f"Status: `{data['status']}`")
lines.append(f"Topic: `{data['topic']}`")
lines.append("")
lines.append(data["summary"])
lines.append("")
lanes = data["helper_lanes"]
lines.append(f"Helper lanes: evidence=`{lanes['evidence_lane']}`, skeptic=`{lanes['skeptic_lane']}`")
lines.append("")

if data["recurring_pains"]:
    lines.append("## Recurring Pains")
    lines.append("")
    for index, item in enumerate(data["recurring_pains"], start=1):
        evidence = ", ".join(item["evidence_sessions"])
        lines.append(f"{index}. **{item['pain_title']}**")
        lines.append(f"   - Evidence: {evidence}")
        lines.append(f"   - Owner: `{item['owner_surface']}`")
        lines.append(f"   - Proposal: {item['proposal']}")
        lines.append(f"   - Skeptic: `{item['skeptic_verdict']}` — {item['skeptic_reason']}")
        lines.append("")
else:
    lines.append("## Recurring Pains")
    lines.append("")
    lines.append("None surfaced strongly enough to recommend.")
    lines.append("")

if data["notes"]:
    lines.append("## Notes")
    lines.append("")
    for note in data["notes"]:
        lines.append(f"- {note}")

dst.write_text("\n".join(lines).rstrip() + "\n")
PY
}

write_run_log() {
  local status="$1"
  local started_at="$2"
  local ended_at="$3"
  local notes="${4:-}"
  cat >"$RUN_LOG_FILE" <<EOF
{
  "run_id": $(json_escape "$RUN_ID"),
  "execution_mode": $(json_escape "$EXECUTION_MODE"),
  "status": $(json_escape "$status"),
  "topic": $(json_escape "$TOPIC"),
  "started_at": $(json_escape "$started_at"),
  "ended_at": $(json_escape "$ended_at"),
  "prompt_file": $(json_escape "$PROMPT_FILE"),
  "jsonl_file": $(json_escape "$JSONL_FILE"),
  "stderr_file": $(json_escape "$STDERR_FILE"),
  "result_file": $(json_escape "$LAST_MESSAGE_FILE"),
  "summary_file": $(json_escape "$SUMMARY_FILE"),
  "notes": $(json_escape "$notes")
}
EOF
}

copy_optional_output() {
  local src="$1"
  local dst="$2"
  if [[ -z "$dst" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

while (($#)); do
  case "$1" in
    --topic)
      TOPIC="${2:-}"
      shift 2
      ;;
    --json-out)
      JSON_OUT="${2:-}"
      shift 2
      ;;
    --summary-out)
      SUMMARY_OUT="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TOPIC" ]]; then
  echo "--topic is required" >&2
  usage >&2
  exit 1
fi

mkdir -p "$STATE_DIR" "$RUNS_DIR"

require_cmd git
require_cmd python3

if [[ ! -d "$SESSION_EXPORT_DIR_DEFAULT" ]]; then
  echo "Exported session directory not found: $SESSION_EXPORT_DIR_DEFAULT" >&2
  exit 1
fi

if [[ ! -f "$OUTPUT_SCHEMA_FILE" ]]; then
  echo "Missing output schema: $OUTPUT_SCHEMA_FILE" >&2
  exit 1
fi

CODEX_BIN="$(resolve_codex_bin)"
build_prompt

SHELL_COMMAND="cd \"$ROOT_DIR\" && \"$CODEX_BIN\" exec --ephemeral --json -C \"$ROOT_DIR\" -m gpt-5.4 -s danger-full-access -c 'model_reasoning_effort=\"medium\"' -c 'approval_policy=\"never\"' -c 'web_search=\"disabled\"' --output-schema \"$OUTPUT_SCHEMA_FILE\" -o \"$LAST_MESSAGE_FILE\" \"\$(cat \"$PROMPT_FILE\")\""

if [[ "$DRY_RUN" == "1" ]]; then
  echo "$SHELL_COMMAND"
  exit 0
fi

git -C "$ROOT_DIR" status --short --untracked-files=all >"$BASELINE_STATUS_FILE"

STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
set +e
"$CODEX_BIN" exec \
  --ephemeral \
  --json \
  -C "$ROOT_DIR" \
  -m gpt-5.4 \
  -s danger-full-access \
  -c 'model_reasoning_effort="medium"' \
  -c 'approval_policy="never"' \
  -c 'web_search="disabled"' \
  --output-schema "$OUTPUT_SCHEMA_FILE" \
  -o "$LAST_MESSAGE_FILE" \
  "$(cat "$PROMPT_FILE")" \
  >"$JSONL_FILE" 2>"$STDERR_FILE"
EXEC_STATUS=$?
set -e
ENDED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

git -C "$ROOT_DIR" status --short --untracked-files=all >"$FINAL_STATUS_FILE"

if ! cmp -s "$BASELINE_STATUS_FILE" "$FINAL_STATUS_FILE"; then
  diff -u "$BASELINE_STATUS_FILE" "$FINAL_STATUS_FILE" >"$STATUS_DIFF_FILE" || true
  write_run_log "fail" "$STARTED_AT" "$ENDED_AT" "repo-tracked-state-mutated"
  echo "session-pattern-analysis: FAIL (repo-tracked state changed; see $STATUS_DIFF_FILE)" >&2
  exit 1
fi

if [[ "$EXEC_STATUS" -ne 0 ]]; then
  write_run_log "fail" "$STARTED_AT" "$ENDED_AT" "codex-exec-exit-$EXEC_STATUS"
  echo "session-pattern-analysis: FAIL (codex exec exited $EXEC_STATUS)" >&2
  echo "stderr: $STDERR_FILE" >&2
  exit "$EXEC_STATUS"
fi

render_summary
copy_optional_output "$LAST_MESSAGE_FILE" "$JSON_OUT"
copy_optional_output "$SUMMARY_FILE" "$SUMMARY_OUT"
write_run_log "ok" "$STARTED_AT" "$ENDED_AT"

echo "session-pattern-analysis: PASS"
echo "json: $LAST_MESSAGE_FILE"
echo "summary: $SUMMARY_FILE"
cat "$SUMMARY_FILE"
