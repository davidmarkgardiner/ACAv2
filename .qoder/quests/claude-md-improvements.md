# CLAUDE.MD Improvements for mcp-template

## Overview

This document outlines improvements to the CLAUDE.MD file and .claude configuration for the mcp-template repository, following best practices from the Claude Code agentic coding guide. The improvements focus on optimizing context gathering, customizing tool allowlists, and enhancing workflow efficiency.

Based on analysis of the existing CLAUDE.MD file and project structure, the current configuration provides a solid foundation but can be enhanced to better align with Claude Code best practices for agentic development workflows. The mcp-template is a modern business template built with Astro, React, Supabase, and Stripe, designed for AI-assisted development.

## 1. CLAUDE.MD Structure Improvements

### Current Issues
The existing CLAUDE.MD file is comprehensive but could be better organized for efficient context consumption by Claude. The file is quite long which may impact token usage and context focus. Additionally, some sections could be more concise and focused on the most frequently used information.

### Recommended Improvements

#### a. Streamline Core Information
Organize the most frequently used information at the beginning of CLAUDE.MD:

```markdown
# Claude Configuration for mcp-template

## Quick Reference
- **Primary Framework**: Astro v5.13.7 with React islands
- **Backend**: Supabase (PostgreSQL + Auth + Realtime)
- **Payments**: Stripe integration
- **Styling**: Tailwind CSS + shadcn/ui primitives
- **Testing**: Vitest (unit) + Playwright (E2E)

## Essential Bash Commands
- `npm run dev` - Start development server
- `npm run build` - Build for production
- `npm run test` - Run unit tests
- `npm run test:e2e` - Run E2E tests
- `npm run health` - Run health check API

## Code Style Guidelines
- Use ES modules (import/export) syntax
- Destructure imports when possible
- TypeScript strict mode - no 'any' types
- Explicit return types for all functions
- Use shadcn/ui components when available
- Follow existing component patterns (see src/components/ui/button.tsx)

## Workflow Best Practices
- Always run type checking after changes
- Prefer running single tests rather than full suite
- Commit message format: type(scope): description
```

#### b. Add Repository-Specific Context
Include information that's unique to this repository:

```markdown
## Project Structure
- `src/components/` - React components (shadcn/ui + custom)
- `src/pages/api/` - API endpoints (Astro API routes)
- `src/lib/` - Utility functions and service clients
- `supabase/migrations/` - Database schema migrations
- `tests/e2e/` - Playwright E2E tests

## Key Files
- `src/lib/supabase.ts` - Supabase client configuration
- `src/lib/stripe.ts` - Stripe client configuration
- `src/lib/utils.ts` - Shared utility functions (cn helper)
- `src/pages/api/health.ts` - Health check endpoint example
```

## 2. Tool Allowlist Optimization

### Current Configuration Analysis
The current `.claude/settings.json` has a reasonable allowlist but can be optimized for the specific workflows in this project:

```json
{
  "permissions": {
    "allow": [
      "Bash(mkdir:*)",
      "Bash(uv:*)",
      "Bash(find:*)",
      "Bash(mv:*)",
      "Bash(grep:*)",
      "Bash(npm:*)",
      "Bash(ls:*)",
      "Bash(cp:*)",
      "Write",
      "Edit",
      "Bash(chmod:*)",
      "Bash(touch:*)"
    ],
    "deny": []
  }
}
```

### Recommended Improvements

#### a. Add Git Commands
Since Claude can effectively handle git operations, add commonly used git commands. Based on the existing git command files in `.claude/commands/`, we should include:

```json
{
  "permissions": {
    "allow": [
      "Bash(mkdir:*)",
      "Bash(uv:*)",
      "Bash(find:*)",
      "Bash(mv:*)",
      "Bash(grep:*)",
      "Bash(npm:*)",
      "Bash(ls:*)",
      "Bash(cp:*)",
      "Bash(git:*)",
      "Bash(gh:*)",
      "Write",
      "Edit",
      "Bash(chmod:*)",
      "Bash(touch:*)"
    ],
    "deny": []
  }
}
```

#### b. Add Database and Payment Tools
Include specific tools for database and payment operations based on the project's MCP configuration:

```json
{
  "permissions": {
    "allow": [
      "Bash(mkdir:*)",
      "Bash(uv:*)",
      "Bash(find:*)",
      "Bash(mv:*)",
      "Bash(grep:*)",
      "Bash(npm:*)",
      "Bash(ls:*)",
      "Bash(cp:*)",
      "Bash(git:*)",
      "Bash(gh:*)",
      "Bash(supabase:*)",
      "Write",
      "Edit",
      "Bash(chmod:*)",
      "Bash(touch:*)",
      "mcp__supabase__*",
      "mcp__stripe__*"
    ],
    "deny": []
  }
}
```

## 3. Custom Slash Command Improvements

