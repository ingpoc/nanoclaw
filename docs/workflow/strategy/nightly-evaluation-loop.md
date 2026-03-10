# Nightly Evaluation Loop

Token-efficient overnight research lane for upstream NanoClaw changes and tool changelog changes, plus the bounded morning Codex pickup that turns those findings into explicit GitHub state.

Use this when changing the overnight improvement lane, its scheduler, its research budget, or the morning Codex prep contract.

Mission anchor: `docs/MISSION.md`.

## Purpose

Provide a low-noise overnight research lane that continuously evaluates only net-new upstream/tooling changes and hands the surviving findings to Codex for morning triage without leaking implementation work into the scheduled automation lanes.

## Doc Type

`workflow-loop`

## Canonical Owner

This document owns the overnight upstream/tooling evaluation lane, its token-efficiency rules, and the morning Codex triage handoff.

## Objective

Improve NanoClaw continuously while avoiding daytime automation churn and avoiding repeat research on already-evaluated changes.

## Scope

Nightly v1 covers only:

1. upstream NanoClaw changes from `qwibitai/nanoclaw`
2. Claude Code release/tag changes
3. Claude Agent SDK release/tag changes
4. OpenCode release/tag changes

This lane does not implement code, create Issues, move Project state, or open PRs.

## Use When

- changing the overnight improvement lane
- changing the nightly scheduler or worktree bootstrap
- changing token-budget or repeat-research dedupe rules
- changing how nightly findings are surfaced to Codex in the morning

## Do Not Use When

- changing the daytime platform pickup lane only
- changing GitHub Actions/rulesets/review policy without touching the local overnight lane
- deciding whether a promoted finding should enter `Ready` for implementation

## Day vs Night Split

### Daytime lane

The existing platform automation is a sparse execution lane:

1. one-shot pickup at `10:00` Asia/Kolkata
2. one-shot pickup at `15:00` Asia/Kolkata
3. manual trigger remains available for urgent work

### Nightly lane

The nightly lane runs once at `00:30` Asia/Kolkata and only:

1. detects net-new upstream/tooling changes
2. researches only those changed sources
3. updates at most one upstream discussion and one tooling discussion
4. records local cursor state for dedupe

### Morning Codex prep lane

The morning Codex prep lane runs once at `08:30` Asia/Kolkata and only:

1. runs `bash scripts/workflow/session-start.sh --agent codex --no-background-sync`
2. handles only GitHub collaboration items surfaced by that session-start sweep
3. applies the nightly promotion boundary only to pending nightly handoffs
4. reruns `session-start.sh` once after GitHub follow-up
5. writes a structured summary and stops

The morning lane must not edit repo-tracked files. It may update GitHub state and runtime-local artifacts only.

## Runtime Surfaces

- `.claude/agents/nightly-improvement-researcher.md`
- `.claude/commands/nightly-improvement-eval.md`
- `.codex/agents/morning-prep.toml`
- `scripts/workflow/nightly-improvement.js`
- `scripts/workflow/start-nightly-improvement.sh`
- `scripts/workflow/start-morning-codex-prep.sh`
- `scripts/workflow/morning-codex-prep-output-schema.json`
- `launchd/com.nanoclaw-nightly-improvement.plist`
- `launchd/com.nanoclaw-morning-codex-prep.plist`
- `.nanoclaw/nightly-improvement/state.json` (runtime-local, gitignored)
- `.nanoclaw/nightly-improvement/runs/` (runtime-local logs)
- `.nanoclaw/morning-codex-prep/` (runtime-local logs and summaries)

## Token-Efficiency Contract

1. Research only net-new source deltas by default.
2. Never re-research the same upstream head or same tool version once it is recorded, unless explicitly forced.
3. Use the deterministic scan output as the primary source of truth.
4. Read additional docs only when the scan output still suggests a credible opportunity.
5. Maintain one discussion per source family, not one discussion per run or per feature guess.
6. Cap nightly tooling candidates to the bounded worklist returned by the scanner.

## State Contract

Runtime-local state lives in `.nanoclaw/nightly-improvement/state.json`.

Tracked fields:

1. `last_run_at`
2. `last_upstream_sha`
3. `tool_versions`
4. `discussion_refs`
5. `evaluated_keys`

`evaluated_keys` is the repeat-research guard:

1. upstream keys use `upstream:<head_sha>`
2. tooling keys use `tool:<tool_key>@<version>`

Do not treat this file as execution truth. GitHub Discussions remain the durable collaboration artifact.

## Nightly Flow

1. `launchd` invokes `scripts/workflow/start-nightly-improvement.sh`.
2. The launcher syncs the dedicated nightly worktree.
3. The launcher runs `node scripts/workflow/nightly-improvement.js scan --state-path <source-root-state>`.
4. If the result is `noop`, the launcher records the run and stops without invoking Claude.
5. If evaluation is required, the launcher runs `claude -p --agent nightly-improvement-researcher --model sonnet`.
6. The agent reads the scan file and updates discussions only for the pending source families.
7. After successful discussion updates, the agent records the processed cursor keys with `record`.
8. The launcher writes a runtime-local run log under `.nanoclaw/nightly-improvement/runs/`.

