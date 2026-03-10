# Weekly Slop Optimization Loop

Deterministic weekly workflow for reducing code, config, scripts, and documentation slop without reliability regressions.

Use this during optimization cycles after external research intake.

Mission anchor: `docs/MISSION.md`.

## Objective

1. Keep quality debt non-increasing week over week.
2. Remove stale/duplicate assets deliberately, not ad hoc.
3. Preserve deterministic evidence for every cleanup decision.
4. Reduce context and token waste caused by duplicated workflow guidance.

## Scope

This loop evaluates and prunes slop in four areas:

1. `docs/` (stale/duplicate/unreferenced docs).
2. `scripts/` (duplicate or orphaned scripts).
3. configuration surfaces (`.claude/`, `.codex/`, `.github/workflows/`, `config-examples/`).
4. implementation surfaces (`src/`, `container/`) for unresolved debt markers.

Workflow duplication and context-budget waste are part of `docs/` slop and must be audited explicitly.

## Separation Of Concern

Use this loop for scheduled deduplication and pruning only.

1. `docs/workflow/strategy/session-introspection-loop.md` owns reactive workflow repair after real execution friction.
2. This loop owns recurring cleanup of duplicated guidance, stale references, dead scripts, and context-budget drift.
3. `CLAUDE.md` and `AGENTS.md` should route to workflow owners, not restate workflow bodies.
4. Delivery/runtime workflow docs should define execution steps, not duplicate governance or cleanup policy.

One concern gets one owner. When overlap is found, remove the duplicate text and leave a reference to the canonical owner.

## Cadence

Run once per week (`45-90 min`) on a dedicated branch:

1. `chore/slop-prune-YYYY-MM-DD`
2. one bounded cleanup batch per week (no broad refactors)
3. merge only after deterministic gates pass

## Automation (Prevention Phase)

Manual on-demand run:

```bash
bash scripts/jarvis-ops.sh weekend-prevention \
  --skip-preflight \
  --skip-acceptance \
  --json-out data/diagnostics/weekend-prevention/latest-manifest.json \
  --summary-out data/diagnostics/weekend-prevention/latest-summary.md
```

When running shared verification for slop cleanup, include prevention as part of the same workflow:

```bash
bash scripts/workflow/verify.sh --with-weekend-prevention
```

Weekend artifacts are written under:

- `data/diagnostics/weekend-prevention/`

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

## Phase 2: Prevention Frequency Sweep

Run prevention recall from incidents and runtime evidence before pruning decisions:

