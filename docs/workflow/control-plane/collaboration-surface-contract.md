# Collaboration Surface Contract

## Purpose

Canonical day-to-day workflow for how Claude, Codex, and humans use Linear, Notion, GitHub, and repo-local artifacts together in this repository.
This is the operator-facing playbook for deciding where collaboration starts, when it becomes committed work, and how execution state is recorded without creating duplicate trackers.

## Owns

This document owns daily operation of the collaboration surfaces in this repository:

1. where work should start
2. when shared context becomes execution work
3. how ownership is assigned
4. how each surface should be used during execution

## Does Not Own

This document does not own:

1. workflow auth, merge policy, or review automation setup
2. GitHub-vs-local placement decisions

Use instead:

1. `docs/workflow/github/github-delivery-governance.md` for governance workflow policy
2. `docs/workflow/github/github-offload-boundary-loop.md` for placement decisions

## Doc Type

`workflow-loop`

## Canonical Owner

This document owns the operating workflow for active agent use of collaboration surfaces.
Do not duplicate its day-to-day execution rules in `docs/workflow/github/github-delivery-governance.md`.

## Use When

Use this before agents create, update, promote, or close shared context, execution work, or delivery state for collaboration work.

## Do Not Use When

- You are changing workflow auth, Actions, or review policy; use `docs/workflow/github/github-delivery-governance.md`.
- You are changing branch/ruleset/security offload boundaries; use `docs/workflow/github/github-offload-boundary-loop.md`.

## Verification

- `bash scripts/check-workflow-contracts.sh`
- `bash scripts/check-claude-codex-mirror.sh`
- `bash scripts/check-tooling-governance.sh`
- `zsh -lc 'set -a; source .env; set +a; node scripts/workflow/work-control-plane.js'`
- `zsh -lc 'set -a; source .env; set +a; node scripts/workflow/linear-work-sweep.js --agent codex'`

## Related Docs

- `docs/workflow/github/github-delivery-governance.md`
- `docs/workflow/github/github-offload-boundary-loop.md`
- `docs/operations/workflow-setup-responsibility-map.md`

## Precedence

1. This doc governs ongoing agent use of collaboration surfaces in this repository.
2. `docs/workflow/github/github-delivery-governance.md` governs workflow auth, review automation, and GitHub-hosted control-plane policy.
3. If there is conflict, `CLAUDE.md` trigger routing decides which doc to read first, then this doc controls day-to-day collaboration behavior.

## Operating Invariants

1. Start work in the least-committed surface that still matches the current maturity of the idea.
2. Use Notion for exploration and durable shared context, Linear for committed work and execution state, GitHub for code delivery, and repo files for machine artifacts only.
3. Every active execution item has exactly one primary owner.
4. No shared surface becomes a second scratchpad thread; reasoning stays in Notion decisions/research, Linear comments, or PR comments depending on the stage.
5. One class of state gets one source of truth. Do not maintain the same execution state in both Linear and local files as co-equal trackers.

## Start Surface Selector

1. Notion page:
   - Use for workflow/process ideas, mission-aligned feature ideas, upstream evaluation, Claude/Codex collaboration design, research, and operating overviews.
   - Use when there is still uncertainty about scope, ownership, or whether any work should be committed at all.
2. Linear issue:
   - Use for committed work with scope, one owner, and deterministic acceptance criteria.
   - Do not open execution work until the next action is concrete enough to test or close.
3. GitHub PR:
   - Use only for delivery state on already-committed work.
   - Do not use PRs as idea trackers or long-form collaboration threads.

Default tie-breaker:

1. If the topic is ambiguous, start in Notion.
2. If the work is actionable but not yet claimed, use a Linear issue.
3. If the work is already being delivered, reflect that in Linear + GitHub PR state.

## Three-Layer Model

Use the current collaboration stack with this exact separation of purpose:

1. Notion = exploration, durable shared context, decisions, research, and operating overviews
2. Linear = committed work, ownership, triage, and execution state
3. GitHub = PRs, review, CI, merge governance
4. Repo files = machine artifacts, execution contracts, catalogs, incidents, and evidence

Current rules:

1. Notion does not own live execution status
2. Linear does not replace PR discussion or CI results
3. GitHub does not become a second issue tracker
4. Repo-local docs remain canonical only when agents depend on them for safe execution

## Notion Contract

Use Notion when the goal is to think, compare, align, evaluate, or preserve shared context.

Expected outputs from a Notion page:

1. `accepted -> create Linear issue`
2. `deferred`
3. `rejected`
4. `reference only`

Do not use Notion to:

1. represent active execution state
2. substitute for assigning an owner
3. collect final acceptance evidence for completed code work

## Linear Issue Contract

Every execution issue should include:

1. the problem being solved
2. the scope boundary
3. deterministic acceptance criteria
4. one primary owner
5. required checks and required evidence
6. rollback notes
7. the work source (`user`, `notion-research`, `upstream-nanoclaw`, `claude-update`, `codex-observation`, or equivalent current taxonomy)

Promotion from Notion context to Linear issue:

1. create the issue when there is a concrete next action
2. copy only the essential context from the Notion source
3. link the relevant Notion page
4. assign one owner
5. place the issue in the correct Linear project/triage state

Do not open an issue for:

1. unresolved brainstorming
2. unowned collaboration notes
3. vague “keep in mind later” items

## Ownership Contract

Use a single active owner for every execution issue:

1. assignee is the primary owner: `claude`, `codex`, or `human`
2. review responsibility is represented via labels, comments, or PR review state, not a co-equal second owner

Allowed:

