# Review Evidence Bar

Minimum evidence before approving worker completion:

| Check | Required |
|-------|----------|
| Git SHA | Real commit hash, not placeholder |
| Tests ran | Actual test output/exit code, not "tests pass" |
| Files changed | `files_changed` list is non-empty for code tasks |
| Risk assessment | Specific to the change, not generic "low risk" |

If any evidence is missing or generic, request rework with specific asks.
