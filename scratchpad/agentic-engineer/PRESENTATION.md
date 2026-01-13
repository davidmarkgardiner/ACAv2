# Agentic Engineering: Best Practices for Using Claude at Work

<img src="agentic_engineering_header_1768316483488.png" width="300" alt="Agentic Engineering" />

> A guide for getting the most out of AI-assisted development using this Habit Tracker repo as a demonstration.

---

## 1. Start with a PRD (Product Requirements Document)

<img src="prd_blueprint_1768316510937.png" width="300" alt="The Blueprint" />

**The PRD is your source of truth for the entire feature.**

### How to Create One

Feed Claude external context to build a comprehensive PRD:
- Official documentation
- Blog posts or tutorials
- GitHub repos or examples
- Your own feature ideas

```markdown
Example prompt:
"Based on this FastAPI documentation [link] and this habit tracking app concept,
create a PRD for a habit tracker with streak tracking and completion metrics."
```

### Iterate Until Finalised

- Go back and forth 2-3+ times
- Challenge assumptions
- Add edge cases
- Clarify acceptance criteria

### Demo Reference

See `.claude/PRD.md` for the finalised PRD that drove this project.

> **Key Point**: Everything built flows from this document. Time invested here saves debugging later.

---

## 2. Keep CLAUDE.md Light and Focused

<img src="focused_context_1768316534994.png" width="300" alt="Focused Context" />

**Don't overwhelm the LLM - it's like having too busy a brain.**

### What Goes in CLAUDE.md

- Tech stack overview
- Project structure (high-level)
- Essential commands
- Code conventions (brief)
- **References to deeper docs** - not the docs themselves

### Demo Reference

See `CLAUDE.md` - notice the reference table:

| Document | When to Read |
|----------|--------------|
| `.claude/PRD.md` | Understanding requirements |
| `.claude/reference/fastapi-best-practices.md` | Building API endpoints |

### The Pattern

```
CLAUDE.md (always loaded)
    └── References to...
        ├── .claude/PRD.md (on demand)
        ├── .claude/reference/*.md (on demand)
        └── .claude/commands/*.md (on demand)
```

> **Key Point**: Concise global context + on-demand deep context = best outcomes.

---

## 3. Turn Repeated Prompts into Commands

<img src="tools_and_skills_1768316564860.png" width="300" alt="Tools & Skills" />

**Anything you prompt more than twice should become a slash command.**

### What Are Commands?

- Reusable instruction sets for Claude
- Invoked with `/command-name`
- Can accept arguments
- Live in `.claude/commands/`

### Demo Reference

This repo has several commands:

```
.claude/commands/
├── commit.md                    # /commit
├── create-prd.md                # /create-prd
├── init-project.md              # /init-project
├── core_piv_loop/
│   ├── plan-feature.md          # /plan-feature
│   └── execute.md               # /execute [plan-path]
└── validation/
    ├── code-review.md           # /code-review
    └── validate.md              # /validate
```

### Example: The Commit Command

Instead of typing commit instructions every time:

```bash
# Before (manual every time)
"Look at git status, check the diff, write a good commit message..."

# After (one command)
/commit
```

### Creating Your Own

```markdown
# .claude/commands/my-task.md
---
description: "Do the thing I always do"
argument-hint: [optional-args]
---

## Instructions

1. First, do X
2. Then check Y
3. Finally, validate with Z

## Output Format

Provide results in this format...
```

> **Key Point**: Commands are scripts for the LLM. Invest in building your workflow.

---

## 3b. Skills: Commands with Superpowers

**Skills are self-contained packages that turn Claude into a domain expert.**

### Commands vs Skills

| Commands | Skills |
|----------|--------|
| Single markdown file | Directory with multiple files |
| Simple instructions | Instructions + scripts + references + assets |
| Task-focused | Domain-focused |
| `.claude/commands/*.md` | `.claude/skills/*/` |

### Anatomy of a Skill

```
skill-name/
├── SKILL.md              # Main instructions (required)
├── scripts/              # Executable code (Python/Bash)
├── references/           # Documentation loaded on-demand
├── assets/               # Templates, configs, files used in output
```

