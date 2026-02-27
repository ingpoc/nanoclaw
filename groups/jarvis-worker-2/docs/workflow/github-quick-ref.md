# GitHub Quick Reference (Container)

`GITHUB_TOKEN` and `GH_TOKEN` are pre-set in your environment. Git credentials are pre-configured.

```bash
# Clone a repo into your workspace
cd /workspace/group/workspace
git clone https://openclaw-gurusharan:$GITHUB_TOKEN@github.com/openclaw-gurusharan/REPO.git

# List repos
gh repo list openclaw-gurusharan --limit 50
```

For push/PR auth details and account isolation rules → read
`/workspace/group/docs/workflow/github-account-isolation.md`
