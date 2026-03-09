# NanoClaw Platform Claude Pickup Lane

## Purpose

Canonical workflow for the sparse daytime Claude pickup lane that claims scoped `NanoClaw Platform` work, implements it, and hands it to Codex review.

## Doc Type

`workflow-loop`

## Canonical Owner

This document owns the daytime `NanoClaw Platform` Claude execution lane.
It does not own the overnight research lane; that belongs to `docs/workflow/strategy/nightly-evaluation-loop.md`.

## Use When

- changing the `NanoClaw Platform` autonomous Claude pickup lane
- editing `.claude/commands/platform-pickup.md`
- editing the launch/bootstrap scripts for the daytime pickup lane
- changing platform-board field/state rules used by the lane

## Do Not Use When

- changing the overnight upstream/tooling research lane
- changing only GitHub Actions/rulesets/review policy
- deciding whether a changelog idea should become committed work

## Verification

- `node scripts/workflow/platform-loop.js next`
- `node scripts/workflow/platform-loop.js ids --issue 1 --title "example"`
- `bash scripts/workflow/platform-loop-sync.sh --dry-run`
- `bash scripts/workflow/start-platform-loop.sh --dry-run`
- `npm test -- src/platform-loop.test.ts src/platform-loop-sync.test.ts src/github-project-sync.test.ts`
- `bash scripts/check-workflow-contracts.sh`

## Related Docs

- `docs/workflow/strategy/nightly-evaluation-loop.md`
- `docs/workflow/github/github-agent-collaboration-loop.md`
- `docs/workflow/github/nanoclaw-github-control-plane.md`
- `groups/andy-developer/docs/github-workflow-admin.md`

## Precedence

1. Discussions decide whether platform automation candidates should be piloted.
2. This doc governs the sparse daytime Claude execution lane after a platform Issue is already `Ready`.
3. Overnight upstream/tooling research belongs to `docs/workflow/strategy/nightly-evaluation-loop.md`.

## Candidate Formation

1. Start in `SDK / Tooling Opportunities`.
2. Require Claude and Codex decision comments: `accept`, `pilot`, `defer`, or `reject`.
3. Promote to one `NanoClaw Platform` Issue only when the discussion decision is concrete enough to commit work.
4. Promotion alone does not make the Issue `Ready`.
5. Before the item can enter `Ready`, Codex must write or normalize the execution contract on the Issue:
   - `Problem Statement`
   - `Execution Board`
   - `Scope`
   - `Acceptance Criteria`
   - `Expected Productivity Gain`
   - `Base Branch`
   - `Required Checks`
   - `Required Evidence`
   - `Blocked If`
   - `Ready Checklist`

## Dispatch Readiness

The Issue is eligible for pickup only when all are true:

1. local GitHub auth is confirmed as `ingpoc`
2. `Status=Ready`
3. no other Claude-owned item is already `In Progress`
4. no Claude-owned item is already in `Review`
5. Codex has explicitly authored or validated the execution contract before setting `Ready`
6. the Issue is not label-blocked

## Sparse Daytime Scheduler

The daytime lane is not a persistent hourly `/loop`.

It is a sparse one-shot pickup lane:

1. launchd invokes `scripts/workflow/check-platform-loop.sh` at `10:00` Asia/Kolkata
2. launchd invokes `scripts/workflow/check-platform-loop.sh` at `15:00` Asia/Kolkata
3. `scripts/workflow/check-platform-loop.sh` starts a one-shot pickup only when another pickup is not already running
4. `scripts/workflow/trigger-platform-pickup-now.sh` remains the manual one-shot trigger

## Pickup Flow

1. The scheduled or manual lane runs `/platform-pickup` in an interactive Claude session.
2. `/platform-pickup` confirms the active GitHub account is `ingpoc`.
3. It refreshes the dedicated worktree from `origin/main` via `bash scripts/workflow/platform-loop-sync.sh`.
4. If the sync fails, Claude stops immediately instead of using stale code.
5. It runs `node scripts/workflow/platform-loop.js next`.
6. If the helper returns `noop`, the lane stops with no work picked.
7. If the helper returns a candidate, Claude generates a `request_id`, `run_id`, and branch via `node scripts/workflow/platform-loop.js ids ...`.
8. Claude moves the board item to `In Progress` and sets `Agent=claude`.
9. Claude immediately leaves an issue comment proving claim ownership.

## Bounded Implementation

1. Claude creates or reuses the dedicated issue branch from the freshly synced base.
2. Claude works only within the scoped touch set.
3. Claude runs the required checks from the Issue.
4. On ambiguity, missing scope, or failed required checks, Claude sets `Status=Blocked`, writes the next decision, comments the blocker, and stops.

## PR and Review Handoff

1. Claude opens or updates a PR linked to the Issue.
2. The PR must include summary, verification evidence, risks, and rollback notes.
3. Claude moves the item to `Review`.
4. Claude leaves an issue comment with PR URL, branch, request/run ids, checks run, and known risks.
5. `Next Decision` must be a Codex review action, not a vague note.

## Runtime Surfaces

- `.claude/commands/platform-pickup.md`
- `scripts/workflow/run-platform-claude-session.sh`
- `scripts/workflow/platform-loop.js`
- `scripts/workflow/platform-loop-sync.sh`
- `scripts/workflow/start-platform-loop.sh`
- `scripts/workflow/trigger-platform-pickup-now.sh`
- `scripts/workflow/check-platform-loop.sh`
- `launchd/com.nanoclaw-platform-loop.plist`
- `.nanoclaw/platform-loop/` runtime state files

## Exit Criteria

This workflow is operating correctly when all are true:

1. the daytime lane picks work only at the sparse scheduled slots or via manual trigger
2. the lane never starts from an incomplete Issue
3. every automation PR arrives in `Review` with evidence
4. every active Claude-owned item has a visible claim comment on the linked issue
5. blocked states include a concrete next decision and a matching issue comment
6. Codex review remains explicit and human merge remains mandatory