### When to Use Skills vs Commands

**Use a Command when:**
- Single task with simple instructions
- No supporting files needed
- Example: `/commit`, `/code-review`

**Use a Skill when:**
- Domain requires specialized knowledge
- Multiple scripts or templates needed
- Complex multi-step workflows
- Reusable across projects
- Example: `aks-mcp-expert`, `kro-stack-builder`

### Demo Reference

This repo has several skills in `.claude/skills/`:

```
.claude/skills/
├── skill-creator/              # Meta-skill for creating skills
├── aks-mcp-expert/             # Kubernetes + MCP deployment
├── kro-stack-builder/          # KRO ResourceGraphDefinitions
├── holmesgpt-deployer/         # AI troubleshooting platform
└── cert-manager-specialist/    # TLS certificate management
```

### Progressive Disclosure

Skills load context efficiently in three levels:

```
Level 1: Metadata (always loaded, ~100 words)
         └── name + description in SKILL.md frontmatter

Level 2: SKILL.md body (when skill triggers, <5k words)
         └── Core instructions and workflow

Level 3: Bundled resources (as needed, unlimited)
         └── scripts/ - executed without reading
         └── references/ - loaded when relevant
         └── assets/ - used in output
```

### Example: Skill Structure

```markdown
# .claude/skills/my-domain/SKILL.md
---
name: my-domain
description: This skill should be used when deploying X to Y with Z configuration.
---

# My Domain Expert

## Purpose
Handle complex deployments of X to Y environments.

## Workflow
1. Read `references/architecture.md` for system design
2. Run `scripts/validate_prereqs.sh` to check environment
3. Use `assets/deployment-template.yaml` as base config
4. Execute deployment steps...

## References
- `references/architecture.md` - System design and patterns
- `references/troubleshooting.md` - Common issues and fixes
```

### Creating a New Skill

Use the skill-creator skill:

```bash
# Initialize a new skill
python .claude/skills/skill-creator/scripts/init_skill.py my-skill --path .claude/skills/

# Package for distribution
python .claude/skills/skill-creator/scripts/package_skill.py .claude/skills/my-skill/
```

> **Key Point**: Skills are "onboarding guides" for domains. They transform Claude from general-purpose to specialized expert.

---

## 4. Reset Context Between Planning and Implementation

<img src="piv_loop_1768316591972.png" width="300" alt="The Loop" />

**Fresh context = focused execution.**

### The PIV Loop (Plan → Implement → Validate)

```
┌─────────────────────────────────────────────────────┐
│                    PIV LOOP                         │
├─────────────────────────────────────────────────────┤
│                                                     │
│   PLAN ──────────► IMPLEMENT ──────────► VALIDATE   │
│     │                  │                     │      │
│     │                  │                     │      │
│     ▼                  ▼                     ▼      │
│  /plan-feature      /execute            /validate   │
│                    [plan-path]                      │
│                                                     │
│   Context reset ◄─────────────────────────────────  │
│   between phases                                    │
└─────────────────────────────────────────────────────┘
```

### Why Reset Context?

1. Planning accumulates research, options, dead-ends
2. Implementation needs clean focus on THE plan
3. Validation needs fresh eyes on the result

### Demo: The Execute Command

See `.claude/commands/core_piv_loop/execute.md`:

```markdown
## Execution Instructions

### 1. Read and Understand
- Read the ENTIRE plan carefully
- Understand all tasks and their dependencies

### 2. Execute Tasks in Order
For EACH task in "Step by Step Tasks":
- Navigate to the task
- Implement the task
- Verify as you go

### 3. Run Validation Commands
Execute ALL validation commands from the plan in order
```

### The Workflow

```bash
# Session 1: Planning
/plan-feature "add weekly summary view"
# → Creates .agents/plans/add-weekly-summary.md
# → End session

# Session 2: Implementation (fresh context)
/execute .agents/plans/add-weekly-summary.md
# → Follows the plan step-by-step
# → Runs validation commands
# → End session

# Session 3: Validation (fresh context)
/validate
```

