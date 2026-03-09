# NanoClaw Start Runbook

Decision tree for starting, restarting, or registering NanoClaw. Follow top to bottom — stop at the first matching state.

## Step 1: Check Current State

```bash
launchctl list | grep "com.nanoclaw$"
```

| Output | State | Go to |
|--------|-------|-------|
| `<PID>  0  com.nanoclaw` | Running via launchd | [Restart](#restart-launchd-registered) |
| `-  0  com.nanoclaw` | Registered but stopped | [Start](#start-launchd-registered-but-stopped) |
| _(no output)_ | Not registered | Check if running manually → [Step 2](#step-2-check-for-manual-process) |

---

## Step 2: Check for Manual Process

_(Only if Step 1 returned no output)_

```bash
ps aux | grep "node.*dist/index" | grep -v grep
```

| Output | State | Go to |
|--------|-------|-------|
| Process found | Running manually (no launchd) | [Register + migrate](#register-launchd-from-manual-process) |
| No output | Not running at all | [Fresh start](#fresh-start-nothing-running) |

---

## Restart (launchd registered)

Service is already registered. This is the normal case.

```bash
launchctl kickstart -k gui/$(id -u)/com.nanoclaw
```

Verify:

```bash
launchctl list | grep "com.nanoclaw$"
# Expected: <PID>  0  com.nanoclaw
```

---

## Start (launchd registered but stopped)

```bash
launchctl kickstart gui/$(id -u)/com.nanoclaw
```

Verify same as above.

---

## Register launchd (from manual process)

Manual process is running but launchd doesn't own it. Stop the manual process first, then register.

```bash
# 1. Find and stop the manual process
kill $(ps aux | grep "node.*dist/index" | grep -v grep | awk '{print $2}')
sleep 2

# 2. Write the plist (only needed once — skip if ~/Library/LaunchAgents/com.nanoclaw.plist exists)
npx tsx setup/index.ts --step service

# 3. Bootstrap with launchd
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nanoclaw.plist

# 4. Verify
launchctl list | grep "com.nanoclaw$"
```

> **Note:** `setup/service.ts` generates the plist correctly — no manual env vars needed.
> The service defaults to `service` mode (correct for launchd-managed processes).

---

## Fresh Start (nothing running)

```bash
# 1. Build
npm run build

# 2. If plist already exists, bootstrap
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nanoclaw.plist

# If plist does NOT exist, generate and bootstrap
npx tsx setup/index.ts --step service

# 3. Verify
launchctl list | grep "com.nanoclaw$"
```

---

## Verify Health After Any Start

```bash
bash scripts/jarvis-preflight.sh
```

All checks should be `[PASS]`. Lane inactivity `[WARN]`s are normal when idle.

To also validate andy-developer end-to-end:

```bash
npx tsx scripts/test-andy-user-e2e.ts
```

---

## Stop Service

```bash
launchctl bootout gui/$(id -u)/com.nanoclaw
```

> This unregisters from launchd. Use `kickstart` to start again, or re-bootstrap the plist.

---

## Plist Location

```
~/Library/LaunchAgents/com.nanoclaw.plist
```

Key properties: `KeepAlive true` (auto-restart on crash), `RunAtLoad true` (start on login).
