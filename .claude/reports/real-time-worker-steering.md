Plan: Real-Time Worker Steering                                                                                                                                                                   │
│                                                                                                                                                                                                   │
│ Context                                                                                                                                                                                           │
│                                                                                                                                                                                                   │
│ NanoClaw's mission is autonomous code delivery via WhatsApp. Currently the andy-developer → jarvis-worker dispatch is one-way: once dispatched, the worker is a black box until it completes or   │
│ times out. If the worker goes off-track, the only recovery is a full cancel-and-redispatch cycle.                                                                                                 │
│                                                                                                                                                                                                   │
│ This plan adds bidirectional communication:                                                                                                                                                       │
│                                                                                                                                                                                                   │
│ - Progress events: worker → andy-developer (visibility into what the worker is doing)                                                                                                             │
│ - Steering messages: andy-developer (or you via WhatsApp) → in-flight worker (course correction without restarting)                                                                               │
│                                                                                                                                                                                                   │
│ Modelled on pi's steering/follow-up message queue pattern, built on top of NanoClaw's existing file-based IPC infrastructure.                                                                     │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Architecture                                                                                                                                                                                      │
│                                                                                                                                                                                                   │
│ You → WhatsApp → Andy → andy-developer                                                                                                                                                            │
│                               ↑ progress events (polled from progress/ dir)                                                                                                                       │
│                               ↓ steering messages (written to steer/ dir)                                                                                                                         │
│                         jarvis-worker container                                                                                                                                                   │
│                               ↓ polls /workspace/ipc/steer/{run_id}.json                                                                                                                          │
│                               ↑ writes /workspace/ipc/progress/{run_id}/*.json                                                                                                                    │
│                                                                                                                                                                                                   │
│ New IPC subdirectories (per worker group):                                                                                                                                                        │
│                                                                                                                                                                                                   │
│ data/ipc/jarvis-worker-1/                                                                                                                                                                         │
│ ├── messages/       (existing)                                                                                                                                                                    │
│ ├── tasks/          (existing)                                                                                                                                                                    │
│ ├── input/          (existing — container input)                                                                                                                                                  │
│ ├── progress/       (NEW — worker writes events here)                                                                                                                                             │
│ │   └── {run_id}/                                                                                                                                                                                 │
│ │       └── {timestamp}-{seq}.json                                                                                                                                                                │
│ └── steer/          (NEW — andy-developer writes steering here)                                                                                                                                   │
│     └── {run_id}.json                                                                                                                                                                             │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Implementation Steps                                                                                                                                                                              │
│                                                                                                                                                                                                   │
│ Step 1 — New Types (src/types.ts)                                                                                                                                                                 │
│                                                                                                                                                                                                   │
│ Add two new interfaces:                                                                                                                                                                           │
│                                                                                                                                                                                                   │
│ export interface WorkerProgressEvent {                                                                                                                                                            │
│   kind: 'worker_progress';                                                                                                                                                                        │
│   run_id: string;                                                                                                                                                                                 │
│   group_folder: string;                                                                                                                                                                           │
│   timestamp: string;                                                                                                                                                                              │
│   phase: string;             // active phase label (e.g. "reading files", "writing tests")                                                                                                        │
│   summary: string;           // 1-line human-readable progress summary                                                                                                                            │
│   tool_used?: string;        // last tool call name if relevant                                                                                                                                   │
│   seq: number;               // monotonic sequence number                                                                                                                                         │
│ }                                                                                                                                                                                                 │
│                                                                                                                                                                                                   │
│ export interface WorkerSteerEvent {                                                                                                                                                               │
│   kind: 'worker_steer';                                                                                                                                                                           │
│   run_id: string;                                                                                                                                                                                 │
│   from_group: string;                                                                                                                                                                             │
│   timestamp: string;                                                                                                                                                                              │
│   message: string;           // plain text steering instruction                                                                                                                                   │
│   steer_id: string;          // unique id for ack tracking                                                                                                                                        │
│ }                                                                                                                                                                                                 │
│                                                                                                                                                                                                   │
│ Also add 'steer_worker' as a new IPC action type alongside send_message / schedule_task.                                                                                                          │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Step 2 — DB Schema (src/db.ts)                                                                                                                                                                    │
│                                                                                                                                                                                                   │
│ Add new table worker_steering_events:                                                                                                                                                             │
│                                                                                                                                                                                                   │
│ CREATE TABLE IF NOT EXISTS worker_steering_events (                                                                                                                                               │
│   steer_id TEXT PRIMARY KEY,                                                                                                                                                                      │
│   run_id TEXT NOT NULL,                                                                                                                                                                           │
│   from_group TEXT NOT NULL,                                                                                                                                                                       │
│   message TEXT NOT NULL,                                                                                                                                                                          │
│   sent_at TEXT NOT NULL,                                                                                                                                                                          │
│   acked_at TEXT,             -- set when container consumes it                                                                                                                                    │
│   status TEXT DEFAULT 'pending'  -- 'pending' | 'acked' | 'expired'                                                                                                                               │
│ )                                                                                                                                                                                                 │
│                                                                                                                                                                                                   │
│ Add columns to worker_runs:                                                                                                                                                                       │
│                                                                                                                                                                                                   │
│ ALTER TABLE worker_runs ADD COLUMN last_progress_summary TEXT;                                                                                                                                    │
│ ALTER TABLE worker_runs ADD COLUMN last_progress_at TEXT;                                                                                                                                         │
│ ALTER TABLE worker_runs ADD COLUMN steer_count INTEGER DEFAULT 0;                                                                                                                                 │
│                                                                                                                                                                                                   │
│ New functions:                                                                                                                                                                                    │
│                                                                                                                                                                                                   │
│ - insertSteeringEvent(steerEvent) → persists steer request                                                                                                                                        │
│ - ackSteeringEvent(steerId) → marks consumed                                                                                                                                                      │
│ - updateWorkerRunProgress(runId, summary, timestamp) → updates last_progress columns                                                                                                              │
│ - getWorkerRunProgress(runId) → returns last_progress_summary + at                                                                                                                                │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Step 3 — Container: Emit Progress Events (container/agent-runner/src/index.ts)                                                                                                                    │
│                                                                                                                                                                                                   │
│ The agent-runner drives the SDK query() loop. Add a progress emitter that hooks into the message stream:                                                                                          │
│                                                                                                                                                                                                   │
│ Location: After the for await (const message of response) loop (around line 95)                                                                                                                   │
│                                                                                                                                                                                                   │
│ What to emit: On each assistant message or tool use event, write a progress event JSON file to /workspace/ipc/progress/{run_id}/:                                                                 │
│                                                                                                                                                                                                   │
│ // After processing each SDK message event:                                                                                                                                                       │
│ if (message.type === 'assistant' || message.type === 'tool_use') {                                                                                                                                │
│   const event: WorkerProgressEvent = {                                                                                                                                                            │
│     kind: 'worker_progress',                                                                                                                                                                      │
│     run_id: input.run_id,          // passed in ContainerInput                                                                                                                                    │
│     group_folder: input.groupFolder,                                                                                                                                                              │
│     timestamp: new Date().toISOString(),                                                                                                                                                          │
│     phase: derivePhaseLabel(message),  // helper: "executing bash", "reading file", etc.                                                                                                          │
│     summary: deriveProgressSummary(message),                                                                                                                                                      │
│     tool_used: message.type === 'tool_use' ? message.name : undefined,                                                                                                                            │
│     seq: progressSeq++,                                                                                                                                                                           │
│   };                                                                                                                                                                                              │
│   writeProgressEvent(event);  // writes to /workspace/ipc/progress/{run_id}/{ts}-{seq}.json                                                                                                       │
│ }                                                                                                                                                                                                 │
│                                                                                                                                                                                                   │
│ Throttle: Only emit at most one event per 5 seconds to avoid flooding. Keep a lastProgressAt timestamp.                                                                                           │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Step 4 — Container: Poll for Steering (container/agent-runner/src/index.ts)                                                                                                                       │
│                                                                                                                                                                                                   │
│ Add a steering poller that runs between tool calls.                                                                                                                                               │
│                                                                                                                                                                                                   │
│ Location: In the main agent loop, after each tool use completes and before the next LLM turn.                                                                                                     │
│                                                                                                                                                                                                   │
│ Mechanism: Poll /workspace/ipc/steer/{run_id}.json (if it exists):                                                                                                                                │
│                                                                                                                                                                                                   │
│ async function checkForSteering(runId: string): Promise<string | null> {                                                                                                                          │
│   const steerPath = `/workspace/ipc/steer/${runId}.json`;                                                                                                                                         │
│   if (!fs.existsSync(steerPath)) return null;                                                                                                                                                     │
│   const event = JSON.parse(fs.readFileSync(steerPath, 'utf8')) as WorkerSteerEvent;                                                                                                               │
│   // Write ack file (steer/{run_id}.acked.json) so host knows it was consumed                                                                                                                     │
│   fs.writeFileSync(`/workspace/ipc/steer/${runId}.acked.json`,                                                                                                                                    │
│     JSON.stringify({ steer_id: event.steer_id, acked_at: new Date().toISOString() }));                                                                                                            │
│   fs.unlinkSync(steerPath);  // consume                                                                                                                                                           │
│   return event.message;                                                                                                                                                                           │
│ }                                                                                                                                                                                                 │
│                                                                                                                                                                                                   │
│ Inject steering message into the agent's MessageStream as a follow-up user message (using the existing inputStream pattern already used for IPC input files).                                     │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Step 5 — Container Runner: Mount New Dirs (src/container-runner.ts)                                                                                                                               │
│                                                                                                                                                                                                   │
│ The container-runner sets up mounts for each worker container. Add the two new IPC subdirectories:                                                                                                │
│                                                                                                                                                                                                   │
│ Location: Near existing IPC input mount (around where input/ is mounted).                                                                                                                         │
│                                                                                                                                                                                                   │
│ // Mount steer dir (host → container, read-only from host perspective but container reads it)                                                                                                     │
│ const steerHostPath = path.join(IPC_BASE_DIR, group.folder, 'steer');                                                                                                                             │
│ fs.mkdirSync(steerHostPath, { recursive: true });                                                                                                                                                 │
│ // Mount progress dir (container writes, host reads)                                                                                                                                              │
│ const progressHostPath = path.join(IPC_BASE_DIR, group.folder, 'progress');                                                                                                                       │
│ fs.mkdirSync(progressHostPath, { recursive: true });                                                                                                                                              │
│                                                                                                                                                                                                   │
│ Add to container mount args:                                                                                                                                                                      │
│                                                                                                                                                                                                   │
│ -v {steerHostPath}:/workspace/ipc/steer                                                                                                                                                           │
│ -v {progressHostPath}:/workspace/ipc/progress                                                                                                                                                     │
│                                                                                                                                                                                                   │
│ Also pass run_id in ContainerInput (already in dispatch payload — thread it through from WorkerRunRecord to the container stdin).                                                                 │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Step 6 — Host: Progress Poller (src/ipc.ts)                                                                                                                                                       │
│                                                                                                                                                                                                   │
│ Add a new polling loop alongside the existing IPC watcher. Every 2000ms:                                                                                                                          │
│                                                                                                                                                                                                   │
│ 1. Scan data/ipc/jarvis-worker-*/progress/ for new event files                                                                                                                                    │
│ 2. For each event file: parse → call updateWorkerRunProgress(runId, summary, timestamp)                                                                                                           │
│ 3. If progress summary changed: notify andy-developer group via deps.sendMessage() with a compact summary                                                                                         │
│ 4. Delete processed event files (or keep for audit — configurable)                                                                                                                                │
│ 5. Check for ack files in data/ipc/jarvis-worker-*/steer/*.acked.json → call ackSteeringEvent()                                                                                                   │
│                                                                                                                                                                                                   │
│ Progress notification to andy-developer format:                                                                                                                                                   │
│                                                                                                                                                                                                   │
│ [run-id-short] ↻ {summary}                                                                                                                                                                        │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Step 7 — Host: Steer Worker IPC Action (src/ipc.ts)                                                                                                                                               │
│                                                                                                                                                                                                   │
│ Add steer_worker as a new IPC action type that andy-developer can write:                                                                                                                          │
│                                                                                                                                                                                                   │
│ IPC file format (andy-developer writes to data/ipc/andy-developer/tasks/):                                                                                                                        │
│                                                                                                                                                                                                   │
│ {                                                                                                                                                                                                 │
│   "type": "steer_worker",                                                                                                                                                                         │
│   "run_id": "run-20260301-042",                                                                                                                                                                   │
│   "message": "also handle the null case in the error path"                                                                                                                                        │
│ }                                                                                                                                                                                                 │
│                                                                                                                                                                                                   │
│ Processing in processTaskIpc():                                                                                                                                                                   │
│                                                                                                                                                                                                   │
│ 1. Validate run_id exists and is in running status                                                                                                                                                │
│ 2. Validate source is andy-developer                                                                                                                                                              │
│ 3. Build WorkerSteerEvent, write to data/ipc/{target_worker_folder}/steer/{run_id}.json                                                                                                           │
│ 4. Call insertSteeringEvent() to persist                                                                                                                                                          │
│ 5. Acknowledge back to andy-developer: "↗ Steering sent to {run_id}"                                                                                                                              │
│                                                                                                                                                                                                   │
│ Existing validateAndyToWorkerPayload does NOT apply here — steer_worker has its own lightweight validation (run must be active, message must be non-empty).                                       │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Step 8 — Andy Group Context (groups/andy-developer/CLAUDE.md)                                                                                                                                     │
│                                                                                                                                                                                                   │
│ Add a doc trigger so andy-developer knows about the steer capability. This is a docs-only change — no code:                                                                                       │
│                                                                                                                                                                                                   │
│ steer worker / course correct / adjust running task → read /workspace/group/docs/worker-steering.md                                                                                               │
│                                                                                                                                                                                                   │
│ Create groups/andy-developer/docs/worker-steering.md explaining:                                                                                                                                  │
│                                                                                                                                                                                                   │
│ - How to write a steer_worker IPC task                                                                                                                                                            │
│ - When to use it (worker has gone off-track, new requirement mid-task)                                                                                                                            │
│ - Format and constraints                                                                                                                                                                          │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Files Modified                                                                                                                                                                                    │
│                                                                                                                                                                                                   │
│ ┌─────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────┐                                                                     │
│ │                File                 │                                       Change                                        │                                                                     │
│ ├─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤                                                                     │
│ │ src/types.ts                        │ Add WorkerProgressEvent, WorkerSteerEvent interfaces                                │                                                                     │
│ ├─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤                                                                     │
│ │ src/db.ts                           │ Add worker_steering_events table, progress columns on worker_runs, new DB functions │                                                                     │
│ ├─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤                                                                     │
│ │ src/ipc.ts                          │ Add progress poller, steer_worker action processing, ack handler                    │                                                                     │
│ ├─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤                                                                     │
│ │ src/container-runner.ts             │ Mount steer/ and progress/ dirs, pass run_id in ContainerInput                      │                                                                     │
│ ├─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤                                                                     │
│ │ container/agent-runner/src/index.ts │ Add progress emitter, steer poller                                                  │                                                                     │
│ ├─────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────┤                                                                     │
│ │ groups/andy-developer/CLAUDE.md     │ Add steer trigger line                                                              │                                                                     │
│ └─────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────┘                                                                     │
│                                                                                                                                                                                                   │
│ New Files                                                                                                                                                                                         │
│                                                                                                                                                                                                   │
│ ┌───────────────────────────────────────────────┬─────────────────────────────────────────┐                                                                                                       │
│ │                     File                      │                 Purpose                 │                                                                                                       │
│ ├───────────────────────────────────────────────┼─────────────────────────────────────────┤                                                                                                       │
│ │ groups/andy-developer/docs/worker-steering.md │ Steering usage guide for andy-developer │                                                                                                       │
│ └───────────────────────────────────────────────┴─────────────────────────────────────────┘                                                                                                       │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Verification                                                                                                                                                                                      │
│                                                                                                                                                                                                   │
│ 1. npm run build — TypeScript must compile clean                                                                                                                                                  │
│ 2. npm test — all 474 existing tests must pass                                                                                                                                                    │
│ 3. Manual smoke test:                                                                                                                                                                             │
│   - Dispatch a long-running task to jarvis-worker-1                                                                                                                                               │
│   - Observe progress events appearing in andy-developer group                                                                                                                                     │
│   - Write a steer_worker IPC task from andy-developer                                                                                                                                             │
│   - Confirm ack file appears and steering is consumed by container                                                                                                                                │
│   - Confirm worker_steering_events table has row with status = 'acked'                                                                                                                            │
│ 4. New unit tests:                                                                                                                                                                                │
│   - src/worker-progress.test.ts — progress event file parsing + DB update                                                                                                                         │
│   - src/ipc.test.ts additions — steer_worker action validation (valid run, invalid run_id, non-andy source blocked)                                                                               │
│                                                                                                                                                                                                   │
│ ---                                                                                                                                                                                               │
│ Non-Goals (Out of Scope)                                                                                                                                                                          │
│                                                                                                                                                                                                   │
│ - UI for progress visualization (WhatsApp text notifications are sufficient)                                                                                                                      │
│ - Steering from main group directly (must go via andy-developer ownership chain)                                                                                                                  │
│ - Multiple simultaneous pending steers (overwrite model: latest steer wins)                                                                                                                       │
│ - Persistent progress event history (delete after processing; DB has last_progress_summary)  