> **Key Point**: The plan is the handoff document. It contains everything needed for one-pass implementation.

---

## 5. Fix Problems at the Source, Not the Symptom

<img src="system_evolution_1768316616155.png" width="300" alt="System Evolution" />

**When something breaks, update your system so it never breaks the same way again.**

### The Feedback Loop

```
Bug/Issue Occurs
      │
      ▼
Fix the immediate problem
      │
      ▼
Ask: "Where should this knowledge live?"
      │
      ├──► CLAUDE.md (global rules)
      │
      ├──► .claude/reference/*.md (domain-specific)
      │
      ├──► .claude/commands/*.md (workflow steps)
      │
      └──► PRD.md (requirements clarification)
```

### Examples

| Problem | Symptom Fix | System Fix |
|---------|-------------|------------|
| Claude keeps using `useEffect` for data fetching | "Use TanStack Query instead" | Add to CLAUDE.md: "Use TanStack Query for all API calls" |
| Commits missing Co-Author line | Manually add it | Update `/commit` command to include it |
| Tests fail because of missing pragma | Add pragma to failing test | Add to CLAUDE.md database section |
| Agent loops on unclear requirement | Clarify in conversation | Add acceptance criteria to PRD |

### Demo: Evolution of CLAUDE.md

The database section exists because of past issues:

```markdown
## Database

SQLite with WAL mode. Always run these PRAGMAs on connection:
```sql
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA synchronous=NORMAL;
```
```

This wasn't in the first version - it was added after foreign key bugs surfaced.

> **Key Point**: Every bug is an opportunity to make the system smarter. Your future self (and the AI) will thank you.

---

## Quick Reference

| Principle | Action |
|-----------|--------|
| 1. PRD First | Create and iterate until it's the source of truth |
| 2. Light CLAUDE.md | Global essentials + references to deeper docs |
| 3. Commands | `/command` anything you do more than twice |
| 3b. Skills | Package domain expertise with scripts, references, assets |
| 4. Context Reset | Fresh session for Plan → Implement → Validate |
| 5. Fix the System | Update rules/commands/skills when issues occur |

---

## File Structure for AI-Assisted Development

```
your-project/
├── CLAUDE.md                    # Light, always-loaded context
├── .claude/
│   ├── PRD.md                   # Source of truth for features
│   ├── commands/                # Simple reusable workflows
│   │   ├── commit.md
│   │   ├── plan-feature.md
│   │   └── execute.md
│   ├── skills/                  # Domain expert packages
│   │   └── my-domain/
│   │       ├── SKILL.md         # Main instructions
│   │       ├── scripts/         # Executable code
│   │       ├── references/      # On-demand docs
│   │       └── assets/          # Templates, configs
│   └── reference/               # Deep context (loaded on demand)
│       ├── api-patterns.md
│       └── testing-guide.md
└── .agents/
    └── plans/                   # Generated implementation plans
        └── feature-name.md
```

---

## Demo Commands to Show

```bash
# Show the PRD
cat .claude/PRD.md

# Show light CLAUDE.md referencing deeper docs
cat CLAUDE.md

# Show a command structure (simple)
cat .claude/commands/core_piv_loop/execute.md

# Show a skill structure (complex domain expert)
ls -la .claude/skills/aks-mcp-expert/
cat .claude/skills/aks-mcp-expert/SKILL.md

# Show skill-creator (meta-skill for creating skills)
cat .claude/skills/skill-creator/SKILL.md

# Live demo: create a plan
/plan-feature "add habit categories"

# Live demo: execute from plan
/execute .agents/plans/add-habit-categories.md
```

---

## Summary

1. **PRD** - Your feature's source of truth. Iterate until solid.
2. **CLAUDE.md** - Keep it light. Reference, don't embed.
3. **Commands** - Automate repeated workflows with simple instructions.
4. **Skills** - Package domain expertise with scripts, references, and assets.
5. **Context Reset** - Fresh sessions for each phase.
6. **System Fixes** - Every bug improves the system.

The goal: Build a workflow where the AI gets smarter with every feature you ship.
