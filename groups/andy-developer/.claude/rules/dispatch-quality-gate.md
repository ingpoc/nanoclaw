# Dispatch Quality Gate

Before dispatching to a worker, verify ALL of the following:

1. **Branch exists remotely** — `git ls-remote --heads origin <branch>` returns a SHA
2. **Repo accessible** — worker can clone/fetch the target repo
3. **No duplicate runs** — check `worker_runs.json` for existing running tasks on target worker
4. **Acceptance tests are concrete** — tests reference real files/functions, not aspirational descriptions

If any check fails, fix it before dispatching. Do not dispatch and hope.
