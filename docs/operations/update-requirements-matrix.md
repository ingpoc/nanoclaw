# Update Requirements Matrix

Where updates are required for each change type.

| Change Type | Required Updates |
|-------------|------------------|
| Core orchestrator flow (`src/index.ts`, queue, IPC lifecycle) | `docs/reference/REQUIREMENTS.md`, `docs/reference/SPEC.md`, `docs/architecture/nanoclaw-system-architecture.md`, `CLAUDE.md` triggers if behavior scope changes |
| Jarvis dispatch/completion schema | `src/dispatch-validator.ts`, `docs/workflow/nanoclaw-jarvis-dispatch-contract.md`, `docs/architecture/nanoclaw-jarvis.md`, checklist evidence in `docs/workflow/nanoclaw-jarvis-acceptance-checklist.md` |
| Worker runtime/image/mount/model changes | `container/worker/*`, `src/container-runner.ts`, `docs/workflow/nanoclaw-jarvis-worker-runtime.md`, `docs/operations/update-requirements-matrix.md`, smoke evidence |
| Role authority changes (`andy-bot`, `andy-developer`, workers) | `docs/operations/roles-classification.md`, `src/ipc.ts` auth gates, `container/rules/*-operating-rule.md`, `docs/architecture/nanoclaw-jarvis.md` |
| Debug workflow/playbook changes | `.claude/rules/nanoclaw-jarvis-debug-loop.md`, `docs/troubleshooting/DEBUG_CHECKLIST.md` or `docs/troubleshooting/APPLE-CONTAINER-NETWORKING.md` as applicable, `DOCS.md` map |
| Worker workflow policy changes | `groups/jarvis-worker-*/docs/workflow/execution-loop.md`, `groups/jarvis-worker-*/docs/workflow/worker-skill-policy.md`, relevant role rules |
| Root documentation structure/classification | `DOCS.md`, `README.md` docs link, `CLAUDE.md` trigger index |

## Minimum Verification

After any non-trivial runtime or contract change:

1. `npm run build`
2. `npm test`
3. `./container/worker/build.sh` (if worker runtime/image path touched)
4. `npx tsx scripts/test-worker-e2e.ts` (if delegation/worker path touched)
