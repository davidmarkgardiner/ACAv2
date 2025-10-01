---
allowed-tools: Bash(git:*)
description: Understand the current state of the git repository
---

# Push to GitHub

Stage, commit, and push changes to GitHub with a well-crafted commit message.

## Steps to Follow

1. **ALWAYS start by running `git status`** to see what files have changed

2. **Stage the appropriate files:**

   ```bash
   # Stage all changes
   git add .

   # Or stage specific files
   git add <file1> <file2>
   ```

3. **Create a meaningful commit message** following this format:

   ```bash
   git commit -m "type: brief description

   - Detailed point about what changed
   - Another specific change made
   - Why this change was necessary"
   ```

4. **Push to the current branch:**
   ```bash
   git push origin HEAD
   ```

## Commit Message Guidelines

**Use conventional commit types:**

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `style:` - Code style/formatting changes
- `refactor:` - Code refactoring
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks

**Good commit message example:**

```
feat: add user authentication system

- Implement JWT-based login and registration
- Add password hashing with bcrypt
- Create middleware for protected routes
- Add user session management
```

**Bad commit message examples:**

- `updated stuff`
- `fixes`
- `changes`
- `wip`

## Important Notes

- **Always review changes** with `git diff` before committing
- **Write descriptive commit messages** that explain what and why, not just what
- **Push to current branch** - use `git push origin HEAD` to avoid branch name mistakes
- **If push fails**, check if you need to pull first: `git pull origin <branch-name>`
- **DO NOT credit yourself** in commit messages

## Common Workflow

```bash
# 1. Check status
git status

# secret scanner
./scripts/scan-secrets.sh

IMPORTANT! stop is secrets detected
# 2. Review changes
git diff

# 3. Stage files
git add .




# 4. Commit with good message
git commit -m "fix: resolve login validation bug

- Fix email validation regex pattern
- Add proper error handling for invalid credentials
- Update error messages to be more user-friendly"

# 5. Push to current branch
git push origin HEAD
```

## Troubleshooting

**If push is rejected:**

```bash
# Pull latest changes first
git pull origin <current-branch>

# Then push again
git push origin HEAD
```

**If you made a mistake in the commit message:**

```bash
# Amend the last commit message
git commit --amend -m "corrected message"

# Force push (only if you haven't shared the commit yet)
git push origin HEAD --force-with-lease
```
