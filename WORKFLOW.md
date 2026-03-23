---
tracker:
  kind: prd_json
  path: .ralphi/prd.json
  active_states:
    - open
    - in_progress
  terminal_states:
    - done

polling:
  interval_ms: 5000

workspace:
  root: ~/kollywood-workspaces
  strategy: worktree
  source: ~/projects/kollywood
  branch_prefix: kollywood/

agent:
  kind: amp
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