### Current Commands Analysis
The repository already has a comprehensive set of custom commands in `.claude/commands/`, including:
- `/component` - Generate React components with TypeScript and Tailwind CSS
- `/test` - Generate Playwright E2E tests
- `/api` - Create Astro API endpoints with Supabase integration
- Git-related commands (`/git-status`, `/git-branch`, etc.)
- Deployment commands (`/deploy`)
- Service-specific commands (`/stripe`, `/supa`, `/shadcn`)

### Recommended Improvements

#### a. Add Common Development Workflows
Create new commands for frequently used workflows:

**.claude/commands/setup-dev.md**
```markdown
---
allowed-tools: Read, Write, Bash
description: Set up local development environment
---

# /setup-dev - Set up development environment

Set up the local development environment for the mcp-template project.

This command will:
1. Install npm dependencies
2. Check for required environment variables
3. Run database migrations
4. Start the development server

Usage:
/setup-dev
```

**.claude/commands/typecheck.md**
```markdown
---
allowed-tools: Bash
description: Run TypeScript type checking
---

# /typecheck - Run TypeScript type checking

Run TypeScript type checking across the entire codebase to catch type errors.

Usage:
/typecheck
```

**.claude/commands/health-check.md**
```markdown
---
allowed-tools: Bash
description: Run health check API endpoint
---

# /health-check - Run health check API endpoint

Run the health check API endpoint to verify all services are working correctly.

Usage:
/health-check
```

#### b. Optimize Existing Commands
Improve existing commands by adding more specific guidance based on the project's actual structure:

**.claude/commands/component.md** (add to existing)
```markdown
## Best Practices

1. Always use TypeScript interfaces for props (see src/components/ui/button.tsx for example)
2. Implement proper error handling
3. Add loading states for async operations
4. Ensure mobile responsiveness
5. Include accessibility attributes (ARIA)
6. Use shadcn/ui components when possible
7. Add test file with --test flag

## Component Categories

- **ui** - Reusable UI components (buttons, inputs, cards)
- **layout** - Page layout components (headers, footers, navigation)
- **shop** - E-commerce specific components (product cards, cart)
- **booking** - Service booking components (calendar, forms)
- **admin** - Admin dashboard components

## Component Structure

Follow the pattern established in src/components/ui/button.tsx:
- Use React.forwardRef for proper ref handling
- Implement VariantProps from class-variance-authority
- Use cn helper from '@/lib/utils' for class merging
- Include proper TypeScript interfaces
```

## 4. Agent Specialization Improvements

### Current Agent Configuration
The repository has specialized agents in `.claude/agents/` including:
- Frontend Agent (React components, Astro pages)
- Backend Agent (API endpoints, Supabase integration)
- Database Agent (PostgreSQL, schema design)
- Payment Agent (Stripe integration)
- Testing Agent (Vitest, Playwright)

These agents are configured to work with the project's specific MCP servers and tools.

### Recommended Improvements

#### a. Clarify Agent Responsibilities
Make agent responsibilities more specific based on the project structure:

**.claude/agents/frontend-agent.md**
```markdown
---
name: frontend-agent
description: Frontend specialist for React components, Astro pages, and UI/UX implementation
tools: Read, Write, Edit, Bash, mcp__puppeteer__
---

You are a frontend specialist focusing on:
1. Creating responsive React components with TypeScript
2. Implementing Astro pages with proper routing
3. Ensuring accessibility compliance (WCAG 2.1 AA)
4. Optimizing performance (Core Web Vitals)
5. Integrating Tailwind CSS and shadcn/ui components
6. Writing unit tests with React Testing Library

When creating components:
- Always include TypeScript interfaces
- Use shadcn/ui when appropriate (see src/components/ui/button.tsx for reference)
- Implement proper error handling
- Add loading and empty states
- Ensure mobile responsiveness
- Follow the class-variance-authority pattern for variants
```

#### b. Add Cross-Agent Collaboration Guidelines
Include guidance on when agents should collaborate:

```markdown
## Agent Collaboration Guidelines

### Frontend + Backend Collaboration
When implementing features that require both frontend and backend:
1. Backend agent creates API endpoints first (see src/pages/api/health.ts for example)
2. Frontend agent consumes APIs with proper error handling
3. Both agents coordinate on data structures

### Database + Backend Collaboration
For database-related features:
1. Database agent designs schema and RLS policies
2. Backend agent implements data access patterns using Supabase client
3. Both agents review performance implications

### Payment + Backend Collaboration
For payment features:
1. Payment agent handles Stripe integration
2. Backend agent manages order and subscription records
3. Both agents ensure PCI compliance

### Testing + All Agents
For quality assurance:
1. Testing agent creates comprehensive test coverage
2. All agents ensure their code is testable
3. Testing agent validates cross-agent integrations
```

## 5. Workflow Optimization Improvements

### Current Workflows
The CLAUDE.MD mentions development workflows but could be more specific. Based on the project structure, we should document workflows that align with the existing commands and agent specializations.

### Recommended Improvements

