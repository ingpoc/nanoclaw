# Docs Governance

Compressed from 5 docs-discipline files + 2 routing maps. This is the single authority for doc/trigger/skill hygiene.

## CLAUDE.md Compression Gate

Only keep content inline when ALL are true:

1. Needed in ≥80% of sessions
2. Silent failure without it
3. Fits in ≤3 lines

Everything else → `docs/` with one trigger line. Same rule applies to `groups/*/CLAUDE.md`.

## Doc Creation Gate

Before creating a new doc:

1. What gap exists that current docs don't cover?
2. Which existing doc is closest — can it absorb this?
3. What single boundary does the new doc own?
4. What breaks without it?

If answers 2 or 4 are weak, extend existing doc instead.

## Doc Types

| Type | Purpose |
|------|---------|
| `contract` | Requirements, invariants, validation, exit criteria |
| `workflow-loop` | End-to-end execution flow for recurring tasks |
| `runbook` | Debug/ops for a specific symptom family |

## Pruning

- One canonical doc per topic. Delete superseded/duplicate docs.
- When docs change: update `DOCS.md`, update CLAUDE.md triggers, remove stale references.

## Skill vs Doc Routing

- **Skills** = execution workflows (how to perform repeatable tasks)
- **Docs** = source-of-truth contracts (what must remain true)
- Load required docs first (invariants), then execute via matching skill.
- Skills reference scripts, don't duplicate them.

## Trigger Line Rules

- One trigger = one action
- No narrative in Docs Index
- A new doc adds at most one trigger line
- Group related triggers (all worker changes → single trigger pointing to `docs/workflow/runtime/`)

## Lane Governance Sync

When editing `groups/*/` governance files (`.claude/rules/`, `.claude/skills/`, CLAUDE.md):

- **Workers must stay symmetric**: any rule/skill added to worker-1 must be copied to worker-2 in the same change
- **No `container/rules/`**: this path is not auto-loaded by OpenCode. Use `.claude/rules/` instead
- **No `/home/node/.claude/rules/` triggers**: rules in `.claude/rules/` are auto-loaded, triggers are redundant and point to wrong path
- **Validate**: run `bash scripts/check-lane-governance.sh` after lane governance changes