```bash
bash scripts/jarvis-ops.sh weekend-prevention \
  --skip-preflight \
  --skip-acceptance \
  --json-out data/diagnostics/weekend-prevention/latest-manifest.json \
  --summary-out data/diagnostics/weekend-prevention/latest-summary.md
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

Audit workflow duplication and progressive-disclosure drift:

1. find workflow docs that restate another workflow's execution steps instead of referencing it
2. find `CLAUDE.md` or `AGENTS.md` lines that paraphrase a workflow body instead of routing to it
3. find triggers that cause agents to read multiple near-overlapping docs for one small task
4. find auto-loaded rules that should be trigger-loaded because they are not needed in most sessions

Treat repeated operational guidance as slop even when the wording differs.

## Phase 3: Prune Queue

Build a bounded weekly queue with severity:

1. `P0`: broken contracts or mirror drift (must fix now).
2. `P1`: unreferenced/duplicate files or overlapping workflow instructions with clear owner replacement.
3. `P2`: debt markers, trigger tuning, and non-blocking cleanup candidates.

Queue sizing rule per weekly cycle:

1. max 2 deletions
2. max 2 consolidations
3. max 3 small refactors

Do not mix cleanup with unrelated feature delivery.

Queue workflow cleanup using these rules:

1. prefer deleting duplicated workflow text over adding another explanatory doc
2. prefer narrowing a trigger over adding a second partially overlapping trigger
3. prefer moving detail from auto-loaded rules into trigger-loaded docs when silent-failure risk stays covered
4. do not split a workflow unless the split reduces retrieval cost and preserves one clear owner per concern

## Phase 4: Execute Cleanup

For each queued item:

1. remove or consolidate one item at a time
2. update `CLAUDE.md`/`AGENTS.md`/`DOCS.md`/`docs/README.md` when paths change
3. run `rg` proof that old path references are gone
4. if pruning workflow overlap, keep one canonical owner and replace other copies with references
5. if changing triggers, verify the new path loads the minimum sufficient context for the task

## Phase 5: Verification Gate

Minimum deterministic checks before merge:

```bash
npm run build
npm test
bash scripts/check-workflow-contracts.sh
bash scripts/check-claude-codex-mirror.sh
bash scripts/check-tooling-governance.sh
bash scripts/jarvis-ops.sh acceptance-gate
```

## Phase 6: Weekly Evidence + Ratchet

Write a weekly artifact in `docs/research/`:

1. findings (`docs/scripts/config/code`)
2. actions taken
3. metrics before/after
4. next-week queue

Naming pattern:

- `docs/research/WEEKLY-SLOP-OPTIMIZATION-<YYYY-MM-DD>.md`

Ratchet rule:

1. no metric may get worse week-over-week without explicit rationale
2. unresolved `P1` items must carry forward with an owner and due week
3. workflow duplication count and unnecessary-doc-load count should trend downward over time

## Exit Criteria

Weekly slop optimization is complete when all are true:

1. `P0` items are zero.
2. verification gate passes.
3. documentation index/mirror is synchronized.
4. weekly evidence artifact is committed.

## Phase 7: Context Budget Optimization

Auto-loaded rules (`.claude/rules/`) consume tokens every session. Trigger-loaded docs (`docs/` + CLAUDE.md trigger line) load only when relevant.

### Decision: Auto-Load vs Trigger-Load

A rule stays in `.claude/rules/` (auto-loaded) only if ALL are true:

1. Applies in >=80% of sessions
2. Silent/wrong behavior without it (not just slower)
3. Under ~150 tokens

Otherwise, move to `docs/` and add a trigger line in CLAUDE.md.

### Inventory Command

```bash
# List auto-loaded rules with token estimates
for f in .claude/rules/*.md; do
  tokens=$(wc -w < "$f" | awk '{printf "%d", $1 * 1.3}')
  printf "%-50s ~%s tokens\n" "$f" "$tokens"
done
```

### Prune Checklist

For each auto-loaded rule, ask:

| Question | If No → |
|----------|---------|
| Needed most sessions? | Move to `docs/`, add trigger |
| Causes silent failure if missing? | Move to `docs/`, add trigger |
| Under ~150 tokens? | Extract detail to `docs/`, keep stub |

### Evidence Template

Record context budget changes in weekly artifact:

```text
## Context Budget
- Rules moved to trigger-load: [list]
- Duplicates removed: [list]
- Tokens freed: [number]
- Remaining auto-loaded rules: [list with token counts]

## Workflow Deduplication
- Canonical owners clarified: [list]
- Duplicate workflow sections removed: [list]
- Triggers narrowed or removed: [list]
- Docs no longer required for common small tasks: [list]
```

## Agent Routing

| Step | Agent | Mode | Notes |
|------|-------|------|-------|
| Prioritization | `main` | fg | Cost/impact judgment and ownership decisions stay in the main lane |
| Inventory scripts/docs | `explorer` | fg | Scan for slop candidates, stale refs, workflow overlap |
| Verification gates | `monitor` | bg | Run governance/mirror/contract checks |
| Workflow overlap audit | `reviewer` | fg | Identify duplicate guidance and wrong-owner text with file evidence |
| Mechanical fixes | `worker` | fg | Apply approved slop removals in bounded scope |