If upstream changed and the head SHA is new:
   - evaluate the changed range
   - update `Upstream NanoClaw Sync`
   - leave one Claude decision comment
If tool versions changed and the versions are new:
   - evaluate only the listed changed tools
   - update `SDK / Tooling Opportunities`
   - leave one Claude decision comment

## Discussion Contract

Nightly discussion bodies must include:

1. exact evaluated range or version delta
2. the source links actually used
3. NanoClaw subsystem fit
4. candidate adoption or explicit `no-fit`
5. operator-load / risk impact
6. `P1`, `P2`, or `P3`

Discussion bodies must include one of these markers:

- `<!-- nightly-improvement:upstream -->`
- `<!-- nightly-improvement:tooling -->`

Decision comments must include:

1. `Agent Label: Claude Code`
2. `Decision: pilot|defer|reject`
3. a one-line summary
4. `To: Codex`
5. `Status: needs-input`
6. `Next: morning Codex triage`

## Morning Codex Contract

`gh-collab-sweep.sh --agent codex` surfaces a `NIGHTLY IMPROVEMENT FINDINGS` section.

The surfaced nightly finding is the handoff boundary: it should appear only when the latest Claude nightly decision is newer than the latest Codex triage comment for that discussion.

Codex should:

1. review surfaced nightly discussions during morning session-start triage
2. make an explicit decision for each surviving candidate before moving on
3. promote only when the next action is concrete enough for an execution Issue
4. leave a clear non-promotion reason for anything not promoted
5. keep the rolling nightly discussion open unless the source family is intentionally retired or replaced

The sweep itself remains read-only.

### Morning Triage Routine

When `NIGHTLY IMPROVEMENT FINDINGS` is non-empty, Codex should process the surfaced discussions in this order:

1. read the latest nightly discussion update
2. verify whether the candidate already exists locally or is already tracked
3. decide one of:
   - `accept -> opened Issue #N`
   - `defer -> reason`
   - `reject -> reason`
   - `reference only -> reason`
4. if accepted, create one execution Issue with concrete next action, set `Source=discussion`, and leave a promotion summary comment
5. if not accepted, leave the decision comment in the discussion so the morning triage outcome is explicit

When this routine is executed by the scheduled morning Codex prep lane, it should remain bounded to the surfaced morning queue:

1. do not start implementation work
2. do not kick off `qmd-session-sync.sh`
3. do not edit repo-tracked workflow/docs/code files
4. rerun `session-start.sh --agent codex --no-background-sync` once after triage to confirm the queue is clean

Morning triage should convert research into a clear GitHub state:

1. Discussions remain the research and decision log
2. Issues represent committed execution only
3. The Project reflects execution state only after an Issue exists

### Promotion Boundary

Promote a nightly finding only when all are true:

1. the proposed improvement has a concrete next action
2. the work is not already tracked by an open Issue
3. the expected benefit is specific to NanoClaw or its operator workflow
4. Codex can state a bounded acceptance target for the first execution step

Do not promote when the finding is only interesting, speculative, already covered locally, or not yet scoped enough to test.

### Discussion Closure Rule

Nightly discussions are rolling source-family threads, not disposable tickets.

Do not close the nightly discussion after each morning triage.

Close or replace a nightly discussion only when:

1. the source family is retired
2. the thread is obsolete and a fresh canonical thread is intentionally created
3. governance explicitly changes the nightly discussion structure

## Related Docs

- `docs/workflow/strategy/workflow-optimization-loop.md`
- `docs/workflow/github/github-collab-sweep.md`
- `docs/workflow/github/github-agent-collaboration-loop.md`
- `docs/workflow/github/nanoclaw-platform-loop.md`

## Verification

- `node scripts/workflow/nightly-improvement.js scan --output /tmp/nightly-scan.json`
- `node scripts/workflow/nightly-improvement.js record --scan-file /tmp/nightly-scan.json`
- `bash scripts/workflow/start-morning-codex-prep.sh --dry-run`
- `claude agents --setting-sources project`
- `bash scripts/workflow/start-nightly-improvement.sh --dry-run`
- `bash scripts/workflow/gh-collab-sweep.sh --agent codex`
- `npm test -- src/nightly-improvement.test.ts src/platform-loop-sync.test.ts src/platform-loop.test.ts src/github-project-sync.test.ts`

## Anti-Patterns

1. re-researching an unchanged source every night
2. creating many discussions for one changed source family
3. using the nightly lane to create execution Issues directly
4. letting the morning sweep auto-promote or auto-close findings
5. storing nightly execution truth in repo-tracked files
