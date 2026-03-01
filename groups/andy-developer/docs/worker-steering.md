# Worker Steering

Send course-correction messages to an in-flight Jarvis worker without cancelling and redispatching.

## When to Use

| Situation | Action |
|-----------|--------|
| Worker went off-track (wrong file, wrong approach) | Steer to redirect |
| New requirement discovered mid-task | Steer with additional context |
| Worker needs to skip a blocked step | Steer with alternative path |
| Task completed but follow-up needed | Wait for completion, then dispatch new run |

Do NOT steer a worker that has already completed or failed — check `worker_runs.json` first.

## How to Write a Steer Task

Write a JSON file to your IPC tasks directory:

```json
{
  "type": "steer_worker",
  "run_id": "run-20260301-042",
  "message": "Focus only on the null case in the error path — skip the other edge cases for now"
}
```

File path: `/workspace/ipc/tasks/{timestamp}-steer.json`

## Constraints

- Source must be `andy-developer` — no other group can steer workers.
- `run_id` must exist and have `status = 'running'`.
- One pending steer at a time per run (latest steer overwrites any unconsumed prior steer).
- Message is plain text; keep it concise (1-3 sentences).

## What Happens

1. Host writes steer event to `data/ipc/{worker-folder}/steer/{run_id}.json`.
2. Worker container polls for steer file every 500ms during active query.
3. When found: worker injects message as a follow-up user turn and acknowledges.
4. Host reads ack file (`{run_id}.acked.json`) and marks `status = 'acked'` in DB.
5. You receive `↗ Steering sent to {run_id}` confirmation.
6. Progress updates continue as `[run-id] ↻ {summary}` messages.

## Steer vs Cancel-Redispatch

| | Steer | Cancel + Redispatch |
|---|---|---|
| Worker state | Preserved (session continues) | Lost (fresh session) |
| Speed | Fast (next poll cycle) | Slow (full container restart) |
| Use when | Minor course correction | Fundamental direction change |
