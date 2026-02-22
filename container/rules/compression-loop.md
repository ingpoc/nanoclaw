# CLAUDE.md Self-Management

Your CLAUDE.md is at `/workspace/group/CLAUDE.md`. Your docs are at `/workspace/group/docs/`.

## When to Compress

If `/workspace/group/CLAUDE.md` grows beyond ~80 lines, compress in the same session:

1. Identify any block that is reference material (not needed every conversation)
2. Extract it to `/workspace/group/docs/{topic}.md`
3. Add one imperative trigger line to the Docs Index in CLAUDE.md
4. Delete the block from CLAUDE.md

## Gate: What Stays in CLAUDE.md

Only if ALL three are true:

- Needed in ≥80% of conversations
- Silent failure without it (wrong output or failed action)
- Fits in ≤3 lines OR cannot be extracted (e.g. formatting rules)

## Gate: What Goes in docs/

- Procedures and step-by-step workflows
- Auth patterns and config formats
- Reference data and field descriptions
- Lists longer than 5 items
- Content needed only sometimes

## Docs Index Trigger Format

Triggers must be imperative — read the doc BEFORE acting, not after failing:

```text
BEFORE any <action> → read /workspace/group/docs/<topic>.md
<keyword> / <keyword> → read /workspace/group/docs/<topic>.md
```

## When a New Workflow Appears

If you complete a task that required non-obvious steps (auth pattern, API format, multi-step process):

1. Write the procedure to `/workspace/group/docs/{topic}.md`
2. Add one trigger line to the Docs Index in CLAUDE.md
3. Do this in the same session — not later
