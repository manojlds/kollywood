---
name: kollywood-prd
description: "Plan a feature and break it into Kollywood stories using Rust CLI. Use when asked to create a feature plan and add or update stories in the project tracker."
---

# Kollywood PRD

Convert feature intent into actionable Kollywood stories.

## Rules

Use Rust CLI only for Kollywood operations:
- `kollywood project resolve --json`
- `kollywood story list --json`
- `kollywood story add ...`
- `kollywood story edit ...`
- `kollywood story import ...`

Do not use `mix kollywood.*`.
Do not start implementation while in PRD mode.

## Workflow

1. Resolve project context:
   - run `kollywood project resolve --json`
   - if unresolved, stop and ask user to onboard/select project
2. Clarify feature scope:
   - ask only high-signal questions (goal, boundaries, dependencies, acceptance expectations)
3. Produce plan:
   - propose story breakdown and sequencing
4. Write stories:
   - default `status=draft` unless user requests `open`
   - include title, description, priority, acceptance criteria, dependencies
5. Confirm result:
   - run `kollywood story list --json`
   - report created/updated IDs and suggested execution order

## Story Quality

Each story must be:
- independently understandable
- small enough for a focused implementation cycle
- backed by verifiable acceptance criteria

Avoid vague criteria such as "works correctly".

## Output Format

Always return:
1. concise plan summary
2. created/updated story IDs with titles
3. dependency notes
4. recommended next story to execute first
