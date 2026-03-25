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

hooks:
  before_run: devenv shell -- sh -c "mix deps.get && MIX_ENV=test mix deps.compile"

checks:
  required:
    - devenv shell -- mix format --check-formatted
    - devenv shell -- mix test
  timeout_ms: 1800000
  fail_fast: true

runtime:
  profile: checks_only
  full_stack:
    command: devenv
    processes:
      - server
    env: {}
    ports:
      PORT: 4000

review:
  enabled: true
  max_cycles: 2
  pass_token: REVIEW_PASS
  fail_token: REVIEW_FAIL
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
  agent:
    kind: claude

publish:
  provider: github
  auto_push: on_pass
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
  kind: claude
  retries_enabled: false
  max_attempts: 1
  max_concurrent_agents: 1
  max_turns: 20
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
