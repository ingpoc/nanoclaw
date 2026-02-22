# NanoClaw Jarvis Architecture

## Intent

Jarvis extends NanoClaw with a worker execution tier while keeping NanoClaw core small and generic.

- Core host orchestration remains in `src/index.ts`, `src/container-runner.ts`, `src/group-queue.ts`, `src/ipc.ts`, `src/db.ts`.
- Workflow policy lives in docs/CLAUDE/skills, not in host-loop feature sprawl.
- Worker execution uses OpenCode free-model containers.

## Runtime Tiers

| Tier | Runtime | Role |
|------|---------|------|
| Main orchestration | NanoClaw Node.js process | Poll messages, route by group, enforce queueing and run-state updates |
| Andy-bot (observer) | `nanoclaw-agent` container | Monitor, summarize, triage, GitHub research on `openclaw-gurusharan`, hand off to Andy-developer |
| Andy-Developer (lead) | `nanoclaw-agent` container | Planning, dispatching, review, rework instructions |
| Jarvis worker (`jarvis-worker-*`) | `nanoclaw-worker` container | Bounded execution only (implement/fix/test/etc.) |

## Worker Routing

- Group folder prefix `jarvis-worker*` routes to `WORKER_CONTAINER_IMAGE` (`nanoclaw-worker:latest` by default).
- Explicit `containerConfig.image` is supported; worker-mode behavior is only auto-applied for `nanoclaw-worker` images.
- Non-worker groups keep Claude Agent SDK session behavior unchanged.

## Delegation Authorization

- `main` can target any group (existing NanoClaw control plane behavior).
- `andy-developer` can delegate only to `jarvis-worker-*` targets through IPC message/task lanes.
- `andy-bot` is observer/research only and does not dispatch worker tasks.
- Other non-main groups remain self-scoped (no cross-group delegation).

## Canonical Run Lifecycle

```text
queued -> running -> review_requested
               -> failed_contract
               -> failed
```

- `run_id` is canonical and must be provided by dispatcher.
- Same `run_id` is idempotent: duplicate execution is blocked unless retrying from `failed`/`failed_contract`.
- Completion contract gates transition to `review_requested`.

## Invariants (P0)

1. No plain-text worker dispatch. Worker dispatch must be strict JSON.
2. Required dispatch fields: `run_id`, `task_type`, `input`, `repo`, `branch`, `acceptance_tests`, `output_contract`.
3. Branch must follow `jarvis-<feature>`.
4. Completion block must include `run_id`, `branch`, `commit_sha`, `files_changed`, `test_result`, `risk`, and one of `pr_url` or `pr_skipped_reason`.
5. Completion `run_id` must match dispatch `run_id`.

## Storage and Auditability

`worker_runs` tracks:

- run state (`queued/running/review_requested/failed_contract/failed/done`)
- retry count
- completion artifacts (`branch_name`, `commit_sha`, `files_changed`, `test_summary`, `risk_summary`, `pr_url`)

This keeps worker runs reproducible and review-auditable.

## Policy Placement

| Concern | Location |
|---------|----------|
| Host primitives | `src/*` core files |
| Dispatch contract | `src/dispatch-validator.ts` + `docs/workflow/nanoclaw-jarvis-dispatch-contract.md` |
| Worker runtime details | `docs/workflow/nanoclaw-jarvis-worker-runtime.md` |
| Team operating model | `docs/workflow/optimized-nanoclaw-jarvis-vision.md` |

## Non-Goals

- No HTTP microservice worker API.
- No replacement of NanoClaw host loop with workflow-specific logic.
- No ad-hoc per-group behavior outside the contract + policy docs.
