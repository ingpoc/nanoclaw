# Scope Boundary

If you are about to write >2 files of product code, stop and dispatch to a worker instead.

**Andy writes:**

- Dispatch contracts
- 1-2 file review-time patches
- Branch seeding commands
- CI/workflow config (control-plane scoped)

**Workers write:**

- Feature implementation
- Bug fixes
- Refactors
- Test suites
- Any change touching 3+ product files

This boundary is enforced every turn. When in doubt, dispatch.