1. `codex` owns readiness/intake and `claude` owns implementation handoff
2. `claude` owns implementation and `codex` owns review/repair
3. `human` owns the issue while Claude or Codex assists through explicit delegation

Not allowed:

1. Claude and Codex both acting as active co-owners of one issue
2. Active work with no owner
3. A Notion page acting as a substitute for ownership assignment

Recommended default:

1. one implementation owner
2. one optional review lane
3. one linked PR per primary issue unless the split is explicitly intentional

Autonomous lane split for this repository:

1. Codex owns intake, promotion, and `Ready`
2. Claude owns implementation pickup for already-`Ready` issues
3. Codex owns PR review, CI repair, and `ready-for-user-merge`
4. Claude reliability may open incidents and fix PRs, but may not promote roadmap work or set `Ready`

## Linear Project Contract

The Linear project answers only one question: what is the current execution state of committed work?

Execution status flow:

1. `Backlog`: accepted but not active
2. `Ready`: scoped and unblocked
3. `In Progress`: one owner is executing
4. `Review`: PR open or review lane active
5. `Blocked`: waiting on dependency or decision
6. `Done`: Issue closed and acceptance met

Default state transitions:

1. new committed issue -> `Backlog` or `Triage`
2. Codex-complete execution contract -> `Ready`
3. claimed scoped work -> `In Progress`
4. linked active PR -> `Review`
5. blocked work -> `Blocked`
6. merged/closed complete work -> `Done`

Authority rules:

1. Only Codex may move an issue to `Ready`
2. Only Claude pickup may move a claimed feature issue from `Ready` to `In Progress`
3. Only Codex PR guardian may apply the `ready-for-user-merge` label
4. Reliability incidents may set a global pickup pause, but they do not move unrelated issues to `Blocked`

Label rules:

1. `ready-for-user-merge` means Codex review is complete and the PR is waiting only on human merge
2. `autonomy-blocked` means autonomous repair reached a non-repo or policy-level blocker and should not keep retrying
3. labels do not replace Linear state; they add merge and block semantics for autonomous lanes

Do not use Linear project state to store:

1. design rationale
2. incident investigation notes
3. long-form collaboration history
4. duplicate PR state outside the linked field

Pause rule:

1. `.nanoclaw/autonomy/pause.json` blocks only new feature pickup
2. Codex PR guardian continues repairing open PRs while pickup is paused
3. Claude reliability continues triage and soak testing while pickup is paused

## CLI, API, and Human-Admin Boundaries

Agents may use repo-local wrappers and APIs for Linear work:

1. read assigned and delegated issues
2. move issue state across the execution flow
3. attach PR URLs, handoffs, and evidence
4. add bounded comments needed for automation and review handoff

Agents may use Notion only for shared context:

1. publish distilled session summaries
2. link or retrieve relevant specs, decisions, and research
3. avoid manual execution-state tracking inside Notion

Agents may use GitHub CLI and APIs for delivery work:

1. open and update PRs
2. inspect CI and review state
3. comment on PRs and issues when needed for delivery
4. sync delivery metadata needed by GitHub-hosted automation

Human-admin only:

1. changing Notion database schema or permissions
2. changing repo settings
3. changing branch protection/rulesets
4. changing secrets/variables
5. changing the Linear schema beyond the accepted field model

## Session Start Sweep

Run this before any task work every session:

```bash
bash scripts/workflow/session-start.sh --agent claude
bash scripts/workflow/session-start.sh --agent codex
```

The wrapper runs recall bootstrap, the active control-plane sweep, and workflow preflight in order.
Act on blocked sweep output before starting new work. See `docs/workflow/control-plane/session-work-sweep.md` for the full protocol.

## Shared Context Affinity

Each agent owns first response for a subset of shared-context topics:

| Context Topic | First Responder |
|---------------|-----------------|
| Workflow / Operating Model | Claude |
| Claude/Codex Collaboration | Claude |
| Feature Ideas | Codex |
| SDK / Tooling Opportunities | Codex |
| Upstream NanoClaw Sync | Codex |

## Handoff Format

When leaving work for the other agent, post a comment on the Issue:

```
<!-- agent-handoff -->
From: claude|codex
To: claude|codex
Status: completed|blocked|needs-review|needs-input
Next: <concrete next action>
Context: <brief context>
```

## Daily Loop

1. Run session-start workflow and act on blocked sweep output.
2. Start in the correct surface using the selector above.
3. Keep exploratory work in Notion until a next action is concrete.
4. Promote concrete work into a Linear issue with owner + acceptance criteria.
5. Keep the Linear issue state current.
6. Link the PR back to the Linear issue and let GitHub show delivery/review state.
7. Post a handoff comment if leaving work for the other agent.
8. Close the Issue when acceptance is met; do not hide follow-up work in comments.

## Exit Criteria

This workflow is being followed correctly when all are true:

1. Every active Linear item is an issue, not a PR
2. Every active Issue has exactly one primary owner
3. Every exploratory topic starts in Notion, not Linear
4. Every promoted research-driven issue sets `Source=notion-research` or an equivalent explicit source
5. No closed Issue remains `In Progress`
6. Notion context taxonomy and Linear schema remain aligned with the accepted collaboration model

## Anti-Patterns

1. Using Linear as a brainstorming board
2. Tracking execution in Notion comments instead of Linear fields
3. Opening PR cards as duplicates of Issue cards
4. Letting two agents co-own the same active execution item
5. Creating Issues without acceptance criteria
6. Treating Notion/Linear schema admin as a normal agent task instead of a human-admin task
7. Copying the same work-item state into repo files and Linear as two manual systems of record
