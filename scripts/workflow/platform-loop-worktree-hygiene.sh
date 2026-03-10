#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${NANOCLAW_PLATFORM_LOOP_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORKTREE_PATH="${NANOCLAW_PLATFORM_LOOP_WORKTREE:-$ROOT_DIR/.worktrees/platform-loop}"

if ! command -v git >/dev/null 2>&1; then
  echo "platform-loop-hygiene: git is required but not found in PATH" >&2
  exit 1
fi

had_entry=0
if git -C "$ROOT_DIR" worktree list --porcelain 2>/dev/null | grep -Fqx "worktree $WORKTREE_PATH"; then
  had_entry=1
fi

git -C "$ROOT_DIR" worktree prune >/dev/null 2>&1 || true

if [[ ! -d "$WORKTREE_PATH" ]]; then
  if [[ "$had_entry" == "1" ]]; then
    if ! git -C "$ROOT_DIR" worktree list --porcelain 2>/dev/null | grep -Fqx "worktree $WORKTREE_PATH"; then
      echo "session-start: pruned stale platform-loop worktree entry"
    fi
  fi
  exit 0
fi

status_output="$(git -C "$WORKTREE_PATH" status --porcelain --untracked-files=normal 2>/dev/null || true)"
if [[ -n "$status_output" ]]; then
  current_branch="$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"
  echo "session-start: retained dirty platform-loop worktree at $WORKTREE_PATH (branch: $current_branch)"
  printf '%s\n' "$status_output"
  exit 0
fi

git -C "$ROOT_DIR" worktree remove "$WORKTREE_PATH" >/dev/null
git -C "$ROOT_DIR" worktree prune >/dev/null 2>&1 || true
echo "session-start: removed clean leftover platform-loop worktree at $WORKTREE_PATH"
