# NanoClaw Jarvis Dispatch Contract

Canonical contract for `jarvis-worker-*` dispatch and completion validation.

## Dispatch Requirements

Worker dispatch must be a JSON object (plain text is rejected).

```json
{
  "run_id": "task-20260222-001",
  "task_type": "implement",
  "input": "Implement strict worker dispatch validation",
  "repo": "openclaw-gurusharan/nanoclaw",
  "branch": "jarvis-dispatch-contract",
  "acceptance_tests": [
    "npm run build",
    "npm test"
  ],
  "output_contract": {
    "required_fields": [
      "run_id",
      "branch",
      "commit_sha",
      "files_changed",
      "test_result",
      "risk",
      "pr_url"
    ]
  },
  "priority": "high"
}
```

## Field Rules

| Field | Rule |
|-------|------|
| `run_id` | required, max 64 chars, no whitespace |
| `task_type` | one of `analyze`, `implement`, `fix`, `refactor`, `test`, `release`, `research`, `code` |
| `input` | required non-empty string |
| `repo` | required in `owner/repo` format |
| `branch` | required and must match `jarvis-<feature>` |
| `acceptance_tests` | required non-empty string array |
| `output_contract.required_fields` | required non-empty array containing completion fields |

## Completion Requirements

Worker output must include a completion block:

```text
<completion>
{
  "run_id": "task-20260222-001",
  "branch": "jarvis-dispatch-contract",
  "commit_sha": "abc1234",
  "files_changed": ["src/index.ts", "src/dispatch-validator.ts"],
  "test_result": "npm run build && npm test passed",
  "risk": "low - isolated to worker dispatch path",
  "pr_url": "https://github.com/..."
}
</completion>
```

`pr_skipped_reason` may be used instead of `pr_url`.

## Validation Gates

A worker run transitions to `review_requested` only when:

1. completion block is parseable JSON
2. completion includes all required artifacts
3. completion `run_id` matches dispatch `run_id`

Otherwise the run transitions to `failed_contract`.

## Retry Semantics

| Existing status for `run_id` | Behavior |
|------------------------------|----------|
| `failed` | retry allowed, `retry_count` incremented |
| `failed_contract` | retry allowed, `retry_count` incremented |
| `running` | duplicate blocked |
| `review_requested` | duplicate blocked |
| `done` | duplicate blocked |
