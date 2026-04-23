---
name: example-skill
description: Template skill — demonstrates structure for SKILL.md, scripts, and resources. Copy this directory and customise.
---

# Example Skill

Replace this with actual instructions for the agent. This is the file kagent's
SkillsTool reads to surface the skill to the LLM.

## When the agent should use this skill

List the triggers / situations. Example:

- User asks about X
- Investigating Y pattern
- Need to produce Z output

Be specific — the LLM uses these triggers to decide whether to load this
skill's context.

## Instructions

Step-by-step what the agent should do when this skill is active.
Numbered steps work well.

1. Do the first thing.
2. If condition A, do B; else do C.
3. Call `scripts/helper.sh` with these arguments: ...
4. Produce output in this shape.

## Commands / tools referenced

If this skill calls scripts in `scripts/` or uses templates in `resources/`,
document them here so the agent knows what to invoke.

## Example interaction

```text
User: "Do the example thing in namespace foo"
Agent: Invokes `scripts/helper.sh foo` and produces ...
```

## Failure patterns

What common issues might arise and what the agent should do about them.

| Pattern | Cause | Action |
|---|---|---|
| Foo fails | Missing bar | Ask user to provide bar |
| Baz times out | Cluster load | Retry with backoff |