#### a. Add Explore-Plan-Code-Test Workflow
```markdown
## Recommended Workflow: Explore-Plan-Code-Test

1. **Explore**: Have Claude read relevant files to understand context
   - Use `/read` command to examine existing implementations
   - Identify patterns and conventions (see src/components/ui/button.tsx and src/pages/api/health.ts)

2. **Plan**: Create implementation plan before coding
   - Document approach in a GitHub issue or design doc
   - Identify potential edge cases
   - Plan test scenarios

3. **Code**: Implement solution with proper structure
   - Follow existing patterns and conventions
   - Include error handling and validation
   - Write clean, maintainable code

4. **Test**: Verify implementation works correctly
   - Run existing tests to ensure no regressions
   - Add new tests for implemented features
   - Test edge cases and error conditions
```

#### b. Add Test-Driven Development Workflow
```markdown
## TDD Workflow for New Features

1. **Write Tests First**
   - Define expected behavior with tests
   - Start with happy path scenarios
   - Include edge cases and error conditions

2. **Run Tests (Expect Failures)**
   - Verify tests fail for the right reasons
   - Confirm no false positives

3. **Implement Code**
   - Write minimal code to pass tests
   - Refactor for clarity and performance
   - Ensure all tests pass

4. **Review and Refine**
   - Check code quality and maintainability
   - Verify tests cover all scenarios
   - Confirm no regressions in existing functionality
```

## 6. Repository-Specific Best Practices

### Add Project-Specific Guidelines
```markdown
## mcp-template Best Practices

### Supabase Integration
- Always use RLS (Row Level Security) policies
- Use generated types from Supabase for type safety
- Implement proper error handling for database operations
- Use server-side clients for API routes (see src/pages/api/health.ts for example)

### Stripe Integration
- Use Stripe Elements for secure payment forms
- Implement proper webhook handling for payment events
- Handle subscription lifecycle events
- Ensure PCI compliance in all payment flows

### Performance Optimization
- Lazy load components where appropriate
- Optimize bundle sizes with code splitting
- Implement proper caching strategies
- Monitor Core Web Vitals metrics

### Security Considerations
- Never expose service role keys to client
- Implement proper authentication checks
- Validate all user inputs with Zod schemas
- Use environment variables for secrets

### Component Development
- Follow the pattern in src/components/ui/button.tsx
- Use class-variance-authority for component variants
- Implement proper TypeScript interfaces
- Use the cn helper from '@/lib/utils' for class merging
```

## 7. Onboarding and Learning Improvements

### Add Quick Start Guide
```markdown
## Quick Start for New Developers

1. **Environment Setup**
   - Clone repository
   - Run `npm install`
   - Copy `.env.sample` to `.env.local`
   - Configure Supabase and Stripe credentials

2. **First Tasks**
   - Run `npm run dev` to start development server
   - Run `npm run test` to verify test setup
   - Try `/component Button` to create first component
   - Try `/test button-component` to create first test

3. **Learning Resources**
   - Review existing components in `src/components/` (especially src/components/ui/button.tsx)
   - Examine API endpoints in `src/pages/api/` (especially src/pages/api/health.ts)
   - Study E2E tests in `tests/e2e/`
   - Check Supabase migrations in `supabase/migrations/`
   - Review custom commands in `.claude/commands/`
```

## 8. Troubleshooting and Debugging

### Add Common Issues and Solutions
```markdown
## Troubleshooting Guide

### Development Server Issues
- **Problem**: Server fails to start
  **Solution**: Check environment variables and database connection

- **Problem**: Hot reload not working
  **Solution**: Restart development server with `npm run dev`

### Testing Issues
- **Problem**: Tests failing due to database state
  **Solution**: Reset test database or run specific test files

- **Problem**: Playwright tests failing
  **Solution**: Update browser drivers with `npx playwright install`

### Deployment Issues
- **Problem**: Build fails during deployment
  **Solution**: Check for TypeScript errors and missing environment variables

### Supabase Issues
- **Problem**: Authentication not working
  **Solution**: Verify Supabase credentials and URL configuration

- **Problem**: Database migrations failing
  **Solution**: Check migration file syntax and dependencies
```

## Implementation Plan

1. **Phase 1**: Update CLAUDE.MD with streamlined structure
   - Reorganize content for better context consumption
   - Add quick reference section with project-specific commands
   - Include repository-specific information and examples

2. **Phase 2**: Optimize tool allowlist
   - Add git and GitHub CLI permissions
   - Include database and payment tool permissions
   - Review and refine permissions regularly

3. **Phase 3**: Enhance custom commands
   - Add new workflow commands (/setup-dev, /typecheck, /health-check)
   - Improve existing command documentation with project examples
   - Create templates for common tasks

4. **Phase 4**: Improve agent specializations
   - Clarify agent responsibilities with project-specific guidance
   - Add collaboration guidelines
   - Include best practices referencing actual project files

5. **Phase 5**: Document workflows and best practices
   - Add recommended development workflows
   - Include troubleshooting guide
   - Create onboarding documentation with references to existing files