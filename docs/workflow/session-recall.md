# Session Recall Workflow

Reconstruct personal session context at the start of a session or when picking up interrupted work. Complements the context graph (decisions) and CLAUDE.md (project state) — fills the gap of ephemeral conversational context not captured elsewhere.

## When to Use

| Trigger | Tool |
|---------|------|
| Starting a new session, need to know what was in progress | `/recall yesterday` or `/recall last week` |
| Looking for a past experiment, debug approach, or partial idea not in a context trace | `/recall <topic>` (BM25) |
| Need both session and formal decision context | `/recall <topic>` + `mcp__context-graph__context_query_traces` |
| Resuming interrupted work mid-stream | `/recall today` |

## When NOT to Use

| Situation | Use Instead |
|-----------|-------------|
| Looking for a formal architectural decision | `mcp__context-graph__context_query_traces` |
| Looking for stable patterns or rules | CLAUDE.md / `docs/` |
| Looking for incident history | `.claude/progress/incident.json` |

## Commands

```bash
# Temporal — no QMD needed, reads native JSONL files
/recall yesterday
/recall last week
/recall today
/recall 2026-02-25

# Topic — BM25 across Claude Code + Codex sessions
/recall worker dispatch
/recall whatsapp auth
/recall container build

# Expand a specific session (get the conversation flow)
python3 ~/.claude/skills/recall/scripts/recall-day.py expand <session_id>
```

## Session Start Pattern

```
1. /recall yesterday          → what was in progress, which sessions
2. Pick 1-2 sessions to expand if mid-stream context is needed
3. Load only the CLAUDE.md docs triggered by the current task intent
4. (Optional) mcp__context-graph__context_query_traces for specific decision area
```

This replaces reading the full CLAUDE.md index from scratch on every session start.

## Index Coverage

| Source | Sessions | Days |
|--------|----------|------|
| Claude Code (nanoclaw project) | ~40 | last 30 days rolling |
| Codex | ~120 | last 30 days rolling |

Index auto-updates on session stop via `~/.claude/hooks/index-sessions.sh`.

Manual refresh:

```bash
python3 ~/.claude/skills/recall/scripts/extract-sessions.py \
  --days 30 \
  --source ~/.claude/projects/-Users-gurusharan-Documents-remote-claude-Codex-jarvis-mac-nanoclaw \
  --output ~/Documents/remote-claude/Obsidian/Claude-Sessions

python3 ~/.claude/skills/recall/scripts/extract-codex-sessions.py \
  --days 30 \
  --output ~/Documents/remote-claude/Obsidian/Claude-Sessions

qmd update && qmd embed
```

## Limitations

- **Graph mode** (`/recall graph`) is not useful here — vault and project are separate directories so file edges are empty.
- **Semantic search** (`qmd vsearch`) is deferred until Wispr Flow transcripts are indexed.
- BM25 searches sessions only — does not search project source files.
