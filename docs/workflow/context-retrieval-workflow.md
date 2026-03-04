# Context Retrieval Workflow

High-signal retrieval path for maximum quality with minimum token usage.

## Objective

1. Retrieve only the context required to execute the current task correctly.
2. Keep default retrieval cheap and deterministic.
3. Escalate retrieval depth only when evidence quality is insufficient.

## Default Policy

1. Use direct `qmd` retrieval for docs/code context.
2. Use `qctx` only for session continuity (`--bootstrap`, `--close`) and session-memory lookup.
3. Keep contract docs trigger-based via `CLAUDE.md` Docs Index; do not bulk-load docs.

## Retrieval Ladder (Required)

1. Run scoped BM25 first:
   - `qmd search "<query>" -c <collection> --files -n 3`
2. If top hit is clear, fetch only one snippet:
   - `qmd get <docid> -l 60`
3. Escalate only on weak/no hit:
   - `qmd query "<query>" -c <collection> --files -n 5 --min-score 0.35`
4. After escalation, still fetch only top 1:
   - `qmd get <docid> -l 60` (max `80`)
5. Stop once one high-confidence source confirms the decision.

## Collection Routing

1. Workflow/process/policy docs -> `docs` collection
2. Implementation behavior/code paths -> `src` (and `scripts` when relevant)
3. Session memory/continuity -> `sessions` via `qctx` or scoped `qmd` query

## Hard Limits (Default)

1. BM25 result count: `-n 3`
2. Hybrid result count: `-n 5` max
3. Snippet fetch: top `1` file, `60` lines (max `80`)
4. Do not use `--all` as default
5. Do not use full-document retrieval (`--full`) for discovery

## Anti-Patterns (Do Not Use)

1. Broad unscoped scans before intent routing (`rg` across large trees as first step).
2. Reading full `CLAUDE.md` plus many workflow docs for every prompt.
3. Always-on hybrid retrieval for simple keyword/exact-match tasks.
4. Sessions-first retrieval for docs/code implementation questions.
5. Fetching multiple full files "just in case."
6. Running duplicate retrieval passes (`search` + `query` + `grep`) without a stop rule.
7. Using high `top-k` defaults (`10+`) for normal tasks.
8. Running incident fallback retrieval for non-incident intents.

## Fast Profiles

1. Strict (default): BM25 `n=3`, no fetch unless needed.
2. Balanced: BM25 `n=3`, fetch top 1 at `l=60`.
3. Deep (on-demand only): hybrid `n=5`, `min-score`, fetch top 1 at `l=60-80`.

