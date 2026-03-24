---
tracker:
  kind: prd_json
  path: prd.json
  active_states:
    - open
    - in_progress
  terminal_states:
    - done
    - failed
    - cancelled

polling:
  interval_ms: 5000

checks:
  required:
    - mix format --check-formatted
    - mix test
  timeout_ms: 600000
  fail_fast: true

review:
  enabled: true
  max_cycles: 2
  pass_token: REVIEW_PASS
  fail_token: REVIEW_FAIL
  prompt_template: |
    Review issue {{ issue.identifier }}: {{ issue.title }}.
    You are a strict reviewer.

    First line must be EXACTLY one of:
    REVIEW_PASS
    REVIEW_FAIL: <short reason>

    Verify tests and implementation quality. If anything is missing, return REVIEW_FAIL.
  agent:
    kind: pi

publish:
  # Conservative defaults: do not publish anything automatically.
  provider: github # github | gitlab
  auto_push: never # never | on_pass
  auto_create_pr: never # never | draft | ready

git:
  # Keep this true to require agent commits before any publish action.
  require_commit: true # true | false

workspace:
  root: ~/kollywood-workspaces
  strategy: worktree
  source: ~/projects/kollywood
  branch_prefix: kollywood/

agent:
  kind: pi
  retries_enabled: false
  max_concurrent_agents: 5
  max_turns: 20
---

You are working on issue `{{ issue.identifier }}`: **{{ issue.title }}**

## Description

{{ issue.description }}

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
