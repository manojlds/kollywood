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
3. Propose plan + draft stories (NO writes yet):
   - propose story breakdown and sequencing
   - present draft stories in chat as a readable table before any mutation
4. Explicit confirmation gate (REQUIRED):
   - ask the user to confirm before creating/updating tracker stories
   - do not run `kollywood story add|edit|import` until the user explicitly confirms
   - if user asks for changes, revise draft and re-confirm
5. Write stories after confirmation:
   - default `status=draft` unless user requests `open`
   - include title, description, priority, acceptance criteria, dependencies
6. Confirm result:
   - run `kollywood story list --json`
   - report created/updated IDs and suggested execution order in chat

## Story Quality

Each story must be:
- independently understandable
- small enough for a focused implementation cycle
- backed by verifiable acceptance criteria

Avoid vague criteria such as "works correctly".

## Output Format

Always return:
1. concise plan summary
2. story table (ID, title, status, priority, depends_on, action)
3. dependency notes
4. recommended next story to execute first

When awaiting confirmation, clearly ask:
- "Do you want me to create/update these stories now?"

After writing stories, always include:
- exact created/updated story IDs
- one-paragraph summary of what changed in the tracker
