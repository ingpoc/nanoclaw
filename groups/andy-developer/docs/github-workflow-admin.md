# Andy-Developer GitHub Workflow Admin

Control-plane playbook for GitHub Actions, review automation, branch governance, the sparse daytime platform pickup lane, and the nightly improvement lane.

## Scope

Andy-developer may directly change:

- `.github/workflows/*.yml`
- CI/review policy docs
- Branch governance docs and operational checklists
- control-plane automation scripts for platform pickup and nightly evaluation
- pre-seeded worker branches (`jarvis-*`) created from an approved `base_branch`

Andy-developer must not directly implement product source code.

## Project Board Split

Use separate boards only when they represent different domains:

- `NanoClaw Platform`:
  - NanoClaw functionality and features
  - runtime/worker contracts
  - SDK/tooling adoption
  - GitHub governance/control-plane changes
- `Andy/Jarvis Delivery`:
  - user-provided project work
  - project delivery tasks and follow-ups

Rules:

1. one execution item belongs to one board only
2. if delivery work is blocked by platform work, create a linked platform Issue instead of duplicating the item on both boards
3. SDK/tooling discussions promote to `NanoClaw Platform` by default unless explicitly scoped to project delivery
4. `Andy/Jarvis Delivery` board state is host-managed from runtime request/worker transitions, not worker-authored GitHub edits

## Standard Sequence

1. Define objective and required checks.
2. Create a dedicated branch (`jarvis-admin-<topic>`).
3. Implement workflow/policy changes.
4. Open PR with clear risk and rollback notes.
5. Decide review mode: request Claude review only when required by project policy/risk.
6. Merge only after required checks pass.

## Sparse Daytime Platform Pickup Lane

Use the daytime Claude pickup lane only for `NanoClaw Platform` issues that are already decision-complete.

Required runtime surfaces:

- `.claude/commands/platform-pickup.md`
- `scripts/workflow/run-platform-claude-session.sh`
- `scripts/workflow/platform-loop.js`
- `scripts/workflow/platform-loop-sync.sh`
- `scripts/workflow/start-platform-loop.sh`
- `scripts/workflow/trigger-platform-pickup-now.sh`
- `scripts/workflow/check-platform-loop.sh`
- `launchd/com.nanoclaw-platform-loop.plist`

Operating rules:

1. the pickup lane confirms local GitHub auth is `ingpoc` before reading or mutating the NanoClaw platform board
2. unanimous discussion promotion creates the platform Issue, but does not make it `Ready`
3. before an issue can be marked `Ready`, Codex must write or normalize the scope, acceptance, checks, evidence, blocked conditions, and checked `Ready Checklist` on the Issue body
4. the lane claims only one `Ready` platform issue at a time
5. if any Claude-owned platform item is already `Review`, the lane must no-op
6. the lane must move active implementation to `In Progress` and set `Agent=claude`
7. the lane must move review-ready PRs to `Review`
8. on ambiguity or failed required checks, the lane must move the item to `Blocked` with a concrete `Next Decision`
9. the lane must leave issue comments when it claims work, blocks, and hands off to review
10. Codex is the default review lane after the lane finishes implementation
11. merge remains human-only
12. the lane provisions an ephemeral worktree per pickup and removes it automatically after Claude exits when the worktree is clean
13. if the session ends with a dirty worktree, the lane may preserve it temporarily, but the retained path must be called out in the blocker or handoff note

Scheduler rules:

1. the launchd job is sparse, not hourly
2. scheduled pickups run at `10:00` and `15:00` Asia/Kolkata
3. `scripts/workflow/check-platform-loop.sh` starts a pickup only when another pickup is not already running
4. `scripts/workflow/trigger-platform-pickup-now.sh` is the manual one-shot trigger

## Nightly Improvement Lane

Use the nightly Claude lane for upstream/tooling evaluation only.

Required runtime surfaces:

- `.claude/agents/nightly-improvement-researcher.md`
- `.claude/commands/nightly-improvement-eval.md`
- `scripts/workflow/nightly-improvement.js`
- `scripts/workflow/start-nightly-improvement.sh`
- `launchd/com.nanoclaw-nightly-improvement.plist`
- `.nanoclaw/nightly-improvement/state.json`

Nightly rules:

1. nightly work is research-only and never creates execution Issues or PRs directly
2. scheduled execution is headless via `claude -p`, not an interactive Terminal session
3. the scheduled lane uses the `nightly-improvement-researcher` project subagent with model `sonnet`
4. nightly research starts from deterministic scan output, not open-ended browsing
5. previously evaluated upstream heads and tool versions are skipped unless explicitly forced
6. nightly output updates one upstream discussion and one tooling discussion at most
7. every nightly decision comment uses `Agent Label: Claude Code` with `pilot`, `defer`, or `reject`
8. Codex performs the morning triage and selective promotion

## Requirement-Based Review Decision

| Profile | `@claude` Review |
|---------|------------------|
| Low-risk internal change | Optional |
| Standard product change | On-demand (recommended) |
| High-risk/compliance/security-sensitive | Required |

Andy-developer owns this decision for each project/repository.

## Workflow Bundle Selection

| Bundle | Include |
|--------|---------|
| Minimal | build/test only |
| Standard | build/test + optional `claude-review` workflow |
| Strict | standard + policy/security checks + stricter merge gates |

Choose the smallest bundle that still satisfies project requirements.

## Required Checks for Mainline Governance

- TypeScript compile/build checks
- Test suite checks
- Any contract/guardrail checks for dispatch/review flow

## Branch Governance Baseline

- `main` is PR-only.
- Required checks must pass before merge.
- Direct pushes to `main` are blocked.
- Include administrators in protection/ruleset.

## Evidence Format for Admin Changes

When reporting completion, include:

- changed workflow file list
- affected required checks
- proof of latest check status
- rollback command or revert PR reference
