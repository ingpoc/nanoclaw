# NanoClaw Jarvis Debug Loop

Use this loop when worker builds hang, delegation fails, or smoke flow breaks.

## Role Model (Mandatory)

- `Andy-bot`: observe, summarize, triage risk, hand off.
- `Andy-bot`: observe, summarize, triage risk, GitHub research on `openclaw-gurusharan`, hand off.
- `Andy-developer`: dispatch/review owner for Jarvis workers.
- `jarvis-worker-*`: bounded execution only.

If the issue is execution-path related, debug through `andy-developer -> jarvis-worker-*`, not direct worker-only assumptions.

## 1) Container Runtime Health

Run in order:

1. `container system status`
2. `container builder status`
3. `container ls -a`

If CLI commands hang:

1. kill stuck `container ...` CLI processes
2. `container system stop`
3. `container system start`
4. `container builder start`

If logs show `ERR_FS_CP_EINVAL` with `src and dest cannot be the same` under `.claude/skills`:

1. confirm runtime is on latest `src/container-runner.ts`
2. verify skill staging skips hidden entries (like `.docs`)
3. restart NanoClaw service after build (`launchctl kickstart -k gui/$(id -u)/com.nanoclaw`)

## 2) Worker Build Failures

If buildkit DNS fails (`EAI_AGAIN`, `Temporary failure resolving`):

- Do not rely on apt/npm inside buildkit.
- Use `container/worker/build.sh` artifact flow:
  - prepare OpenCode bundle with `container run`
  - build with local `vendor/opencode-ai-node_modules.tgz`

Validation:

1. `./container/worker/build.sh`
2. `container images | rg nanoclaw-worker`

## 3) OpenCode Runtime Failures

If worker output indicates model issues:

- Check for `Model not found` in worker output.
- Ensure runner fallback path remains active:
  1. requested model
  2. `opencode/minimax-m2.5-free`
  3. `opencode/big-pickle`
  4. `opencode/kimi-k2.5-free`

If output is JSON event stream:

- parse `text` events (and `message.part.updated` text fields), not only final `step_finish`.

## 4) Delegation Authorization Checks

Expected IPC behavior:

- `main` -> any group: allowed.
- `andy-developer` -> `jarvis-worker-*`: allowed.
- non-main/non-Andy groups -> cross-group: blocked.

If delegation fails, verify `src/ipc.ts` authorization gates first.

## 5) End-to-End Smoke Gate

Run:

`npx tsx scripts/test-worker-e2e.ts`

Pass criteria:

1. Andy container uses `nanoclaw-agent:latest`
2. Worker container uses `nanoclaw-worker:latest`
3. Dispatch validates
4. Completion validates
5. `worker_runs.status == review_requested`

If fail:

- capture failing stage
- apply fix
- rerun smoke until green
- update docs/checklist evidence

## 6) Quota-Limited Claude Lane

If `andy-developer` or `main` returns quota text (`You've hit your limit ...`):

1. treat as model-capacity issue, not dispatch/runtime failure
2. keep worker path available for bounded execution tasks
3. retry after quota reset or adjust model/runtime for affected group
