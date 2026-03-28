---
tracker:
  active_states:
    - open
    - in_progress
  kind: prd_json
  terminal_states:
    - done
    - merged
    - failed
    - cancelled
workspace:
  strategy: worktree
agent:
  kind: opencode
  max_attempts: 1
  max_concurrent_agents: 1
  max_turns: 20
  retries_enabled: false
  timeout_ms: 7200000
quality:
  max_cycles: 2
  checks:
    fail_fast: true
    max_cycles: 2
    required:
      - "devenv shell -- mix format --check-formatted"
      - "devenv shell -- bash -c \"MIX_ENV=test mix test\""
    timeout_ms: 1800000
  review:
    agent:
      kind: opencode
      timeout_ms: 7200000
    enabled: true
    max_cycles: 2
runtime:
  full_stack:
    command: devenv
    env: {}
    ports:
      PORT: 4000
    processes:
      - server
  profile: checks_only
hooks:
  before_run: "bash -lc 'if [ -f .kollywood/AGENTS.md ]; then cp .kollywood/AGENTS.md AGENTS.md; fi; devenv shell -- sh -c \"mix deps.get && MIX_ENV=test mix deps.compile\"'"
publish:
  mode: auto_merge
git:
  base_branch: main
---

You are working on issue `{{ issue.identifier }}`: **{{ issue.title }}**

## Description

{{ issue.description }}

{% if resume_context %}
{{ resume_context }}
{% endif %}

## Instructions

{% if attempt %}
This is retry attempt #{{ attempt }}. Review what went wrong in the previous attempt
and try a different approach.
{% endif %}

1. Read the issue description carefully
2. Understand the codebase context
3. Implement the changes
4. Run tests to verify
5. Commit your changes with a descriptive message
