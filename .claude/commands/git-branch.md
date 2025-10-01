---
allowed-tools: Bash(git:*)
description: Create a new branch with proper naming based on the type of work being done
---

# Create New Branch

Create a new branch with a descriptive name based on the type of work you're about to do.

## Command Usage

```bash
# Basic usage - you'll be prompted for details
./create-branch.sh

# With arguments
./create-branch.sh <type> <description>

# Examples
./create-branch.sh feature "user authentication"
./create-branch.sh fix "login validation bug"
./create-branch.sh docs "api endpoints"
```

## Interactive Branch Creation Steps

1. **Check current state and ensure you're up to date:**

   ```bash
   git status
   git fetch origin
   ```

2. **Determine branch type** (accept user input):
   - `feature` - New functionality
   - `fix` - Bug fixes
   - `hotfix` - Urgent production fixes
   - `refactor` - Code improvements
   - `docs` - Documentation
   - `test` - Test additions/updates
   - `chore` - Maintenance tasks
   - `experiment` - Experimental features

3. **Get branch description** (from user):

   ```bash
   # Prompt: "What is this branch for? (brief description):"
   # User provides: "add user authentication"
   # Result: feature/add-user-authentication
   ```

4. **Create and checkout the new branch:**
   ```bash
   git checkout -b <type>/<formatted-description>
   ```

## Branch Name Formatting Rules

**Automatic formatting applied:**

- Convert spaces to hyphens
- Convert to lowercase
- Remove special characters
- Limit length to 50 characters
- Remove duplicate hyphens

**Examples of formatting:**

- Input: `"User Authentication System"` → `user-authentication-system`
- Input: `"Fix: Login Bug!!"` → `fix-login-bug`
- Input: `"API v2.0 endpoints"` → `api-v2-0-endpoints`

## Complete Workflow Script

```bash
#!/bin/bash

# Function to format branch name
format_branch_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' | cut -c1-50
}

# 1. Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

# 2. Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo "Warning: You have uncommitted changes"
    echo "Would you like to stash them? (y/n)"
    read -r response
    if [[ "$response" == "y" ]]; then
        git stash save "WIP: creating new branch"
    else
        echo "Please commit or stash your changes first"
        exit 1
    fi
fi

# 3. Get branch type (from argument or prompt)
if [ -n "$1" ]; then
    BRANCH_TYPE="$1"
else
    echo "Select branch type:"
    echo "1) feature - New functionality"
    echo "2) fix - Bug fix"
    echo "3) hotfix - Urgent production fix"
    echo "4) refactor - Code improvement"
    echo "5) docs - Documentation"
    echo "6) test - Tests"
    echo "7) chore - Maintenance"
    echo "8) experiment - Experimental"
    read -p "Enter number (1-8): " choice

    case $choice in
        1) BRANCH_TYPE="feature" ;;
        2) BRANCH_TYPE="fix" ;;
        3) BRANCH_TYPE="hotfix" ;;
        4) BRANCH_TYPE="refactor" ;;
        5) BRANCH_TYPE="docs" ;;
        6) BRANCH_TYPE="test" ;;
        7) BRANCH_TYPE="chore" ;;
        8) BRANCH_TYPE="experiment" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

# 4. Get branch description (from argument or prompt)
if [ -n "$2" ]; then
    DESCRIPTION="$2"
else
    read -p "Brief description of the work: " DESCRIPTION
fi

# 5. Format the branch name
FORMATTED_DESC=$(format_branch_name "$DESCRIPTION")
BRANCH_NAME="${BRANCH_TYPE}/${FORMATTED_DESC}"

# 6. Confirm branch creation
echo ""
echo "Creating branch: $BRANCH_NAME"
echo "From: $(git branch --show-current)"
read -p "Proceed? (y/n): " confirm

if [[ "$confirm" != "y" ]]; then
    echo "Branch creation cancelled"
    exit 0
fi

# 7. Create and checkout the new branch
git checkout -b "$BRANCH_NAME"

# 8. Display status
echo ""
echo "✅ Successfully created and switched to: $BRANCH_NAME"
echo ""
git status --short --branch
```

## Quick Examples

```bash
# Feature branch for authentication
git checkout -b feature/user-authentication

# Bug fix for login issue
git checkout -b fix/login-validation-error

# Hotfix for production
git checkout -b hotfix/critical-payment-bug

# Documentation update
git checkout -b docs/api-endpoint-descriptions

# Refactoring API structure
git checkout -b refactor/simplify-api-routes

# Experimental feature
git checkout -b experiment/ai-recommendations
```

## Branch Creation Best Practices

1. **Always pull latest changes first:**

   ```bash
   git pull origin main  # or master/develop
   ```

2. **Create from the right base branch:**

   ```bash
   # For features (from develop)
   git checkout develop
   git checkout -b feature/new-feature

   # For hotfixes (from main/master)
   git checkout main
   git checkout -b hotfix/urgent-fix
   ```

3. **Keep branch names:**
   - **Short** - Under 50 characters
   - **Descriptive** - Clear about what work is being done
   - **Consistent** - Follow team conventions
   - **Lowercase** - Avoid case sensitivity issues

## Advanced Options

**Create branch from specific commit:**

```bash
git checkout -b feature/new-feature abc123f
```

**Create branch from remote branch:**

```bash
git checkout -b feature/new-feature origin/develop
```

**Create branch and set upstream:**

```bash
git checkout -b feature/new-feature
git push -u origin feature/new-feature
```

## Validation Checks

Before creating a branch, ensure:

- [ ] You're in the correct repository
- [ ] Working directory is clean (no uncommitted changes)
- [ ] You've pulled the latest changes
- [ ] Branch name follows conventions
- [ ] Branch doesn't already exist

## Error Handling

**If branch already exists:**

```bash
# Check existing branches
git branch | grep <branch-name>

# Delete local branch if needed
git branch -d <branch-name>

# Or use a different name
git checkout -b <branch-name>-v2
```

**If you're in the wrong base branch:**

```bash
# Check current branch
git branch --show-current

# Switch to correct base
git checkout main

# Then create new branch
git checkout -b feature/new-feature
```

## Post-Creation Steps

After creating your branch:

1. **Push to remote (optional but recommended):**

   ```bash
   git push -u origin HEAD
   ```

2. **Verify branch creation:**

   ```bash
   git branch --show-current
   git log --oneline -1
   ```

3. **Start working:**
   - Make your changes
   - Commit regularly
   - Push to remote periodically
