#!/usr/bin/env bash
set -euo pipefail

# Lane Governance Validator
# Ensures governance structure consistency across all NanoClaw lanes.
# Run: bash scripts/check-lane-governance.sh
# Wired into: scripts/workflow/preflight.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

errors=()
warnings=()

err()  { errors+=("$1"); }
warn() { warnings+=("$1"); }

# --- Worker Parity ---
# Workers must have identical .claude/rules/ and .claude/skills/ sets.
W1="groups/jarvis-worker-1"
W2="groups/jarvis-worker-2"

if [ -d "$W1/.claude/rules" ] && [ -d "$W2/.claude/rules" ]; then
  w1_rules=$(ls "$W1/.claude/rules/" 2>/dev/null | sort)
  w2_rules=$(ls "$W2/.claude/rules/" 2>/dev/null | sort)
  if [ "$w1_rules" != "$w2_rules" ]; then
    err "worker rules drift: worker-1 has [$(echo $w1_rules | tr '\n' ', ')] vs worker-2 has [$(echo $w2_rules | tr '\n' ', ')]"
  fi
elif [ -d "$W1/.claude/rules" ] && [ ! -d "$W2/.claude/rules" ]; then
  err "worker-2 missing .claude/rules/ (worker-1 has it)"
elif [ ! -d "$W1/.claude/rules" ] && [ -d "$W2/.claude/rules" ]; then
  err "worker-1 missing .claude/rules/ (worker-2 has it)"
fi

if [ -d "$W1/.claude/skills" ] && [ -d "$W2/.claude/skills" ]; then
  w1_skills=$(ls "$W1/.claude/skills/" 2>/dev/null | sort)
  w2_skills=$(ls "$W2/.claude/skills/" 2>/dev/null | sort)
  if [ "$w1_skills" != "$w2_skills" ]; then
    err "worker skills drift: worker-1 has [$(echo $w1_skills | tr '\n' ', ')] vs worker-2 has [$(echo $w2_skills | tr '\n' ', ')]"
  fi
elif [ -d "$W1/.claude/skills" ] && [ ! -d "$W2/.claude/skills" ]; then
  err "worker-2 missing .claude/skills/ (worker-1 has it)"
elif [ ! -d "$W1/.claude/skills" ] && [ -d "$W2/.claude/skills" ]; then
  err "worker-1 missing .claude/skills/ (worker-2 has it)"
fi

# --- Dead Governance Paths ---
# container/rules/ is not auto-loaded by OpenCode. Files there are invisible.
for group_dir in groups/*/; do
  if [ -d "${group_dir}container/rules" ]; then
    err "dead governance path: ${group_dir}container/rules/ (move to ${group_dir}.claude/rules/)"
  fi
done

# --- Required Governance per Role ---
# Andy-developer must have coordinator operating rule
ANDY="groups/andy-developer"
for required_rule in coordinator-operating-rule.md docs-governance.md; do
  if [ ! -f "$ANDY/.claude/rules/$required_rule" ]; then
    err "andy-developer missing required rule: .claude/rules/$required_rule"
  fi
done

# Workers must have operating rule and compression loop
for worker in "$W1" "$W2"; do
  worker_name=$(basename "$worker")
  for required_rule in worker-operating-rule.md compression-loop.md skill-routing-preflight.md; do
    if [ ! -f "$worker/.claude/rules/$required_rule" ]; then
      err "$worker_name missing required rule: .claude/rules/$required_rule"
    fi
  done
done

# --- Stale References ---
# No context-graph references in worker operational docs
for worker in "$W1" "$W2"; do
  worker_name=$(basename "$worker")
  if [ -d "$worker/docs/workflow" ]; then
    if grep -rql "context-graph\|context_graph" "$worker/docs/workflow/" 2>/dev/null; then
      matches=$(grep -rl "context-graph\|context_graph" "$worker/docs/workflow/" 2>/dev/null | head -3)
      err "$worker_name operational docs still reference context-graph: $matches"
    fi
  fi
done

# No broken /home/node/.claude/rules/ references in CLAUDE.md
for group_dir in groups/*/; do
  group_name=$(basename "$group_dir")
  if [ -f "${group_dir}CLAUDE.md" ]; then
    if grep -q "/home/node/.claude/rules/" "${group_dir}CLAUDE.md" 2>/dev/null; then
      err "$group_name CLAUDE.md has broken /home/node/.claude/rules/ trigger (rules are auto-loaded from .claude/rules/)"
    fi
  fi
done

# --- CLAUDE.md Required Sections ---
# Main must have system topology
if [ -f "groups/main/CLAUDE.md" ]; then
  if ! grep -q "System Topology" "groups/main/CLAUDE.md" 2>/dev/null; then
    warn "main CLAUDE.md missing System Topology section"
  fi
fi

# Andy must have expert judgment
if [ -f "$ANDY/CLAUDE.md" ]; then
  if ! grep -q "Expert Judgment" "$ANDY/CLAUDE.md" 2>/dev/null; then
    warn "andy-developer CLAUDE.md missing Expert Judgment section"
  fi
fi

# --- Output ---
if [ "${#errors[@]}" -gt 0 ]; then
  echo "lane-governance-check: FAIL"
  for e in "${errors[@]}"; do
    echo "  ERROR: $e"
  done
  for w in "${warnings[@]}"; do
    echo "  WARN: $w"
  done
  exit 1
fi

echo "lane-governance-check: PASS"
if [ "${#warnings[@]}" -gt 0 ]; then
  for w in "${warnings[@]}"; do
    echo "  WARN: $w"
  done
fi
exit 0
