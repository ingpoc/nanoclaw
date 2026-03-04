# Weekly Slop Optimization Loop

Deterministic weekly workflow for reducing code, config, scripts, and documentation slop without reliability regressions.

Use this during optimization cycles after external research intake.

Mission anchor: `docs/MISSION.md`.

## Objective

1. Keep quality debt non-increasing week over week.
2. Remove stale/duplicate assets deliberately, not ad hoc.
3. Preserve deterministic evidence for every cleanup decision.

## Scope

This loop evaluates and prunes slop in four areas:

1. `docs/` (stale/duplicate/unreferenced docs).
2. `scripts/` (duplicate or orphaned scripts).
3. configuration surfaces (`.claude/`, `.codex/`, `.github/workflows/`, `config-examples/`).
4. implementation surfaces (`src/`, `container/`) for unresolved debt markers.

## Cadence

Run once per week (`45-90 min`) on a dedicated branch:

1. `chore/slop-prune-YYYY-MM-DD`
2. one bounded cleanup batch per week (no broad refactors)
3. merge only after deterministic gates pass

## Phase 0: Preflight

1. Run `bash scripts/workflow/preflight.sh --skip-recall`.
2. Confirm branch scope is slop cleanup only.
3. If runtime reliability issues are active, list open incidents first:
   `bash scripts/jarvis-ops.sh incident list --status open`

## Phase 1: Deterministic Inventory

Run objective checks and capture output:

```bash
bash scripts/check-workflow-contracts.sh
bash scripts/check-claude-codex-mirror.sh
bash scripts/check-tooling-governance.sh
```

Find unreferenced docs:

```bash
bash scripts/workflow/slop-inventory.sh --list-unreferenced-docs
```

Find unreferenced scripts:

```bash
bash scripts/workflow/slop-inventory.sh --list-unreferenced-scripts
```

Optional combined summary (counts + lists):

```bash
bash scripts/workflow/slop-inventory.sh --summary
```

Check exact-duplicate scripts:

```bash
find scripts -type f \( -name '*.sh' -o -name '*.ts' \) -print0 \
  | xargs -0 shasum -a 256 \
  | sort \
  | awk '{print $1}' \
  | uniq -d
```

Check temporary/backup config artifacts:

```bash
find .claude .codex .github config-examples -type f \
  \( -name '*.bak' -o -name '*.old' -o -name '*.orig' -o -name '*~' \) | sort
```

Check unresolved debt markers in code surfaces:

```bash
rg -n --glob '!docs/**' --glob '!.claude/**' --glob '!node_modules/**' '\b(TODO|FIXME|HACK|XXX)\b' src scripts container
```

Review hooks/subagents/built-in routing governance:

```bash
bash scripts/check-tooling-governance.sh
```

## Phase 2: Prune Queue

Build a bounded weekly queue with severity:

1. `P0`: broken contracts or mirror drift (must fix now).
2. `P1`: unreferenced/duplicate files with clear owner replacement.
3. `P2`: debt markers and non-blocking cleanup candidates.

Queue sizing rule per weekly cycle:

1. max 2 deletions
2. max 2 consolidations
3. max 3 small refactors

Do not mix cleanup with unrelated feature delivery.

## Phase 3: Execute Cleanup

For each queued item:

1. remove or consolidate one item at a time
2. update `CLAUDE.md`/`AGENTS.md`/`DOCS.md`/`docs/README.md` when paths change
3. run `rg` proof that old path references are gone

## Phase 4: Verification Gate

Minimum deterministic checks before merge:

```bash
npm run build
npm test
bash scripts/check-workflow-contracts.sh
bash scripts/check-claude-codex-mirror.sh
bash scripts/check-tooling-governance.sh
bash scripts/jarvis-ops.sh acceptance-gate
```

## Phase 5: Weekly Evidence + Ratchet

Write a weekly artifact in `docs/research/`:

1. findings (`docs/scripts/config/code`)
2. actions taken
3. metrics before/after
4. next-week queue

Naming pattern:

- `docs/research/WEEKLY-SLOP-OPTIMIZATION-YYYY-MM-DD.md`

Ratchet rule:

1. no metric may get worse week-over-week without explicit rationale
2. unresolved `P1` items must carry forward with an owner and due week

## Exit Criteria

Weekly slop optimization is complete when all are true:

1. `P0` items are zero.
2. verification gate passes.
3. documentation index/mirror is synchronized.
4. weekly evidence artifact is committed.
