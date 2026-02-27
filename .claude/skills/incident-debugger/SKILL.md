---
name: incident-debugger
description: Incident triage and lifecycle tracking for NanoClaw/Jarvis. Use when investigating "Andy not responding", worker instability, dispatch failures, recurring runtime issues, root-cause analysis, or when the user asks to track/reopen/resolve incidents with explicit confirmation.
---

# Incident Debugger

Use this skill for script-first incident response and long-term incident memory.

## Goals

1. Find root cause quickly using the right debug script for the symptom.
2. Track every incident in `.claude/progress/incident.json`.
3. Keep incidents open until the user explicitly confirms the fix.
4. Record exact resolution + verification so similar issues can be resolved faster.

## Required References

Before deep incident debugging, load these references:

1. `docs/troubleshooting/DEBUG_CHECKLIST.md`
2. `docs/workflow/nanoclaw-container-debugging.md`
3. `.claude/rules/nanoclaw-jarvis-debug-loop.md`

Use the checklist as the canonical runbook; do not improvise command order unless blocked.

## Core Rules

1. Never mark an incident `resolved` unless the user explicitly confirms it is fixed.
2. Prefer script outputs over ad-hoc/manual interpretation.
3. Do not create an incident immediately when a symptom is reported; debug first, then create incident with verified cause/details.
4. Every serious investigation should produce an incident bundle.
5. If a resolved issue recurs, reopen the same incident (do not create duplicate IDs unless unrelated).

## Script Routing Matrix

Use `bash scripts/jarvis-ops.sh <command>` for all operations.

### A) "System feels broken / unstable"

Run in order:

1. `preflight`
2. `reliability`
3. `status`

If runtime is unhealthy, continue with:

4. `recover`
5. rerun `preflight` and `status`

### B) "Andy/Jarvis did not respond"

Run:

1. `status`
2. `trace --lane andy-developer` (or `--run-id` / `--chat-jid` if known)
3. `watch --once --lines 300`

If issue persists:

4. `incident-bundle --window-minutes 180 --lane andy-developer --incident-id <id>`

### C) "Dispatch blocked / contract mismatch"

Run:

1. `dispatch-lint --file <dispatch.json> --target-folder <jarvis-worker-x>`
2. `status`
3. `trace --lane andy-developer`

### D) "DB/schema/session drift suspected"

Run:

1. `db-doctor`
2. `status`

### E) "Recurring patterns across time"

Run:

1. `hotspots --window-hours 72`
2. `incident list --status open`

### F) "Worker lane execution health"

Run:

1. `probe`
2. `status`

### G) "Capture handoff artifacts"

Run:

1. `incident-bundle --window-minutes 180 --lane andy-developer`

By default this is debug-only (no incident tracking) unless `--incident-id` or `--track` is provided.

## Container/Runtime Debug Command Pack

Use this sequence when container behavior is suspicious:

1. `container system status`
2. `container builder status`
3. `container ls -a`
4. `bash scripts/jarvis-ops.sh preflight`
5. `bash scripts/jarvis-ops.sh status`

If CLI/runtime is hung or inconsistent:

1. `container system stop`
2. `container system start`
3. `container builder start`
4. `launchctl kickstart -k gui/$(id -u)/com.nanoclaw`
5. rerun `bash scripts/jarvis-ops.sh preflight`

If worker image/runtime is suspect:

1. `./container/worker/build.sh`
2. `container images | rg nanoclaw-worker`
3. `bash scripts/jarvis-ops.sh smoke`

## Incident Lifecycle Commands

### Initialize registry

`incident init`

### Add a new incident manually

`incident add --title "<title>" --lane <lane>`

After debugging, enrich with verified details:

`incident enrich --id <incident-id> --cause "<root cause>" --impact "<impact>" --next-action "<next step>"`

### List incidents without reading full JSON

`incident list --status open`
`incident list --status resolved`

### Show one incident

`incident show --id <incident-id>`

### Append investigative notes

`incident note --id <incident-id> --note "<finding>"`

### Resolve (strict gate)

Only after user confirmation:

`incident resolve --id <incident-id> --resolution "<exact fix>" --verification "<tests/checks>" --fix-reference "<commit/pr/script>" --user-confirmed-fixed --user-confirmation "<exact user confirmation text>"`

If user has not confirmed, do not run resolve; keep status `open`.

### Reopen on recurrence

`incident reopen --id <incident-id> --reason "<regression reason>"`

## Standard Investigation Flow

1. `incident init`
2. Run routing matrix scripts based on symptom
3. Capture debug artifacts with `incident-bundle` (no tracking yet)
4. Derive/verify root cause from trace/status/hotspots outputs
5. Create incident with `incident add`
6. Attach verified details via `incident enrich` (and optional `incident note`)
7. For ongoing tracked incidents, use `incident-bundle --incident-id <id>` to append fresh evidence
8. Apply fixes and rerun validation (`preflight`, `status`, `trace` as relevant)
9. Wait for explicit user confirmation
10. Run `incident resolve ... --user-confirmed-fixed --user-confirmation "<user text>"`

## Output Contract For Agent

When using this skill, report:

1. active incident id
2. scripts run + key outcome
3. current incident status (`open`/`resolved`)
4. if unresolved, next validation step
5. if ready to resolve, request explicit user confirmation text
6. if no incident exists yet, provide debug result first and only then create incident with `incident add` + `incident enrich`
