# Create GitHub Issue

Create a clear, actionable GitHub issue that any engineer can pick up and work on: `$ARGUMENTS`

## Steps to Follow

1. **ALWAYS start by running `git status`** to understand the current state

2. **Use this template for issue creation:**

   ```bash
   gh issue create \
     --title "Clear, specific title describing the work" \
     --body "$(cat <<EOF
   ## Problem Statement
   Brief description of what needs to be done and why.

   ## Acceptance Criteria
   - [ ] Specific, testable requirement 1
   - [ ] Specific, testable requirement 2
   - [ ] Specific, testable requirement 3

   ## Technical Details
   - Files/components that need changes:
   - API endpoints affected:
   - Dependencies/libraries involved:

   ## Additional Context
   - Related issues: #123
   - Screenshots/mockups: (if applicable)
   - Performance considerations:
   - Testing requirements:
   EOF
   )"
   ```

3. **Add appropriate labels:**

   ```bash
   # Add labels during creation
   gh issue create --label "bug,high-priority" --title "..." --body "..."

   # Or add labels after creation
   gh issue edit <issue-number> --add-label "enhancement,backend"
   ```

4. **Assign if needed:**
   ```bash
   # Assign to specific person
   gh issue create --assignee username --title "..." --body "..."
   ```

## Issue Title Guidelines

**Good titles (specific and actionable):**

- `Add user profile image upload functionality`
- `Fix memory leak in data processing pipeline`
- `Implement email notification system for order updates`
- `Optimize database queries for user dashboard`

**Bad titles (vague and unclear):**

- `Fix bug`
- `Update UI`
- `Improve performance`
- `Add feature`

## Writing Clear Acceptance Criteria

**Make each criterion:**

- **Specific** - No ambiguity about what "done" looks like
- **Testable** - Can be verified through testing or demonstration
- **Actionable** - Clear what needs to be implemented

**Example - Good Acceptance Criteria:**

```
- [ ] User can upload profile images up to 5MB in JPEG/PNG format
- [ ] Images are automatically resized to 300x300px
- [ ] Old profile image is deleted when new one is uploaded
- [ ] Upload progress indicator shows during file transfer
- [ ] Error messages display for invalid file types or size limits
```

**Example - Bad Acceptance Criteria:**

```
- [ ] Make upload work
- [ ] Handle errors
- [ ] Improve user experience
```

## Technical Details Section

Always include:

- **Files/directories** that likely need changes
- **Database tables** that might be affected
- **API endpoints** to be created/modified
- **External services** or dependencies involved
- **Configuration changes** required

## Common Labels to Use

- **Type:** `bug`, `enhancement`, `feature`, `documentation`
- **Priority:** `low`, `medium`, `high`, `critical`
- **Area:** `frontend`, `backend`, `database`, `devops`, `security`
- **Size:** `small`, `medium`, `large`, `epic`
- **Status:** `ready`, `blocked`, `in-progress`

## Complete Example

```bash
gh issue create \
  --title "Implement password reset functionality via email" \
  --label "feature,backend,medium" \
  --body "$(cat <<EOF
## Problem Statement
Users currently cannot reset their passwords if forgotten. We need to implement a secure email-based password reset flow.

## Acceptance Criteria
- [ ] User can request password reset from login page
- [ ] System sends reset email with secure token (expires in 1 hour)
- [ ] Reset link leads to password change form
- [ ] New password must meet security requirements
- [ ] Old sessions are invalidated after password change
- [ ] Rate limiting prevents abuse (max 3 requests per hour per email)

## Technical Details
- Files/components that need changes:
  - \`/routes/auth.js\` - Add reset endpoints
  - \`/models/User.js\` - Add reset token fields
  - \`/views/reset-password.ejs\` - New reset form
  - \`/services/email.js\` - Reset email template
- API endpoints affected:
  - \`POST /auth/forgot-password\`
  - \`POST /auth/reset-password\`
  - \`GET /auth/reset/:token\`
- Dependencies/libraries involved:
  - \`nodemailer\` for sending emails
  - \`crypto\` for generating secure tokens
  - \`bcrypt\` for password hashing

## Additional Context
- Related issues: #234 (email service setup)
- Security considerations: Use cryptographically secure tokens
- Testing requirements: Unit tests for all endpoints, integration test for full flow
- Email template should match existing brand styling
EOF
)"
```

## Quality Checklist

Before creating the issue, ensure:

- [ ] Title clearly describes the work to be done
- [ ] Problem statement explains the "why"
- [ ] Acceptance criteria are specific and testable
- [ ] Technical details help engineers understand scope
- [ ] Appropriate labels are applied
- [ ] Related issues/PRs are referenced
- [ ] Enough context for someone else to pick up the work

## Remember

- **Be specific, not generic** - Another engineer should understand exactly what to build
- **Include edge cases** in acceptance criteria
- **Link related work** - Reference other issues, PRs, or documentation
- **Consider the full user journey** - Not just the happy path
- **DO NOT credit yourself** in issue descriptions
