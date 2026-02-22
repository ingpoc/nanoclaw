# Roles Classification

Role contract for NanoClaw + Jarvis operation.

## Role Matrix

| Role | Runtime | Primary Scope | Must Not Do |
|------|---------|---------------|-------------|
| `main` | host process control | global orchestration, full group control | n/a |
| `andy-bot` | `nanoclaw-agent` | observation, summarization, GitHub research on `openclaw-gurusharan`, risk triage | direct worker dispatch/control |
| `andy-developer` | `nanoclaw-agent` | convert context into strict worker dispatch, review completion, request rework | bypass contract or dispatch to non-worker lanes |
| `jarvis-worker-*` | `nanoclaw-worker` | bounded execution from dispatch contract, produce `<completion>` payload | unbounded orchestration decisions |

## Handoff Sequence

1. `andy-bot` gathers context and risk signal.
2. `andy-developer` emits strict JSON dispatch (`run_id`, branch, tests, output contract).
3. `jarvis-worker-*` executes and returns `<completion>`.
4. `andy-developer` reviews and resolves to done/rework.

## Access Policy

- `andy-bot` and `andy-developer` both retain GitHub access (`GITHUB_TOKEN`/`GH_TOKEN`) for `openclaw-gurusharan` activity.
- Only `andy-developer` has worker delegation authority in IPC lanes.
