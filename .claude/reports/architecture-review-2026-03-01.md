# Architecture Review — NanoClaw Customizations

_Date: 2026-03-01_

---

## Architecture Overview

Three-tier agent system on top of NanoClaw:

```
WhatsApp user
    │
    ▼
main (Andy) ──── Claude Code (nanoclaw-agent image)
                 conversational, memory, scheduling
    │
    ▼ IPC dispatch
andy-developer ─── Claude Code (nanoclaw-agent image)
                   planner, reviewer, contract drafter
    │
    ▼ JSON dispatch contract
jarvis-worker-1/2 ── OpenCode (nanoclaw-worker image)
                     bounded code execution
```

The topology matches the "humans steer, agents execute" principle from CLAUDE.md. Each tier runs in a container with isolated `.claude/`, isolated IPC namespace, and scoped mounts.

---

## Best Practices Assessment vs Claude Agent SDK

| Pattern | Status | Notes |
|---------|--------|-------|
| Session ID capture from `system/init` message | ✅ Correct | `newSessionId = message.session_id` on `subtype === 'init'` |
| Session resumption via `resume: sessionId` option | ✅ Correct | Passed to `query()` options |
| Async iterable input (`MessageStream`) | ✅ Correct | Keeps `isSingleUserTurn=false` enabling agent teams |
| Agent Teams flag | ✅ Correct | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in settings |
| `additionalDirectories` for multi-CLAUDE.md | ✅ Correct | `/workspace/extra/*` discovery for Andy review repos |
| `PreCompact` hook for archiving | ✅ Correct | Conversation archived before compaction |
| `PreToolUse` hook for secret sanitization | ✅ Correct | Strips API keys from Bash subprocess env |
| Secrets via stdin, never disk | ✅ Correct | `readSecrets()` → stdin → deleted |
| Per-group session isolation | ✅ Correct | `data/sessions/<group>/.claude/` per group |
| IPC namespacing prevents cross-group escalation | ✅ Correct | `canIpcAccessTarget()` authorization gate |
| Mount security validation | ✅ Correct | `validateAdditionalMounts()` with allowlist |
| Dispatch ownership enforcement | ✅ Correct | Only `andy-developer` → `jarvis-worker-*` |
| Completion contract gate with re-invocation | ✅ Correct | Runner re-invokes worker if fields missing |
| Worker uses OpenCode, not Claude Code | ✅ Correct | Separate image, no OAuth fallback for workers |

**Overall: strong alignment with SDK best practices.**

---

## Simplification Opportunities (Clear Benefit Only)

### 1. `isJarvisWorkerFolder` duplicated in 3 files

**Where:**

- `src/ipc.ts:47` — local `isJarvisWorkerFolder()` function
- `src/container-runner.ts:417` — inline `group.folder.startsWith('jarvis-worker')`
- `container/agent-runner/src/index.ts:132` — inline `groupFolder.startsWith('jarvis-worker')`

**Problem:** If you add a second worker type prefix (e.g. `jarvis-analyst-*`), or rename the prefix, you'd miss one of the three places.

**Recommendation:** Export `isJarvisWorkerFolder(folder: string): boolean` from `src/types.ts` or a new `src/worker-identity.ts`. Import it in `ipc.ts` and `container-runner.ts`. The agent-runner is a separate build, so it keeps its own copy (but can share the logic pattern).

**Benefit:** Single source of truth for worker identity. Safer to extend.

---

### 2. `schedule_task` validation in `processTaskIpc` duplicates `validateAndyWorkerDispatchMessage`

**Where:** `src/ipc.ts:630–732` (schedule_task path) vs. `src/ipc.ts:230–290` (validateAndyWorkerDispatchMessage)

**Problem:** The `schedule_task` path hand-rolls ~90 lines of worker dispatch validation that is functionally identical to `validateAndyWorkerDispatchMessage` + `validateWorkerSessionRouting`. If dispatch rules change, both paths must be updated in sync. The dispatch blocks sent differ slightly in format between the two paths too.

**Recommendation:** Extract:

```typescript
function validateWorkerDispatch(
  sourceGroup: string,
  targetFolder: string,
  prompt: string,
): { valid: boolean; reasonCode: DispatchBlockEvent['reason_code']; reason: string; parsed?: DispatchPayload }
```

Then call it from both the message path (already partly done) and the `schedule_task` path.

**Benefit:** Dispatch rules in one place. Lower risk of paths silently diverging.

---

### 3. `parseCompletionContract` — fallback chain is over-engineered

**Where:** `src/dispatch-validator.ts:253–338`

**Current:** 5-level parsing hierarchy:

1. `<completion>...</completion>` tag match → parse JSON inside
2. Direct bare JSON parse (whole output)
3. Fenced code block (``` json ```) extraction
4. Escaped-JSON decode heuristic (`\\n`, `\\"` etc.)
5. Brace extraction (`firstBrace..lastBrace`)

**Problem:** The worker CLAUDE.md mandates `<completion>...</completion>` blocks. The pre-exit gate re-invokes workers if fields are missing. The escaped-JSON decode path (#4) in particular can produce false-positive matches on unintended content.

**Recommendation:** Simplify to:

1. `<completion>` tag (primary, enforced by CLAUDE.md)
2. Direct JSON or fenced JSON (single fallback for analyze/research tasks that output plain JSON)
3. Remove escaped-JSON decode and brace-extraction fallbacks

**Benefit:** Simpler, more predictable parsing. Less surface area for ambiguous matches. The CLAUDE.md + re-invocation gate already handles the correctness enforcement.

---

## No-Change Recommendations

| Area | Rationale |
|------|-----------|
| File-based IPC polling | Required by container boundary. No in-process alternative without removing isolation. |
| Dual container image (agent vs worker) | Claude Code and OpenCode have different runtime requirements. Correct. |
| `buildVolumeMounts` with settings side-effects | Coupled but not harmful — container per group, no parallel spawn, cleanup is pre-spawn |
| `ALTER TABLE ADD COLUMN` migrations | Standard pattern for SQLite schema evolution. `createSchema` has the base, migrations add columns. |
| `OutputChain` promise chaining | Correct for ordered streaming output. Not over-engineered. |
| OAuth → API key fallback for main/andy-developer only | `OAUTH_FALLBACK_GROUPS` hardcoded but deliberate control-lane policy |
| `allowedTools` list in agent-runner | Comprehensive but appropriate — workers don't use this (separate image) |

---

## Patterns Worth Noting (Not Problems)

**`MessageStream.session_id: ''`** (agent-runner:89) — each pushed message has `session_id: ''`. This is the local `SDKUserMessage` interface, not the SDK output type. The SDK routes multi-turn context via the `resume: sessionId` query option, not per-message session_id. So `''` is fine here — confirmed by session working correctly in production.

**`agent-runner-src` writable, `skills` always-synced** — This is intentional: agent-runner source is preserved after first copy (agent-customizable), skills are always overwritten from `container/skills/` on each start (centrally managed). The design is correct.

**`validateCompletionContract` auto-allowing no-code on `pr_skipped_reason`** — Intentional for research/analysis tasks. Workers can legitimately produce no code change if the dispatch doesn't require it.

---

## Summary

The customization is architecturally sound and well-aligned with Claude Agent SDK patterns. The three identified simplifications (worker identity function, dispatch validation deduplication, completion parser simplification) are the only changes with clear, non-trivial benefit. Everything else is appropriate complexity for the use case being built.

Priority order: 2 (dispatch validation) > 1 (worker identity) > 3 (completion parser)
