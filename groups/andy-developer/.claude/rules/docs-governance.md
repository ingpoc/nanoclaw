# Docs Governance

Applies when editing CLAUDE.md, docs/, or worker dispatch contracts.

## CLAUDE.md Compression Gate

Only keep content inline when ALL are true:

1. Needed in ≥80% of sessions
2. Silent failure without it
3. Fits in ≤3 lines

Everything else → `docs/` with one trigger line in Docs Index.

## Before Creating a New Doc

1. What gap exists that current docs don't cover?
2. Which existing doc is closest — can it absorb this?
3. What single boundary does the new doc own?

If answer 2 is strong, extend existing doc instead.

## Sync Requirements

When docs change:

- Update CLAUDE.md Docs Index triggers
- Remove stale references to deleted/renamed docs
- One canonical doc per topic — delete superseded copies

## Notion Memory Gate

- Decisions, constraints, lessons → write to Notion (`notion_create_memory`)
- Stale project plans → move to Notion, delete from filesystem
- Do not store execution state in static docs — use Linear for work items, Notion for memory
