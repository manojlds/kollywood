---
name: kollywood-init
description: "Initialize Kollywood onboarding files for the current project. Use when asked to initialize Kollywood, detect existing Kollywood project settings, and create or update workflow and agent guidance files."
---

# Kollywood Init

Initialize onboarding files for a project that is already mapped in Kollywood.

## Scope

Create or update:
- `.kollywood/WORKFLOW.md`
- `.kollywood/AGENTS.md`
- `mise.toml` only when required by chosen workflow/runtime
- `pitchfork.toml` only when required by chosen workflow/runtime

Do not run story planning or story CRUD during init unless the user explicitly asks.

## Required Kollywood Lookup

Use Rust CLI to read project settings first:
- `kollywood project resolve --json`
- `kollywood workflow schema --json`

Use `KOLLYWOOD_CLI` if provided by environment as the CLI binary path:
- `"${KOLLYWOOD_CLI:-kollywood}" project resolve --json`
- `"${KOLLYWOOD_CLI:-kollywood}" workflow schema --json`

If lookup fails because the project is not mapped, stop and ask the user to onboard the project in Kollywood first.

If the project is mapped but tracker files are missing, continue onboarding and generate WORKFLOW/AGENTS first.
Do not block onboarding on missing `~/.kollywood/projects/<slug>/prd.json`.

Treat resolved metadata as source of truth:
- `slug`
- `provider`
- `local_path`
- `repository`

## Workflow

1. Resolve project settings via `"${KOLLYWOOD_CLI:-kollywood}" project resolve --json`.
2. Fetch machine-readable workflow schema via `"${KOLLYWOOD_CLI:-kollywood}" workflow schema --json` and treat it as the authoritative shape/version.
3. Analyze repository context:
   - read `README*`, manifests, existing runtime files, existing `.kollywood/*` files
   - infer test/lint/build/typecheck commands and runtime process model
4. Ask confirmation questions for unresolved workflow fields:
   - runtime kind
   - runtime process names and ports
   - quality/check commands
   - default agent kind
   - project constraints for `.kollywood/AGENTS.md`
5. Generate/update onboarding files using resolved settings + confirmed answers.
6. Report what changed and what assumptions were applied.

## Invocation behavior

The triggering user prompt may be minimal (for example: `I need to onboard this project to Kollywood.`).
Treat that as sufficient to run the full init workflow in this skill.
Do not require a verbose user message that restates this skill's internal checklist.

## `.kollywood/WORKFLOW.md` Requirements

Build workflow config from resolved project settings and confirmations:
- set top-level `schema_version: 1`
- set tracker/provider fields from resolved project context
- for local-tracker projects, use `tracker.kind: prd_json`
- keep `workspace.strategy` explicit
- include only confirmed quality commands
- include runtime kind/process/ports
- include safe `hooks.before_run` to copy `.kollywood/AGENTS.md` into workspace when present
- keep `git.base_branch` explicit (fallback `main`)
- when `tracker.kind` resolves to `prd_json`, note that `prd.json` can be created lazily when story CRUD begins

Do not invent commands that are not validated for the repo.

## `.kollywood/AGENTS.md` Requirements

Write concise operational rules:
- scope boundaries
- test/runtime safety constraints
- commit conventions when provided
- environment caveats relevant to this project

Merge non-destructively when guidance already exists.

## Output Format

Always return:
1. resolved Kollywood project metadata used
2. files created/updated
3. unresolved items (if any)
