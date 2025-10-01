---
allowed-tools: Bash(git:*), Bash(gh:*)
description: Create a pull request with proper GitHub workflow
---

# Create a PR

Create a pull request against the specified branch: `$ARGUMENTS`

## Steps to Follow

1. **ALWAYS start by running `git status`** to check what branch you're on

2. **Use this template for PR creation:**

   ```bash
   gh pr create --base dev --head <current-branch> \
     --title "Clear & concise title" \
     --body "Clear, detailed description of changes"
   ```

3. **Always create Pull Requests against the branch the user specifies** (or default to 'dev' branch). **NEVER EVER AGAINST 'main'**

4. **If you run into issues, STOP and explain the error to the user**

## Important Reminders

- Use the GitHub CLI (`gh`) for all GitHub-related tasks
- Make titles clear & concise, and descriptions detailed yet focused
- **DO NOT credit yourself** in PR titles or descriptions
- Always verify the target branch before creating the PR
- Include relevant context about what changed and why

## Common Commands

```bash
# Check current status
git status

# Create PR with interactive prompts
gh pr create

# Create PR with specific parameters
gh pr create --base <target-branch> --head <source-branch> --title "Title" --body "Description"

# List existing PRs
gh pr list

# View PR details
gh pr view <pr-number>
```

<example>
- `gh pr create --base dev --head david --title "FIX: clear & concise title" --body "clear, detailed description of changes"`
</example>
