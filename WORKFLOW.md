---
tracker:
  active_states:
    - open
    - in_progress
  kind: prd_json
  terminal_states:
    - done
    - failed
    - cancelled
polling:
  interval_ms: 5000
workspace:
  strategy: worktree
agent:
  kind: opencode
  max_attempts: 1
  max_concurrent_agents: 1
  max_turns: 20
  retries_enabled: false
  timeout_ms: 7200000
checks:
  fail_fast: true
  required:
    - "devenv shell -- mix format --check-formatted"
    - "devenv shell -- bash -c \"MIX_ENV=test mix test\""
  timeout_ms: 1800000
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
  before_run: "devenv shell -- sh -c \"mix deps.get && MIX_ENV=test mix deps.compile\""
review:
  agent:
    kind: opencode
    timeout_ms: 7200000
  enabled: true
  fail_token: REVIEW_FAIL
  max_cycles: 2
  pass_token: REVIEW_PASS
  prompt_template: |
    You are reviewing work for issue {{ issue.identifier }}: {{ issue.title }}.
    
    Issue description:
    {{ issue.description }}
    
    Prior implementation output (may be empty):
    {{ agent_output }}
    
    Review the current workspace changes. You may run commands for validation.
    Do not modify files, do not commit, and do not push.
    
    On the FIRST line, return exactly one verdict:
    REVIEW_PASS
    or
    REVIEW_FAIL: <one-line summary of the most critical issue>
    
    After the first line, provide a structured review report with the following sections
    (omit sections with no findings):
    
    ## Critical
    Issues that must be fixed before merging (bugs, broken tests, security issues, missing required functionality).
    List each as: - [description of issue and where to find it]
    
    ## Major
    Significant quality issues that should be fixed (poor design, missing error handling, test coverage gaps).
    List each as: - [description of issue and where to find it]
    
    ## Minor
    Nice-to-haves and style issues (naming, code clarity, optional improvements).
    List each as: - [description of issue and where to find it]
    
    ## Summary
    One or two sentences summarising the overall quality of the changes.
publish:
  auto_create_pr: never
  auto_push: on_pass
  provider: github
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
