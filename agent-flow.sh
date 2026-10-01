#!/usr/bin/env bash
# ==============================================================================
# agent-flow.sh — two-agent workflow for OpenCode
#
#   Prompt Engineer (read-only)  ->  .agent/prompts/latest.md
#   Coding Agent    (read/write) ->  .agent/reports/latest.md
#   Context Builder (read-only)  ->  .agent/context/PROJECT.md
#
# Usage:
#   ./agent-flow.sh "Implement feature X"                 full cycle
#   ./agent-flow.sh --continue "Fix what remains of X"    continue previous work
#   ./agent-flow.sh --prompt-only "Implement feature X"   only generate the prompt
#   ./agent-flow.sh --implement-only                      only run the existing prompt
#   ./agent-flow.sh --setup [--force]                     only install workflow files
#   ./agent-flow.sh --context-only                        (re)build the project context only
#   ./agent-flow.sh --verify-agents                       check that opencode loads the agents
#   ./agent-flow.sh --task-file task.md                   task from a file
#   echo "task" | ./agent-flow.sh                         task from stdin
#
# Every run: project context is built automatically if missing (mandatory step),
# and work happens on a fresh branch agent/<task-slug>-<timestamp>.
# The whole workflow stays out of git (.git/info/exclude, no tracked file touched).
#
# Options:
#   --branch NAME                  use/create this branch instead of agent/...
#   --no-branch                    work on the current branch
#   --refresh-context              rebuild project context before the run
#   --keep N                       history/log files to keep (0 = keep all)
#   --timeout SEC                  hard limit per agent call (0 = no limit)
#   --lock-wait SEC                wait for a concurrent run's lock
#   --no-auto                      do not pass --auto to `opencode run`
#   --pe-model    provider/model   model for the Prompt Engineer
#   --coder-model provider/model   model for the Coding Agent
#   (or env: AGENT_FLOW_PE_MODEL, AGENT_FLOW_CODER_MODEL, ...)
#
# Exit codes:
#   0  report says COMPLETED (or a non-executing mode finished)
#   1  workflow error
#   2  Coding Agent finished with PARTIALLY_COMPLETED / BLOCKED / FAILED
#   3  Coding Agent produced no valid report
# ==============================================================================

set -euo pipefail

TEMPLATE_VERSION="v4"
TEMPLATE_MARKER="agent-flow-template: ${TEMPLATE_VERSION}"

if [ -t 2 ]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

info()    { printf '%s[agent-flow]%s %s\n' "$C_BLUE"   "$C_OFF" "$*" >&2; }
success() { printf '%s[agent-flow]%s %s\n' "$C_GREEN"  "$C_OFF" "$*" >&2; }
warn()    { printf '%s[agent-flow]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
error()   { printf '%s[agent-flow]%s %s\n' "$C_RED"    "$C_OFF" "$*" >&2; }
die()     { error "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
Agentic coding workflow (OpenCode): Prompt Engineer -> Coding Agent

Usage:
  agent-flow.sh "Your task"                    Full cycle: generate prompt, then implement
  agent-flow.sh --continue "Next step"         Same, but builds on the previous report
  agent-flow.sh --prompt-only "Your task"      Only generate .agent/prompts/latest.md
  agent-flow.sh --implement-only               Run the existing .agent/prompts/latest.md
  agent-flow.sh --setup [--force]              Only install workflow files
  agent-flow.sh --context-only                 Only (re)build the project context
  agent-flow.sh --verify-agents                Check that opencode loads our agent definitions
  agent-flow.sh --task-file FILE               Read the task from a file
  echo "task" | agent-flow.sh                  Read the task from stdin

Options:
  --branch NAME          Use/create this branch instead of agent/<slug>-<time>
  --no-branch            Do not create a branch; work on the current one
  --refresh-context      Rebuild .agent/context/PROJECT.md before running
  --keep N               Keep the newest N history/log files (0 = keep all)
  --timeout SEC          Hard limit per agent call (0 = no limit, default 0)
  --lock-wait SEC        Wait up to SEC for a concurrent run to release its lock
  --no-auto              Do not pass --auto to `opencode run` (stricter, may stall)
  --pe-model MODEL       Model for Prompt Engineer (provider/model)
  --coder-model MODEL    Model for Coding Agent    (provider/model)
  --force                With --setup: overwrite existing agent definitions
  -h, --help             Show this help

Environment:
  AGENT_FLOW_PE_MODEL       Model for Prompt Engineer
  AGENT_FLOW_CODER_MODEL    Model for Coding Agent
  AGENT_FLOW_KEEP           History/log retention (default 100, 0 = unlimited)
  AGENT_FLOW_TIMEOUT        Per-agent-call timeout in seconds (default 0)
  AGENT_FLOW_LOCK_WAIT      Lock wait in seconds (default 0)
  AGENT_FLOW_VERIFY_WAIT    Retry delay for --verify-agents (default 2)
  AGENT_FLOW_OPENCODE_BIN   opencode binary (default: opencode)
  AGENT_FLOW_OPENCODE_ARGS  Extra args for `opencode run` (whitespace separated)
  AGENT_FLOW_AUTO           0 disables --auto (same as --no-auto)

Exit codes:
  0 success | 1 workflow error | 2 agent reported PARTIALLY_COMPLETED/BLOCKED/FAILED
  3 no usable completion report

Always-on behavior:
  * Project context (.agent/context/PROJECT.md) is built on first run.
  * A new branch agent/<task-slug>-<timestamp> is created unless you are
    already on an agent/* branch (or use --branch / --no-branch).
  * Workflow files are excluded via .git/info/exclude, never committed.
  * One run per repository; a stale lock left by a killed process is detected
    and reclaimed automatically.

Combinations:
  --continue --prompt-only   Generate a continuation prompt without executing it
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------

MODE="run"            # run | prompt-only | implement-only | setup | context-only | verify-agents
CONTINUE=0
FORCE=0
NO_BRANCH=0
BRANCH_NAME=""
REFRESH_CONTEXT=0
BASE_BRANCH=""
BRANCH_CREATED=""
MERGE_HINT=""
TASK=""
TASK_FILE=""
KEEP="${AGENT_FLOW_KEEP:-100}"
TIMEOUT="${AGENT_FLOW_TIMEOUT:-0}"
LOCK_WAIT="${AGENT_FLOW_LOCK_WAIT:-0}"
VERIFY_RETRY_WAIT="${AGENT_FLOW_VERIFY_WAIT:-2}"
AUTO="1"
if [ "${AGENT_FLOW_AUTO:-1}" = "0" ]; then
    AUTO="0"
fi
PE_MODEL="${AGENT_FLOW_PE_MODEL:-}"
CODER_MODEL="${AGENT_FLOW_CODER_MODEL:-}"
OPENCODE_BIN="${AGENT_FLOW_OPENCODE_BIN:-opencode}"
OPENCODE_EXTRA_ARGS="${AGENT_FLOW_OPENCODE_ARGS:-}"
OPENCODE_HAS_AUTO=""

need_value() {
    # need_value OPTION REMAINING_ARGC
    [ "$2" -ge 2 ] || die "$1 requires a value."
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        --setup)          MODE="setup" ;;
        --verify-agents)  MODE="verify-agents" ;;
        --force)          FORCE=1 ;;
        --continue)       CONTINUE=1 ;;
        --prompt-only)    MODE="prompt-only" ;;
        --implement-only) MODE="implement-only" ;;
        --context-only)   MODE="context-only" ;;
        --refresh-context) REFRESH_CONTEXT=1 ;;
        --no-branch)      NO_BRANCH=1 ;;
        --no-auto)        AUTO="0" ;;
        --timeout)
            need_value "$1" "$#"; TIMEOUT="$2"; shift ;;
        --keep)
            need_value "$1" "$#"; KEEP="$2"; shift ;;
        --lock-wait)
            need_value "$1" "$#"; LOCK_WAIT="$2"; shift ;;
        --branch)
            need_value "$1" "$#"
            BRANCH_NAME="$2"; shift ;;
        --task-file)
            need_value "$1" "$#"
            TASK_FILE="$2"; shift ;;
        --pe-model)
            need_value "$1" "$#"
            PE_MODEL="$2"; shift ;;
        --coder-model)
            need_value "$1" "$#"
            CODER_MODEL="$2"; shift ;;
        --)
            shift
            TASK="${TASK:+$TASK }$*"
            break ;;
        -*)
            die "Unknown option: $1 (see --help)" ;;
        *)
            TASK="${TASK:+$TASK }$1" ;;
    esac
    shift
done

require_uint() {
    # require_uint FLAG_NAME VALUE
    case "$2" in
        ''|*[!0-9]*) die "$1 expects a non-negative integer, got: $2" ;;
    esac
}
require_uint "--keep" "$KEEP"
require_uint "--timeout" "$TIMEOUT"
require_uint "--lock-wait" "$LOCK_WAIT"

# ------------------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------------------

command_exists git || die "git is required but was not found in PATH."

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROOT="${ROOT%/}"
[ -n "$ROOT" ] || ROOT="/"
cd "$ROOT" || die "Cannot enter repository root: $ROOT"

IN_GIT=0
git rev-parse --git-dir >/dev/null 2>&1 && IN_GIT=1

AGENT_DIR="$ROOT/.opencode/agents"
WORKFLOW_DIR="$ROOT/.agent"
PROMPT_DIR="$WORKFLOW_DIR/prompts"
REPORT_DIR="$WORKFLOW_DIR/reports"
LOG_DIR="$WORKFLOW_DIR/logs"
RUNTIME_DIR="$WORKFLOW_DIR/runtime"
LOCK_DIR="$RUNTIME_DIR/lock"
CONTEXT_DIR="$WORKFLOW_DIR/context"
CONTEXT_FILE="$CONTEXT_DIR/PROJECT.md"
CONTEXT_DRAFT="$CONTEXT_DIR/PROJECT.draft.md"
CONTEXT_META="$CONTEXT_DIR/meta"

LATEST_PROMPT="$PROMPT_DIR/latest.md"
DRAFT_PROMPT="$PROMPT_DIR/draft.md"
LATEST_REPORT="$REPORT_DIR/latest.md"

# Paths as the agents see them (relative to repo root)
REL_LATEST_PROMPT=".agent/prompts/latest.md"
REL_DRAFT_PROMPT=".agent/prompts/draft.md"
REL_LATEST_REPORT=".agent/reports/latest.md"
REL_CONTEXT=".agent/context/PROJECT.md"
REL_CONTEXT_DRAFT=".agent/context/PROJECT.draft.md"

PROMPT_ENGINEER_FILE="$AGENT_DIR/prompt-engineer.md"
CODING_AGENT_FILE="$AGENT_DIR/coding-agent.md"
CONTEXT_BUILDER_FILE="$AGENT_DIR/context-builder.md"

TS="$(date '+%Y%m%d-%H%M%S')"

REQUIRED_PROMPT_SECTIONS=(
    "Objective"
    "Repository Context"
    "Current State"
    "Requirements"
    "Constraints"
    "Non-Goals"
    "Implementation Guidance"
    "Validation"
    "Acceptance Criteria"
    "Completion Report"
)

REQUIRED_REPORT_SECTIONS=(
    "Task"
    "Result"
    "Summary"
    "Files Changed"
    "Implementation Details"
    "Acceptance Criteria"
    "Validation"
    "Remaining Issues"
    "Notes For Next Agent"
)

RESULT_COMPLETED="COMPLETED"
RESULT_PARTIAL="PARTIALLY_COMPLETED"
RESULT_BLOCKED="BLOCKED"
RESULT_FAILED="FAILED"

# ------------------------------------------------------------------------------
# Template: Prompt Engineer
# ------------------------------------------------------------------------------

# shellcheck disable=SC2329  # invoked indirectly through install_agent_file
write_prompt_engineer() {
cat > "$PROMPT_ENGINEER_FILE" <<'EOF'
---
description: Investigates the repository and writes an execution-ready prompt for the Coding Agent. Read-only except for its own draft file.
mode: primary
steps: 200
permissions:
  # OpenCode V2 permission rules. The LAST matching rule wins, so every broad
  # rule comes before its exceptions.
  - action: "*"
    resource: "*"
    effect: deny
  - action: "question"
    resource: "*"
    effect: deny
  - action: "subagent"
    resource: "*"
    effect: deny
  - action: "skill"
    resource: "*"
    effect: deny
  - action: "webfetch"
    resource: "*"
    effect: deny
  - action: "websearch"
    resource: "*"
    effect: deny
  - action: "external_directory"
    resource: "*"
    effect: ask
  - action: "external_directory"
    resource: "$HOME/.ssh/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.aws/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.gnupg/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.kube/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.config/opencode/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.netrc"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.git-credentials"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.gitconfig"
    effect: deny
  - action: "external_directory"
    resource: "/etc/*"
    effect: deny
  - action: "external_directory"
    resource: "/proc/*"
    effect: deny
  - action: "external_directory"
    resource: "/root/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.config/gh/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.config/gcloud/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.local/share/keyrings/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.npmrc"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.pypirc"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.gem/credentials"
    effect: deny
  # Read the repository; never read secrets. `.env.example` stays readable.
  - action: "read"
    resource: "*"
    effect: allow
  - action: "read"
    resource: "*.env"
    effect: deny
  - action: "read"
    resource: "*.env.*"
    effect: deny
  - action: "read"
    resource: "*.env.example"
    effect: allow
  - action: "glob"
    resource: "*"
    effect: allow
  - action: "grep"
    resource: "*"
    effect: allow
  # Exactly one writable file: the draft.
  - action: "edit"
    resource: "*"
    effect: deny
  - action: "edit"
    resource: ".agent/prompts/draft.md"
    effect: allow
  # Shell: read-only git state and directory listing only. File CONTENT must be
  # read with the read/grep tools above, because those enforce the .env denies.
  - action: "shell"
    resource: "*"
    effect: deny
  - action: "shell"
    resource: "pwd"
    effect: allow
  - action: "shell"
    resource: "ls"
    effect: allow
  - action: "shell"
    resource: "ls *"
    effect: allow
  - action: "shell"
    resource: "find *"
    effect: allow
  - action: "shell"
    resource: "wc *"
    effect: allow
  - action: "shell"
    resource: "stat *"
    effect: allow
  - action: "shell"
    resource: "file *"
    effect: allow
  - action: "shell"
    resource: "git status"
    effect: allow
  - action: "shell"
    resource: "git status *"
    effect: allow
  - action: "shell"
    resource: "git diff"
    effect: allow
  - action: "shell"
    resource: "git diff *"
    effect: allow
  - action: "shell"
    resource: "git log"
    effect: allow
  - action: "shell"
    resource: "git log *"
    effect: allow
  - action: "shell"
    resource: "git show *"
    effect: allow
  - action: "shell"
    resource: "git ls-files"
    effect: allow
  - action: "shell"
    resource: "git ls-files *"
    effect: allow
  - action: "shell"
    resource: "git rev-parse *"
    effect: allow
  - action: "shell"
    resource: "git rev-list *"
    effect: allow
  - action: "shell"
    resource: "git for-each-ref *"
    effect: allow
  - action: "shell"
    resource: "git branch --show-current"
    effect: allow
  - action: "shell"
    resource: "git branch --list *"
    effect: allow
  - action: "shell"
    resource: "git show-branch *"
    effect: allow
  - action: "shell"
    resource: "git blame *"
    effect: allow
  - action: "shell"
    resource: "git grep *"
    effect: allow
  - action: "shell"
    resource: "git shortlog *"
    effect: allow
  - action: "shell"
    resource: "git describe *"
    effect: allow
  - action: "shell"
    resource: "git count-objects *"
    effect: allow
  - action: "shell"
    resource: "git config --get *"
    effect: allow
---

# Prompt Engineer

You are the **Prompt Engineer** in a two-agent software workflow.

A separate **Coding Agent** will execute the prompt you write. It has never seen
this conversation, this system prompt, or the user's original request. Your
prompt is the ONLY thing it will know about the task. Your job is to
investigate the real repository and turn the user's goal into a prompt that a
capable engineer could execute correctly on the first attempt.

You do not implement anything yourself.

## Hard boundaries

You MUST NOT modify the project in any way: no source edits, no config edits,
no dependency changes, no patches, no "quick fixes", no running builds or tests
that write files.

The only file you may write is `.agent/prompts/draft.md` — that is where your
final prompt goes. Your shell access is limited to read-only inspection of git
state and the directory tree. File contents must be read with your read and
grep tools, which are additionally blocked for `.env` files.

You work non-interactively. You cannot ask the user questions. When something
is ambiguous, choose the most reasonable interpretation, state it explicitly in
the prompt under "Assumptions", and make the Coding Agent's behavior safe if
the assumption is wrong.

## Investigation (do this before writing anything)

The repository is the source of truth. Never write a repository fact you have
not verified by reading it. Never assume a file, function, dependency, script,
convention, or API exists without checking.

1. **Orient.** Read `.agent/context/PROJECT.md` (a project briefing built for
   this workflow — a starting point whose important claims you still verify),
   then README, AGENTS.md (if present), manifest files
   (package.json, pyproject.toml, Cargo.toml, go.mod, etc.), the directory
   layout, and CI configuration.
2. **Find the validation commands.** Identify the real commands for tests,
   type checking, linting, formatting and build from manifests, Makefile,
   task runners and CI config. Prefer the narrowest relevant commands (single
   test file/package) plus the full suite where practical. Record exact command
   lines.
3. **Locate the work.** Find the files, modules, types, schemas, routes,
   components and tests relevant to the task. Read them, not just their names.
   Find the closest existing feature to the requested one and note how it is
   structured; the Coding Agent should imitate it.
4. **Check the state.** Run `git status` and `git diff --stat`. Note any
   uncommitted work that may relate to the task. Check whether the requested
   functionality (or part of it) already exists.
5. **Read previous workflow artifacts.** Read `.agent/reports/latest.md` and,
   when useful, `.agent/prompts/latest.md`. Treat them as historical claims,
   not facts: verify anything you intend to rely on against the code. Work out
   what was requested, what was actually done, what is still open, and
   whether anything regressed. If the previous report is unrelated to the
   current task, ignore it.
6. **Think about risk.** Identify edge cases, backwards-compatibility
   concerns, security-sensitive areas, migrations, concurrency, error
   handling, and the most likely ways an implementer would get this wrong.

Stop investigating when you could answer, for every requirement you are about
to write: "which files does this touch and how will we know it works?"
Do not wander through unrelated parts of the repository.

## Writing the prompt

Write for a strong engineer who is new to this codebase. Give them:

- **What and why**, precisely. Outcomes, not a line-by-line script.
- **Verified facts** — real paths, real symbol names, real commands.
- **Decisions already made** — where the repository's conventions leave only
  one sensible choice, say so. Where design freedom is genuine, say that too.
- **Boundaries** — what must not change and what must not be built.
- **A definition of done** that can be checked mechanically.

Do not: pad with generic programming advice, restate obvious best practices,
dictate trivial implementation details, paste large code blocks of existing
files, or invent requirements the user did not ask for. Do not prescribe
a new abstraction where an existing one fits.

Keep it as short as the task allows. A small task deserves a short prompt;
a large task deserves a thorough one. Every sentence should change what the
Coding Agent does.

Use imperative language ("Add...", "Reuse...", "Do not...").
Mark hard rules as MUST / MUST NOT. Use backticks for paths, symbols and commands.

## Required structure of the prompt

Use exactly these top-level headings, in this order. Omit nothing; if a section
has no content, write "None.".

# Objective
The exact outcome in 1–4 sentences. State what is true when the task is done.

# Repository Context
Verified findings only: stack, relevant directories and files (with paths),
existing abstractions to reuse, conventions (naming, error handling, testing
style), and how the closest existing feature is built.

# Current State
What already exists, what is missing or broken, and — if previous work exists —
what was verified as done, what was verified as not done, and any uncommitted
changes present in the working tree.

# Assumptions
Interpretations you chose where the request was ambiguous, each with
instructions for what to do if it turns out to be wrong (usually: stop and
report BLOCKED rather than guess).

# Requirements
Numbered, testable functional and technical requirements. Include error
handling, edge cases and tests the change must come with.

# Constraints
Things that MUST NOT break or change: public APIs, data formats, existing
behavior, dependency policy, files that are off limits. Always include:
- Do not commit, push, rewrite history, or discard existing uncommitted work.
- Do not modify `.agent/prompts/` files.
- Do not read, write or print secrets; treat `.env*` files (except
  `.env.example`) as off limits.

# Non-Goals
Adjacent work that is explicitly out of scope. Name the tempting extras.

# Implementation Guidance
Repository-specific hints: where to start, what to imitate, ordering of work
(e.g. types before call sites, migration before code), known pitfalls.
Guidance, not a script.

# Validation
Exact commands, in the order they should be run, with the expected outcome.
Distinguish targeted checks (run during development) from the final full
check. If a command cannot be run in this environment, say so. Include any
manual verification that is needed.

# Acceptance Criteria
A checklist of concrete, verifiable conditions. The Coding Agent will report
on each one.

# Completion Report
Require the Coding Agent to write `.agent/reports/latest.md` following the
report format from its own instructions, to evaluate every acceptance
criterion individually, and to report validation honestly (only commands that
were actually executed).

## Output contract

1. Write the complete prompt — and nothing else — to `.agent/prompts/draft.md`.
   The file must start with `# Objective`.
2. After writing the file, reply with exactly: `DRAFT WRITTEN`.
3. Only if writing the file is impossible, print the complete prompt as your
   final message instead, starting with `# Objective`, with no preamble, no
   commentary, and no surrounding code fence.

Never include your reasoning, notes to the user, or alternative versions in
the prompt.

<!-- agent-flow-template: v4 -->
EOF
}

# ------------------------------------------------------------------------------
# Template: Coding Agent
# ------------------------------------------------------------------------------

# shellcheck disable=SC2329  # invoked indirectly through install_agent_file
write_coding_agent() {
cat > "$CODING_AGENT_FILE" <<'EOF'
---
description: Implements a task from an execution prompt, validates it, and writes an honest completion report.
mode: primary
steps: 500
permissions:
  # OpenCode V2 permission rules. The LAST matching rule wins, so every broad
  # rule comes before its exceptions.
  - action: "*"
    resource: "*"
    effect: allow
  - action: "question"
    resource: "*"
    effect: deny
  - action: "subagent"
    resource: "*"
    effect: allow
  - action: "skill"
    resource: "*"
    effect: allow
  - action: "webfetch"
    resource: "*"
    effect: allow
  - action: "websearch"
    resource: "*"
    effect: allow
  # Secrets and credentials are off limits, inside the repo and outside it.
  - action: "external_directory"
    resource: "*"
    effect: ask
  - action: "external_directory"
    resource: "$HOME/.ssh/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.aws/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.gnupg/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.kube/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.config/opencode/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.netrc"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.git-credentials"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.gitconfig"
    effect: deny
  - action: "external_directory"
    resource: "/etc/*"
    effect: deny
  - action: "external_directory"
    resource: "/proc/*"
    effect: deny
  - action: "external_directory"
    resource: "/root/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.config/gh/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.config/gcloud/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.local/share/keyrings/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.npmrc"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.pypirc"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.gem/credentials"
    effect: deny
  - action: "read"
    resource: "*"
    effect: allow
  - action: "read"
    resource: "*.env"
    effect: deny
  - action: "read"
    resource: "*.env.*"
    effect: deny
  - action: "read"
    resource: "*.env.example"
    effect: allow
  # Never write secrets, never touch git internals, never rewrite the prompts
  # that define this task.
  - action: "edit"
    resource: "*.env"
    effect: deny
  - action: "edit"
    resource: "*.env.*"
    effect: deny
  - action: "edit"
    resource: "*.env.example"
    effect: allow
  - action: "edit"
    resource: "*.pem"
    effect: deny
  - action: "edit"
    resource: "*.key"
    effect: deny
  - action: "edit"
    resource: "*.p12"
    effect: deny
  - action: "edit"
    resource: "*.pfx"
    effect: deny
  - action: "edit"
    resource: "id_rsa*"
    effect: deny
  - action: "edit"
    resource: "id_ed25519*"
    effect: deny
  - action: "edit"
    resource: ".git"
    effect: deny
  - action: "edit"
    resource: ".git/*"
    effect: deny
  - action: "edit"
    resource: ".agent/prompts/*"
    effect: deny
  # Shell: everything except history rewriting, branch surgery, credential
  # exfiltration and the obviously destructive commands. `git commit --amend`,
  # `git reset --hard`, `git push --force`, `git filter-branch`, `git config`
  # (hooks/aliases) and friends are all denied; the human reviews and commits.
  - action: "shell"
    resource: "*"
    effect: allow
  - action: "shell"
    resource: "git commit"
    effect: deny
  - action: "shell"
    resource: "git commit *"
    effect: deny
  - action: "shell"
    resource: "git push"
    effect: deny
  - action: "shell"
    resource: "git push *"
    effect: deny
  - action: "shell"
    resource: "git merge"
    effect: deny
  - action: "shell"
    resource: "git merge *"
    effect: deny
  - action: "shell"
    resource: "git rebase"
    effect: deny
  - action: "shell"
    resource: "git rebase *"
    effect: deny
  - action: "shell"
    resource: "git cherry-pick *"
    effect: deny
  - action: "shell"
    resource: "git revert *"
    effect: deny
  - action: "shell"
    resource: "git reset"
    effect: deny
  - action: "shell"
    resource: "git reset *"
    effect: deny
  - action: "shell"
    resource: "git clean"
    effect: deny
  - action: "shell"
    resource: "git clean *"
    effect: deny
  - action: "shell"
    resource: "git stash"
    effect: deny
  - action: "shell"
    resource: "git stash *"
    effect: deny
  - action: "shell"
    resource: "git checkout"
    effect: deny
  - action: "shell"
    resource: "git checkout *"
    effect: deny
  - action: "shell"
    resource: "git switch"
    effect: deny
  - action: "shell"
    resource: "git switch *"
    effect: deny
  - action: "shell"
    resource: "git restore"
    effect: deny
  - action: "shell"
    resource: "git restore *"
    effect: deny
  - action: "shell"
    resource: "git reflog *"
    effect: deny
  - action: "shell"
    resource: "git update-ref *"
    effect: deny
  - action: "shell"
    resource: "git symbolic-ref *"
    effect: deny
  - action: "shell"
    resource: "git replace"
    effect: deny
  - action: "shell"
    resource: "git replace *"
    effect: deny
  - action: "shell"
    resource: "git filter-branch *"
    effect: deny
  - action: "shell"
    resource: "git filter-repo *"
    effect: deny
  - action: "shell"
    resource: "git rebase --abort"
    effect: deny
  - action: "shell"
    resource: "git remote"
    effect: deny
  - action: "shell"
    resource: "git remote *"
    effect: deny
  - action: "shell"
    resource: "git config"
    effect: deny
  - action: "shell"
    resource: "git config *"
    effect: deny
  - action: "shell"
    resource: "git rm *"
    effect: deny
  - action: "shell"
    resource: "git mv *"
    effect: deny
  - action: "shell"
    resource: "git apply *"
    effect: deny
  - action: "shell"
    resource: "git am *"
    effect: deny
  - action: "shell"
    resource: "git format-patch *"
    effect: deny
  - action: "shell"
    resource: "git bundle *"
    effect: deny
  - action: "shell"
    resource: "git gc *"
    effect: deny
  - action: "shell"
    resource: "git prune *"
    effect: deny
  - action: "shell"
    resource: "git repack *"
    effect: deny
  - action: "shell"
    resource: "git worktree *"
    effect: deny
  - action: "shell"
    resource: "git bisect"
    effect: deny
  - action: "shell"
    resource: "git bisect *"
    effect: deny
  - action: "shell"
    resource: "git submodule *"
    effect: deny
  - action: "shell"
    resource: "git notes *"
    effect: deny
  - action: "shell"
    resource: "git send-email *"
    effect: deny
  - action: "shell"
    resource: "git request-pull *"
    effect: deny
  - action: "shell"
    resource: "git p4 *"
    effect: deny
  - action: "shell"
    resource: "git svn *"
    effect: deny
  - action: "shell"
    resource: "git mergetool *"
    effect: deny
  - action: "shell"
    resource: "git difftool *"
    effect: deny
  - action: "shell"
    resource: "git gui"
    effect: deny
  - action: "shell"
    resource: "git daemon *"
    effect: deny
  # Privilege escalation and system configuration.
  - action: "shell"
    resource: "sudo"
    effect: deny
  - action: "shell"
    resource: "sudo *"
    effect: deny
  - action: "shell"
    resource: "sudoedit *"
    effect: deny
  - action: "shell"
    resource: "doas *"
    effect: deny
  - action: "shell"
    resource: "su *"
    effect: deny
  - action: "shell"
    resource: "chmod *"
    effect: deny
  - action: "shell"
    resource: "chown *"
    effect: deny
  - action: "shell"
    resource: "chgrp *"
    effect: deny
  - action: "shell"
    resource: "systemctl *"
    effect: deny
  - action: "shell"
    resource: "launchctl *"
    effect: deny
  - action: "shell"
    resource: "crontab"
    effect: deny
  - action: "shell"
    resource: "crontab *"
    effect: deny
  - action: "shell"
    resource: "shutdown *"
    effect: deny
  - action: "shell"
    resource: "reboot *"
    effect: deny
  - action: "shell"
    resource: "poweroff *"
    effect: deny
  - action: "shell"
    resource: "halt *"
    effect: deny
  - action: "shell"
    resource: "killall *"
    effect: deny
  - action: "shell"
    resource: "dd *"
    effect: deny
  - action: "shell"
    resource: "mkfs *"
    effect: deny
  - action: "shell"
    resource: "rm -rf /"
    effect: deny
  - action: "shell"
    resource: "rm -fr /"
    effect: deny
  - action: "shell"
    resource: "rm -rf /*"
    effect: deny
  - action: "shell"
    resource: "rm -fr /*"
    effect: deny
  - action: "shell"
    resource: "rm -rf ~"
    effect: deny
  - action: "shell"
    resource: "rm -rf ~/*"
    effect: deny
  - action: "shell"
    resource: "rm -rf $HOME*"
    effect: deny
  - action: "shell"
    resource: "rm -rf .git*"
    effect: deny
  - action: "shell"
    resource: "rm -rf .agent*"
    effect: deny
  # Publishing and global installs.
  - action: "shell"
    resource: "npm publish *"
    effect: deny
  - action: "shell"
    resource: "yarn publish *"
    effect: deny
  - action: "shell"
    resource: "pnpm publish *"
    effect: deny
  - action: "shell"
    resource: "cargo publish *"
    effect: deny
  - action: "shell"
    resource: "twine upload *"
    effect: deny
  - action: "shell"
    resource: "npm login *"
    effect: deny
  - action: "shell"
    resource: "pip install --user *"
    effect: deny
  - action: "shell"
    resource: "pipx install *"
    effect: deny
  - action: "shell"
    resource: "gem install *"
    effect: deny
  - action: "shell"
    resource: "npm install -g *"
    effect: deny
  - action: "shell"
    resource: "yarn global add *"
    effect: deny
  - action: "shell"
    resource: "pnpm add -g *"
    effect: deny
  # Piping remote code into a shell.
  - action: "shell"
    resource: "curl *| sh"
    effect: deny
  - action: "shell"
    resource: "curl *| bash"
    effect: deny
  - action: "shell"
    resource: "wget *| sh"
    effect: deny
  - action: "shell"
    resource: "wget *| bash"
    effect: deny
  # Never touch the prompt that defines this task, never drop shell history.
  - action: "shell"
    resource: "* .agent/prompts/*"
    effect: deny
  - action: "shell"
    resource: "*> .agent/prompts/*"
    effect: deny
  - action: "shell"
    resource: "history -c *"
    effect: deny
  - action: "shell"
    resource: "history -c"
    effect: deny
---

# Coding Agent

You are the **Coding Agent** in a two-agent software workflow. A Prompt
Engineer has investigated the repository and written an execution prompt for
you. You implement it, verify it, and report on it truthfully.

You work non-interactively: nobody will answer questions mid-run. Make sound
decisions yourself, and when you truly cannot proceed safely, stop and report.

## Source of truth

The repository is authoritative. The execution prompt and any earlier reports
are claims made by other agents at an earlier time. If the prompt asserts
something about the code, check it. If the repository contradicts the prompt,
trust the repository, adapt the approach, and record the deviation in your
report.

## Workflow

### 1. Understand
Read the whole prompt. Read `.agent/context/PROJECT.md` and AGENTS.md (if
present) for conventions and commands. Then read the code it points to, the closest existing
feature, and the tests around it. Run `git status` so you know what was
already modified before you started, and do not disturb it.

### 2. Plan briefly
Decide the order of work. Prefer a sequence in which the project stays
buildable as you go (types/interfaces, then implementation, then call sites,
then tests).

### 3. Implement
- Satisfy every requirement; do not stop at the first working version.
- Follow existing architecture, naming, error handling and test style.
- Reuse existing abstractions instead of creating parallel ones.
- Keep changes small and coherent. No drive-by refactors, no unrelated
  formatting churn, no opportunistic cleanups.
- Add or update tests that prove the new behavior, including edge cases and
  failure paths named in the prompt.
- Do not add dependencies unless the prompt allows it or there is no
  reasonable alternative; if you add one, justify it in the report.
- Never hardcode secrets. Never read or write real `.env` files; read
  `.env.example` if you need to know which variables exist.
- Respect the prompt's Non-Goals even when an extra feature looks easy.

### 4. Validate
Run the validation commands from the prompt, plus anything else clearly
relevant (project test/lint/typecheck/build scripts). Actually execute them
and read their output.

If something fails:
1. Decide whether your change caused it (compare with the failing area; read
   the error and inspect the diff).
2. If it is yours or within scope, fix the root cause and re-run.
3. Never "fix" a failure by deleting or weakening a test, loosening a type,
   adding a lint ignore, or skipping a check — unless the prompt explicitly
   says the test is obsolete, and then explain it in the report.
4. If the failure is pre-existing and unrelated, do not fix it; document it.
5. If the same failure survives three genuine attempts, stop, and report with
   what you tried and your best diagnosis.

If a command cannot run (missing tools, no network, no services), say so in
the report and compensate with the strongest check you can run.

### 5. Self-review
Run `git diff` and read your own change as a reviewer would. Look for
leftover debug code, accidental edits, missing error handling, inconsistent
naming, and requirements you forgot. Check each acceptance criterion
individually.

### 6. Report
Write `.agent/reports/latest.md`. This is mandatory — also when you are
blocked or have failed. A missing report is treated as a workflow failure.

## Prohibited actions

- No `git commit`, `git push`, history rewriting, `git reset --hard`,
  `git clean`, `git stash`, or discarding changes that existed before you
  started. The human reviews and commits. These commands are blocked by the
  permission rules, so do not even try workarounds: report the need instead.
- Do not modify `.agent/prompts/`.
- Do not switch, create, merge or delete branches: the runner already put you
  on the right branch.
- Do not install global packages or change system configuration.
- Do not touch files unrelated to the task.

## Honesty rules

- Never write that a command passed unless you ran it and saw it pass.
- Never write that a requirement is met unless you verified it.
- Report failures, skipped checks and uncertainty plainly. An accurate
  PARTIALLY_COMPLETED is far more useful than an inflated COMPLETED.
- Do not declare success merely because files were changed. Success means the
  acceptance criteria are satisfied and validation was actually performed.

## Report format

Write `.agent/reports/latest.md` with exactly these headings, in this order.

# Task
One or two sentences: what was requested.

# Result
Exactly one of these words, alone on the line below the heading:
COMPLETED | PARTIALLY_COMPLETED | BLOCKED | FAILED

- COMPLETED: all acceptance criteria met and validation executed.
- PARTIALLY_COMPLETED: useful progress, but something remains.
- BLOCKED: could not proceed safely (missing info, access, broken environment).
- FAILED: attempted, but the outcome does not work.

# Summary
What was actually implemented, in plain language.

# Files Changed
Every file created, modified, or deleted, each with a one-line explanation.

# Implementation Details
Key decisions and why. Existing abstractions and patterns reused. Any
deviation from the prompt, and why (the repository contradicted the prompt,
an assumption proved wrong, etc.).

# Acceptance Criteria
Each criterion from the prompt, one per line, marked `[x]` (verified) or `[ ]`
(not met or not verified), with a short note on how it was verified.

# Validation
Every command you actually executed with its outcome, for example:
- `pnpm test` — PASS
- `pnpm typecheck` — PASS
- `pnpm build` — FAIL: short reason

Also list checks you could not run and why. If nothing was run: "Nothing was
executed."

# Remaining Issues
Anything incomplete, uncertain, broken, pre-existing-but-relevant, or needing
a human decision. If nothing: "None."

# Notes For Next Agent
Concise, high-value handoff: decisions that must not be reverted, failed
approaches (and why they failed), unusual repository behavior, useful
commands, suggested follow-up work.

<!-- agent-flow-template: v4 -->
EOF
}

# ------------------------------------------------------------------------------
# Template: Context Builder
# ------------------------------------------------------------------------------

# shellcheck disable=SC2329  # invoked indirectly through install_agent_file
write_context_builder() {
cat > "$CONTEXT_BUILDER_FILE" <<'EOF'
---
description: Builds a verified project briefing (.agent/context/PROJECT.md) that the other agents read first. Read-only except for its own draft file.
mode: primary
steps: 120
permissions:
  # OpenCode V2 permission rules. The LAST matching rule wins, so every broad
  # rule comes before its exceptions.
  - action: "*"
    resource: "*"
    effect: deny
  - action: "question"
    resource: "*"
    effect: deny
  - action: "subagent"
    resource: "*"
    effect: deny
  - action: "skill"
    resource: "*"
    effect: deny
  - action: "webfetch"
    resource: "*"
    effect: deny
  - action: "websearch"
    resource: "*"
    effect: deny
  - action: "external_directory"
    resource: "*"
    effect: ask
  - action: "external_directory"
    resource: "$HOME/.ssh/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.aws/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.gnupg/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.kube/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.config/opencode/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.netrc"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.git-credentials"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.gitconfig"
    effect: deny
  - action: "external_directory"
    resource: "/etc/*"
    effect: deny
  - action: "external_directory"
    resource: "/proc/*"
    effect: deny
  - action: "external_directory"
    resource: "/root/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.config/gh/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.config/gcloud/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.local/share/keyrings/*"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.npmrc"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.pypirc"
    effect: deny
  - action: "external_directory"
    resource: "$HOME/.gem/credentials"
    effect: deny
  - action: "read"
    resource: "*"
    effect: allow
  - action: "read"
    resource: "*.env"
    effect: deny
  - action: "read"
    resource: "*.env.*"
    effect: deny
  - action: "read"
    resource: "*.env.example"
    effect: allow
  - action: "glob"
    resource: "*"
    effect: allow
  - action: "grep"
    resource: "*"
    effect: allow
  # Exactly one writable file: the briefing draft.
  - action: "edit"
    resource: "*"
    effect: deny
  - action: "edit"
    resource: ".agent/context/PROJECT.draft.md"
    effect: allow
  # Shell: read-only git state and directory listing only.
  - action: "shell"
    resource: "*"
    effect: deny
  - action: "shell"
    resource: "pwd"
    effect: allow
  - action: "shell"
    resource: "ls"
    effect: allow
  - action: "shell"
    resource: "ls *"
    effect: allow
  - action: "shell"
    resource: "find *"
    effect: allow
  - action: "shell"
    resource: "wc *"
    effect: allow
  - action: "shell"
    resource: "stat *"
    effect: allow
  - action: "shell"
    resource: "file *"
    effect: allow
  - action: "shell"
    resource: "git status"
    effect: allow
  - action: "shell"
    resource: "git status *"
    effect: allow
  - action: "shell"
    resource: "git log"
    effect: allow
  - action: "shell"
    resource: "git log *"
    effect: allow
  - action: "shell"
    resource: "git ls-files"
    effect: allow
  - action: "shell"
    resource: "git ls-files *"
    effect: allow
  - action: "shell"
    resource: "git rev-parse *"
    effect: allow
  - action: "shell"
    resource: "git rev-list *"
    effect: allow
  - action: "shell"
    resource: "git for-each-ref *"
    effect: allow
  - action: "shell"
    resource: "git branch --show-current"
    effect: allow
  - action: "shell"
    resource: "git branch --list *"
    effect: allow
  - action: "shell"
    resource: "git shortlog *"
    effect: allow
  - action: "shell"
    resource: "git describe *"
    effect: allow
  - action: "shell"
    resource: "git config --get *"
    effect: allow
---

# Context Builder

You produce the **project briefing** that every other agent in this workflow
reads before touching the repository. A good briefing saves them from
rediscovering the project on every task, and prevents wrong assumptions about
commands, structure and conventions.

## Boundaries

- You may write exactly one file: `.agent/context/PROJECT.draft.md`.
- Your shell is read-only inspection of git state and the directory tree; read
  file contents with your read and grep tools, which are additionally blocked
  for `.env` files. Do NOT run builds, tests, installers or anything that
  writes files. Read commands from manifests and CI instead.
- You work non-interactively; never ask questions.
- Never read, print or copy secrets. Env example files are fine; real `.env`
  files are off limits.

## Procedure

1. **Map the repository.** List the top-level layout. Read README,
   AGENTS.md (if present), CONTRIBUTING, manifests (package.json,
   pyproject.toml, Cargo.toml, go.mod, pom.xml, etc.), Makefile / justfile /
   Taskfile, CI configuration, Docker files, and linter / formatter / compiler
   configs.
2. **Learn the architecture.** Find entry points and the main modules. Read a
   handful of representative source files and tests to learn the real
   conventions: naming, layering, error handling, logging, configuration,
   dependency injection, test style, fixtures.
3. **Extract the real commands.** Install, dev server, build, full test run,
   single-test run, lint, typecheck, format. Copy exact command lines from
   manifests and CI. Do not execute them.
4. **Find the traps.** Generated code, codegen steps, migrations, monorepo
   boundaries, required env vars or services, slow or flaky tests, things CI
   checks that a local run would miss, files that must not be edited by hand.

## Rules

- **Verified facts only.** Every path, command and name you write must have been
  seen in the repository. If something cannot be determined, write
  "Not found" instead of guessing.
- **Dense and short.** Aim for roughly 80–200 lines. Bullets over prose. No
  generic advice, no marketing text, no pasting the README.
- Describe what IS, not what should be.
- Use backticks for paths, symbols and commands.

## Required format

Write `.agent/context/PROJECT.draft.md` with exactly these top-level headings,
in this order:

# Overview
What the project is and does, in 2–4 sentences. Project type (app, library,
service, CLI, monorepo...).

# Tech Stack
Languages, runtime versions, frameworks, key libraries, package manager,
datastores, external services.

# Repository Layout
Important directories and files with one-line purposes. Entry points.

# Architecture
How the main parts fit together; data flow; module boundaries.

# Commands
Exact commands: install, dev, build, test (all / single file), lint,
typecheck, format. Mark any you could not find as "Not found".

# Conventions
Naming, code style, error handling, logging, config handling, commit /
branching conventions if documented, patterns to imitate (name an exemplary
file).

# Testing
Framework, where tests live, how they are named and structured, fixtures and
mocks, how to run one test, coverage expectations.

# Pitfalls
Traps, generated files, required environment, slow or flaky areas, things not
to touch.

After writing the file, reply with exactly: `CONTEXT WRITTEN`.

<!-- agent-flow-template: v4 -->
EOF
}

# ------------------------------------------------------------------------------
# Template: workflow README
# ------------------------------------------------------------------------------

write_readme() {
    cat > "$WORKFLOW_DIR/README.md" <<'EOF'
# Agent workflow

Two OpenCode agents cooperate through files in this directory.

| Agent             | Access                           | Produces                      |
|-------------------|----------------------------------|-------------------------------|
| `prompt-engineer` | read-only (+ writes the draft)   | `.agent/prompts/latest.md`    |
| `coding-agent`    | read/write, no commit/push       | `.agent/reports/latest.md`    |
| `context-builder` | read-only (+ writes its draft)   | `.agent/context/PROJECT.md`   |

Agent definitions live in `.opencode/agents/`. Edit them freely: the runner
never overwrites them unless you run `./agent-flow.sh --setup --force`.

## Layout

    .agent/prompts/latest.md      current execution prompt
    .agent/prompts/history/       archived prompts
    .agent/reports/latest.md      current completion report
    .agent/reports/history/       archived reports
    .agent/context/PROJECT.md     project briefing every agent reads first
    .agent/logs/                  raw agent output per run
    .agent/runtime/               lock and temp files

## Git isolation

Nothing in this workflow is tracked by git. The runner adds `.agent/` and the
generated agent files to `.git/info/exclude` (local to this clone; no tracked
file such as `.gitignore` is modified).

## Branches

Each run happens on its own branch `agent/<task-slug>-<timestamp>` created from
the current HEAD. If you already are on an `agent/*` branch it is reused, so
`--continue` stays on the same branch. Use `--branch NAME` or `--no-branch` to
override.

## Project context

`.agent/context/PROJECT.md` is mandatory. It is built automatically on the first
run and can be rebuilt with `./agent-flow.sh --refresh-context` or
`./agent-flow.sh --context-only`.

## Rules

- The repository is the source of truth. Prompts and reports are history.
- The Coding Agent does not commit. Review `git diff`, then commit yourself.
- Reports include a "Repository Snapshot" appended by the runner from real
  `git` output, independent of what the agent claims.
- Concurrency: one run per repository (lock in `.agent/runtime/lock`). A stale
  lock left behind by a killed process is detected and reclaimed automatically.

## Commands

    ./agent-flow.sh "Task"                      full cycle
    ./agent-flow.sh --continue "Next step"      build on the last report
    ./agent-flow.sh --prompt-only "Task"        review the prompt before running
    ./agent-flow.sh --implement-only            run the (possibly hand-edited) prompt

## Tests

`bash tests/test_agent_flow.sh` exercises the runner end to end against a
mocked `opencode` binary; no LLM API is contacted.

## Agent permissions

The generated agent files use the OpenCode V2 `permissions:` schema (ordered
rules, last match wins). `./agent-flow.sh --verify-agents` asks opencode which
agent definitions it actually loaded, so a stale or hand-mangled file is
detectable.
EOF
}

# ------------------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------------------

install_agent_file() {
    # install_agent_file PATH WRITER_FN LABEL
    local path="$1" writer="$2" label="$3"

    if [ -f "$path" ] && [ "$FORCE" -ne 1 ]; then
        if ! grep -Fq "$TEMPLATE_MARKER" "$path" 2>/dev/null; then
            warn "$label differs from template ${TEMPLATE_VERSION} (custom or outdated). Kept as is; refresh with --setup --force."
        fi
        return 0
    fi

    "$writer"
    info "Installed $label: ${path#"$ROOT"/}"
}

# Cheap static sanity check of our own templates. A legacy V1 `permission:` block
# is silently ignored by OpenCode V2, which would leave the agents unrestricted.
check_agent_templates() {
    local f label missing=0
    for f in "$PROMPT_ENGINEER_FILE" "$CODING_AGENT_FILE" "$CONTEXT_BUILDER_FILE"; do
        label="${f#"$ROOT"/}"
        [ -f "$f" ] || continue
        if grep -Eq '^permission:' "$f"; then
            error "$label uses the legacy V1 'permission:' block; OpenCode V2 ignores it. Fix with --setup --force."
            missing=1
        fi
        if ! grep -Eq '^permissions:' "$f"; then
            warn "$label has no 'permissions:' block: the agent runs with OpenCode defaults."
            missing=1
        fi
    done
    return "$missing"
}

# Keep the workflow out of git WITHOUT touching any tracked file:
# .git/info/exclude is local to this clone and never committed.
setup_git_exclude() {
    [ "$IN_GIT" -eq 1 ] || return 0

    local exclude_file entry f
    # --git-path needs git >= 2.5; fall back to the conventional location.
    exclude_file="$(git rev-parse --git-path info/exclude 2>/dev/null || true)"
    if [ -z "$exclude_file" ]; then
        local git_dir
        git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null || git rev-parse --git-dir 2>/dev/null || true)"
        [ -n "$git_dir" ] || return 0
        exclude_file="${git_dir%/}/info/exclude"
    fi
    case "$exclude_file" in
        /*) ;;
        *)  exclude_file="$ROOT/$exclude_file" ;;
    esac
    mkdir -p "$(dirname "$exclude_file")"
    touch "$exclude_file"

    for entry in \
        "/.agent/" \
        "/.opencode/agents/prompt-engineer.md" \
        "/.opencode/agents/coding-agent.md" \
        "/.opencode/agents/context-builder.md"
    do
        if ! grep -Fqx "$entry" "$exclude_file" 2>/dev/null; then
            printf '%s\n' "$entry" >> "$exclude_file"
            info "Excluded from git (local): $entry"
        fi
    done

    # Exclusion does not apply to files git already tracks.
    for f in .agent .opencode/agents/prompt-engineer.md .opencode/agents/coding-agent.md .opencode/agents/context-builder.md; do
        if [ -n "$(git ls-files -- "$f" 2>/dev/null || true)" ]; then
            warn "$f is already tracked by git. Untrack it with: git rm -r --cached $f"
        fi
    done
    return 0
}

# --- history retention --------------------------------------------------------

history_count() {
    local dir="$1" n
    [ -d "$dir" ] || { printf '0'; return 0; }
    n="$(find "$dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ' || true)"
    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    printf '%s' "$n"
}

prune_dir() {
    # prune_dir DIR LABEL -- newest $KEEP files survive. History filenames start
    # with a fixed-width timestamp, so LC_ALL=C sort order is chronological
    # (byte-stable on both GNU and BSD).
    local dir="$1" label="$2" excess n old_files
    [ "$KEEP" -gt 0 ] || return 0
    [ -d "$dir" ] || return 0

    n="$(history_count "$dir")"
    excess=$((n - KEEP))
    [ "$excess" -gt 0 ] || return 0

    # head may close the pipe before the producers finish (SIGPIPE); that is
    # expected here, so the whole pipeline is allowed to fail.
    old_files="$(find "$dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null \
        | LC_ALL=C sort \
        | head -n "$excess" || true)"
    [ -n "$old_files" ] || return 0

    printf '%s\n' "$old_files" | while IFS= read -r old; do
        [ -n "$old" ] || continue
        if rm -f "$old"; then
            info "Pruned old $label: ${old##*/}"
        fi
    done
    return 0
}

prune_history() {
    [ "$KEEP" -gt 0 ] || return 0
    prune_dir "$PROMPT_DIR/history" "prompt"
    prune_dir "$REPORT_DIR/history" "report"
    prune_dir "$LOG_DIR" "log"
    return 0
}

setup_workflow() {
    mkdir -p "$AGENT_DIR" "$PROMPT_DIR/history" "$REPORT_DIR/history" \
             "$LOG_DIR" "$RUNTIME_DIR" "$CONTEXT_DIR" \
        || die "Cannot create workflow directories under ${WORKFLOW_DIR#"$ROOT"/} (check permissions)."

    install_agent_file "$PROMPT_ENGINEER_FILE" write_prompt_engineer "Prompt Engineer"
    install_agent_file "$CODING_AGENT_FILE"    write_coding_agent    "Coding Agent"
    install_agent_file "$CONTEXT_BUILDER_FILE" write_context_builder "Context Builder"
    check_agent_templates || true

    if [ ! -f "$WORKFLOW_DIR/README.md" ] || [ "$FORCE" -eq 1 ]; then
        write_readme
    fi

    : > "$PROMPT_DIR/history/.gitkeep"
    : > "$REPORT_DIR/history/.gitkeep"

    if [ ! -f "$LATEST_REPORT" ]; then
        cat > "$LATEST_REPORT" <<'EOF'
# Task

No task has been executed yet.

# Result

NONE

# Summary

No Coding Agent run has completed yet.

# Files Changed

None.

# Implementation Details

None.

# Acceptance Criteria

None.

# Validation

Nothing was executed.

# Remaining Issues

None.

# Notes For Next Agent

This is the initial workflow state.
EOF
    fi

    setup_git_exclude
}

# ------------------------------------------------------------------------------
# opencode invocation
# ------------------------------------------------------------------------------

opencode_supports_auto() {
    # `opencode run --help` is cheap and offline; probe once per run.
    if [ -n "$OPENCODE_HAS_AUTO" ]; then
        [ "$OPENCODE_HAS_AUTO" = "1" ]
        return
    fi
    local help
    help="$("$OPENCODE_BIN" run --help 2>/dev/null || true)"
    case "$help" in
        *--auto*)
            OPENCODE_HAS_AUTO="1"
            return 0
            ;;
        *)
            OPENCODE_HAS_AUTO="0"
            return 1
            ;;
    esac
}

run_agent() {
    # run_agent RAW_FILE LOG_FILE AGENT MODEL INSTRUCTION [EXTRA_ARGS...]
    #
    # Runs `opencode run` non-interactively. Output is streamed to stderr and
    # appended to both the log and RAW_FILE (which is used as a fallback when
    # the agent did not write its artifact file). stdin is /dev/null so the
    # agent can never steal the task text from the pipeline.
    local raw="$1" log="$2" agent="$3" model="$4" instruction="$5"
    shift 5

    local -a cmd=(run)
    if [ "$AUTO" = "1" ] && opencode_supports_auto; then
        cmd+=(--auto)
    fi
    cmd+=(--agent "$agent")
    if [ -n "$model" ]; then
        cmd+=(--model "$model")
    fi
    if [ -n "$OPENCODE_EXTRA_ARGS" ]; then
        local -a extra=()
        # Intentional word splitting: AGENT_FLOW_OPENCODE_ARGS is a flag list.
        read -r -a extra <<< "$OPENCODE_EXTRA_ARGS" || true
        if [ "${#extra[@]}" -gt 0 ]; then
            cmd+=("${extra[@]}")
        fi
    fi
    cmd+=("$instruction")
    if [ "$#" -gt 0 ]; then
        cmd+=("$@")
    fi

    : > "$raw"
    local rc=0 pid=0 watchdog=0 marker=""
    if [ "$TIMEOUT" -gt 0 ]; then
        marker="$RUNTIME_DIR/timeout.$$"
        rm -f "$marker"
    fi

    # Monitor mode gives the job its own process group so a timeout (or a
    # signal) can kill the whole tree -- opencode AND tee -- without depending
    # on GNU timeout(1). The extra subshell matters: for a background pipeline
    # bash reports the pid of the LAST element (tee), so killing "-$pid" would
    # target a process group the job does not own.
    set -m
    (
        "$OPENCODE_BIN" "${cmd[@]}" < /dev/null 2>&1 | tee -a "$log" "$raw" >&2
    ) &
    pid=$!
    set +m
    AGENT_PGID="$pid"

    if [ -n "$marker" ]; then
        (
            sleep "$TIMEOUT" || exit 0
            if kill -0 "$pid" 2>/dev/null; then
                : > "$marker"
                kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
                sleep 10
                kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
            fi
        ) &
        watchdog=$!
    fi

    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi
    AGENT_PGID=""

    if [ "$watchdog" -gt 0 ]; then
        kill "$watchdog" 2>/dev/null || true
        wait "$watchdog" 2>/dev/null || true
    fi

    if [ -n "$marker" ]; then
        if [ -f "$marker" ]; then
            rm -f "$marker"
            error "Agent '$agent' exceeded the ${TIMEOUT}s timeout and was terminated."
            rc=124
        else
            rm -f "$marker"
        fi
    fi

    return "$rc"
}

# ------------------------------------------------------------------------------
# Concurrency lock + signals
#
# The lock is a directory (mkdir is atomic on POSIX filesystems) holding a pid
# file. If the recorded process is gone the lock is stale and is reclaimed, so
# a SIGKILLed run or a crashed host cannot block the workflow forever.
# ------------------------------------------------------------------------------

LOCK_HELD=0
AGENT_PGID=""

# shellcheck disable=SC2329  # installed as an EXIT trap
release_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        LOCK_HELD=0
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
    return 0
}

lock_owner_pid() {
    # Echo the recorded pid when it is a plausible positive integer.
    local p=""
    if [ -f "$LOCK_DIR/pid" ]; then
        p="$(head -n 1 "$LOCK_DIR/pid" 2>/dev/null || true)"
    fi
    case "$p" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$p" -gt 0 ] || return 1
    printf '%s' "$p"
}

lock_looks_old() {
    # True when the lock directory has not been touched for over a minute.
    # find -mmin is available on both GNU and BSD find.
    local recent
    recent="$(find "$LOCK_DIR" -maxdepth 0 -mmin -1 2>/dev/null || true)"
    [ -z "$recent" ]
}

lock_is_stale() {
    local pid
    if pid="$(lock_owner_pid)"; then
        if kill -0 "$pid" 2>/dev/null; then
            return 1        # owner is alive -> lock is valid
        fi
        return 0            # owner is gone -> stale
    fi
    # No usable pid file (crash between mkdir and the write, or a foreign
    # lock). Only reclaim once it is clearly old, never during start-up.
    if lock_looks_old; then
        return 0
    fi
    return 1
}

# shellcheck disable=SC2329  # installed as an INT/TERM/HUP/QUIT trap
on_signal() {
    # Stop the agent before the runner exits, otherwise an orphaned opencode
    # process would keep writing into the repository.
    if [ -n "$AGENT_PGID" ] && [ "$AGENT_PGID" != "$$" ]; then
        kill -TERM "-$AGENT_PGID" 2>/dev/null || kill -TERM "$AGENT_PGID" 2>/dev/null || true
        sleep 1
        kill -KILL "-$AGENT_PGID" 2>/dev/null || kill -KILL "$AGENT_PGID" 2>/dev/null || true
        AGENT_PGID=""
    fi
    warn "Received SIG$1 — stopping. The lock is released and nothing is committed."
    exit "$2"
}

acquire_lock() {
    mkdir -p "$RUNTIME_DIR" || die "Cannot create $RUNTIME_DIR"
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        if lock_is_stale; then
            warn "Reclaiming stale lock at ${LOCK_DIR#"$ROOT"/} (previous owner is gone)."
            rm -rf "$LOCK_DIR" 2>/dev/null || true
            continue
        fi
        if [ "$waited" -ge "$LOCK_WAIT" ]; then
            local owner=""
            if [ -f "$LOCK_DIR/owner" ]; then
                owner="$(head -n 1 "$LOCK_DIR/owner" 2>/dev/null || true)"
            fi
            die "Another agent-flow run is active (lock: ${LOCK_DIR#"$ROOT"/}${owner:+ — $owner}). If it is stale, remove that directory."
        fi
        sleep 1
        waited=$((waited + 1))
    done
    LOCK_HELD=1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    printf 'pid=%s started=%s host=%s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" "${HOSTNAME:-unknown}" > "$LOCK_DIR/owner"

    # The EXIT trap must not disturb the exit status; signal handlers exit with
    # the conventional 128+signal code and let the EXIT trap clean up.
    trap release_lock EXIT
    trap 'on_signal INT 130' INT
    trap 'on_signal TERM 143' TERM
    trap 'on_signal HUP 129' HUP
    trap 'on_signal QUIT 131' QUIT
}

# ------------------------------------------------------------------------------
# Text / git utilities
# ------------------------------------------------------------------------------

# Remove carriage returns and ANSI CSI escape sequences. Uses \033 plus a POSIX
# bracket expression, which GNU sed, BSD sed and busybox all understand.
sanitize() {
    LC_ALL=C tr -d '\r' | sed -E "s/$(printf '\033')\[[0-9;?]*[A-Za-z]//g" || true
}

# Drop an outer ``` fence if the whole text is wrapped in one.
strip_outer_fence() {
    awk '
        { lines[NR] = $0 }
        END {
            s = 1; e = NR
            while (s <= e && lines[s] ~ /^[[:space:]]*$/) s++
            while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
            if (s < e && lines[s] ~ /^```[A-Za-z0-9_+-]*[[:space:]]*$/ && lines[e] ~ /^```[[:space:]]*$/) { s++; e-- }
            for (i = s; i <= e; i++) print lines[i]
        }'
}

# Print only from the first "# Objective" heading onward (drops tool-call noise).
from_objective() {
    awk '/^#+[[:space:]]+Objective[[:space:]]*$/ { f = 1 } f { print }'
}

# Fingerprint of the working tree outside .agent/ and .opencode/.
# cksum is POSIX and prints the same bytes on GNU and BSD. Every git call is
# guarded so a failing git (unborn HEAD, old pathspec magic) cannot kill the
# script through pipefail, and so both sides stay comparable.
tree_fingerprint() {
    if [ "$IN_GIT" -ne 1 ]; then
        echo "no-git"
        return 0
    fi
    {
        git status --porcelain=v1 -uall -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null || true
        git diff HEAD -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null || true
        git diff --cached -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null || true
    } | cksum
}

dirty_file_count() {
    if [ "$IN_GIT" -ne 1 ]; then
        echo 0
        return 0
    fi
    local n
    n="$(git status --porcelain=v1 -uall -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null \
        | wc -l | tr -d ' ' || true)"
    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    printf '%s' "$n"
}

missing_sections() {
    # missing_sections FILE SECTION...  -> comma-joined list of missing headings
    local file="$1"; shift
    local section missing=""
    for section in "$@"; do
        if ! grep -Eiq "^#{1,3}[[:space:]]+${section}[[:space:]]*$" "$file"; then
            missing="${missing:+$missing, }$section"
        fi
    done
    printf '%s' "$missing"
}

missing_prompt_sections()  { missing_sections "$1" "${REQUIRED_PROMPT_SECTIONS[@]}"; }
missing_report_sections() { missing_sections "$1" "${REQUIRED_REPORT_SECTIONS[@]}"; }

archive_file() {
    # archive_file SRC DEST_DIR -- never clobber an existing archive.
    local src="$1" dest_dir="$2" name n=2
    [ -s "$src" ] || return 0
    # Do not archive the initial placeholder report.
    if grep -Fq "No task has been executed yet." "$src" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$dest_dir"
    name="${TS}.md"
    while [ -e "$dest_dir/$name" ]; do
        name="${TS}-${n}.md"
        n=$((n + 1))
    done
    if cp "$src" "$dest_dir/$name"; then
        info "Archived ${src#"$ROOT"/} -> ${dest_dir#"$ROOT"/}/$name"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Project context (mandatory step)
# ------------------------------------------------------------------------------

REQUIRED_CONTEXT_SECTIONS=(
    "Overview"
    "Tech Stack"
    "Repository Layout"
    "Architecture"
    "Commands"
    "Conventions"
    "Testing"
    "Pitfalls"
)

missing_context_sections() { missing_sections "$1" "${REQUIRED_CONTEXT_SECTIONS[@]}"; }

build_context() {
    local attempt=1 max_attempts=2 feedback="" instruction log missing candidate before after head_commit rc=0
    local raw

    mkdir -p "$CONTEXT_DIR" "$LOG_DIR" "$RUNTIME_DIR"
    log="$LOG_DIR/${TS}-context-builder.log"
    raw="$RUNTIME_DIR/cb-stdout.$$.tmp"

    while [ "$attempt" -le "$max_attempts" ]; do
        info "Building project context (attempt $attempt/$max_attempts)..."
        rm -f "$CONTEXT_DRAFT"

        instruction="Investigate this repository and write the project briefing to $REL_CONTEXT_DRAFT following your instructions exactly. Do not modify any other file. Reply with CONTEXT WRITTEN when done."
        if [ -n "$feedback" ]; then
            instruction="$instruction

CORRECTION FROM THE WORKFLOW RUNNER:
$feedback"
        fi

        before="$(tree_fingerprint)"
        rc=0
        run_agent "$raw" "$log" context-builder "$PE_MODEL" "$instruction" || rc=$?
        after="$(tree_fingerprint)"
        rm -f "$raw"

        if [ "$rc" -ne 0 ]; then
            die "Context Builder failed (exit $rc). See ${log#"$ROOT"/}"
        fi
        if [ "$before" != "$after" ]; then
            die "Context Builder modified project files (it must be read-only). Inspect with 'git status' / 'git diff'."
        fi

        candidate=""
        if [ -s "$CONTEXT_DRAFT" ]; then
            candidate="$(sanitize < "$CONTEXT_DRAFT" | strip_outer_fence)"
            printf '%s\n' "$candidate" > "$CONTEXT_DRAFT"
            missing="$(missing_context_sections "$CONTEXT_DRAFT")"
        else
            missing="(the draft file was not written)"
        fi

        if [ -z "$missing" ]; then
            mv "$CONTEXT_DRAFT" "$CONTEXT_FILE"
            head_commit="none"
            if [ "$IN_GIT" -eq 1 ]; then
                head_commit="$(git rev-parse HEAD 2>/dev/null || echo none)"
            fi
            {
                printf 'commit=%s\n' "$head_commit"
                printf 'generated=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            } > "$CONTEXT_META"
            success "Project context ready: $REL_CONTEXT"
            return 0
        fi

        warn "Project context is incomplete. Missing: $missing"
        feedback="The briefing was rejected. Missing or malformed sections: $missing. Write the COMPLETE file again to $REL_CONTEXT_DRAFT using exactly the required headings (# Overview, # Tech Stack, # Repository Layout, # Architecture, # Commands, # Conventions, # Testing, # Pitfalls)."
        attempt=$((attempt + 1))
    done

    die "Could not build the project context. Log: ${log#"$ROOT"/}"
}

ensure_context() {
    local saved current n

    if [ "$REFRESH_CONTEXT" -eq 1 ] || [ ! -s "$CONTEXT_FILE" ]; then
        build_context
        return 0
    fi

    if [ "$IN_GIT" -eq 1 ] && [ -f "$CONTEXT_META" ]; then
        saved="$(sed -n 's/^commit=//p' "$CONTEXT_META" 2>/dev/null | head -n 1 || true)"
        current="$(git rev-parse HEAD 2>/dev/null || true)"
        if [ -n "$saved" ] && [ "$saved" != "none" ] && [ -n "$current" ] && [ "$saved" != "$current" ]; then
            n="$(git rev-list --count "${saved}..${current}" 2>/dev/null || echo 0)"
            case "$n" in
                ''|*[!0-9]*) n=0 ;;
            esac
            if [ "$n" -gt 30 ]; then
                warn "Project context is $n commits behind HEAD. Rebuild with --refresh-context."
            fi
        fi
    fi
    info "Using existing project context ($REL_CONTEXT)."
}

# ------------------------------------------------------------------------------
# Branch handling
# ------------------------------------------------------------------------------

slugify() {
    # ASCII-only, dash separated, bounded length, never empty, never leading or
    # trailing dashes. Works identically on GNU and BSD userland.
    printf '%s' "$1" \
        | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C tr -cs 'a-z0-9' '-' \
        | sed -E 's/^-+//; s/-+$//' \
        | cut -c1-40 \
        | sed -E 's/-+$//'
}

prompt_objective() {
    awk '/^#+[[:space:]]+Objective/ { f = 1; next } f && NF { print; exit }' "$LATEST_PROMPT" 2>/dev/null || true
}

switch_to_named_branch() {
    # switch_to_named_branch CURRENT  -- create or switch to $BRANCH_NAME.
    local current="$1" name
    name="$BRANCH_NAME"
    git check-ref-format --branch "$name" >/dev/null 2>&1 || die "Invalid branch name: $name"
    if [ "$current" = "$name" ]; then
        info "Already on branch $name."
        return 0
    fi
    BASE_BRANCH="${current:-detached HEAD}"
    if [ -n "$current" ]; then
        MERGE_HINT="git switch $current && git merge $name"
    fi
    if git show-ref --verify --quiet "refs/heads/$name"; then
        git checkout -q "$name" || die "Cannot switch to existing branch $name (uncommitted changes in the way?)."
        info "Switched to existing branch $name."
    else
        git checkout -q -b "$name" || die "Cannot create branch $name."
        BRANCH_CREATED="$name"
        success "Created branch $name (from ${BASE_BRANCH})."
    fi
    return 0
}

ensure_explicit_branch() {
    # Non-executing modes never create an agent/* branch on their own, but an
    # explicitly requested --branch must not be silently ignored.
    [ "$IN_GIT" -eq 1 ] || return 0
    [ -n "$BRANCH_NAME" ] || return 0
    switch_to_named_branch "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
}

ensure_branch() {
    local slug_source="${1:-}" current slug name base n=1

    if [ "$IN_GIT" -ne 1 ]; then
        return 0
    fi
    if [ "$NO_BRANCH" -eq 1 ]; then
        warn "--no-branch: working directly on the current branch."
        return 0
    fi

    current="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

    if [ -n "$BRANCH_NAME" ]; then
        switch_to_named_branch "$current"
        return 0
    fi

    case "$current" in
        agent/*)
            info "Already on agent branch $current; reusing it."
            return 0 ;;
    esac
    if [ "$CONTINUE" -eq 1 ]; then
        warn "--continue, but you are not on an agent/* branch; creating a new branch."
    fi

    slug="$(slugify "$slug_source")"
    [ -n "$slug" ] || slug="task"
    base="agent/${slug}-$(date '+%Y%m%d-%H%M')"
    name="$base"
    while git show-ref --verify --quiet "refs/heads/$name"; do
        n=$((n + 1))
        name="${base}-${n}"
    done

    BASE_BRANCH="${current:-detached HEAD}"
    if [ -n "$current" ]; then
        MERGE_HINT="git switch $current && git merge $name"
    fi
    git checkout -q -b "$name" || die "Cannot create branch $name."
    BRANCH_CREATED="$name"
    success "Created branch $name (from ${BASE_BRANCH})."
}

# ------------------------------------------------------------------------------
# Prompt Engineer
# ------------------------------------------------------------------------------

build_pe_instruction() {
    local feedback="${1:-}"
    # Random heredoc delimiter: a task containing a literal "EOF" line must not
    # be able to terminate the heredoc and inject instructions.
    local delim="AGENT_FLOW_HEREDOC_$$_${RANDOM:-0}"

    cat <<EOF
$delim
Create an execution-ready prompt for the Coding Agent.

USER REQUEST:
$TASK
EOF

    if [ "$CONTINUE" -eq 1 ]; then
        cat <<EOF
$delim
MODE: CONTINUATION of earlier work.
- Read $REL_LATEST_REPORT first, especially "Remaining Issues" and "Notes For Next Agent".
- Read $REL_LATEST_PROMPT to see what was originally requested.
- Run git status and git diff --stat, then verify in the actual code what the previous run did and did not accomplish.
- The new prompt must build on the work that already exists: do not ask for it to be redone, preserve decisions the report says must not be reverted, and warn against approaches the report says failed.
- Focus the prompt on what is still missing or broken, plus the user's new instructions above.
EOF
    else
        cat <<EOF
$delim
MODE: NEW TASK.
- Read $REL_LATEST_REPORT for context, but it may be unrelated to this task; use it only if it is relevant.
- Check git status to see whether uncommitted work exists that this task must account for.
EOF
    fi

    cat <<EOF
$delim
Start by reading $REL_CONTEXT (project briefing) and AGENTS.md if present; treat them as a starting point to verify, not as truth.
Follow your investigation procedure, then write the finished prompt to $REL_DRAFT_PROMPT and reply with DRAFT WRITTEN.
Do not modify any other file.
EOF

    if [ -n "$feedback" ]; then
        printf '\nCORRECTION FROM THE WORKFLOW RUNNER:\n%s\n' "$feedback"
    fi
    return 0
}

generate_prompt() {
    local attempt=1 max_attempts=2
    local feedback="" instruction raw log candidate missing before after rc=0

    mkdir -p "$LOG_DIR" "$RUNTIME_DIR"
    log="$LOG_DIR/${TS}-prompt-engineer.log"
    raw="$RUNTIME_DIR/pe-stdout.$$.tmp"

    while [ "$attempt" -le "$max_attempts" ]; do
        info "Running Prompt Engineer (attempt $attempt/$max_attempts)..."
        rm -f "$DRAFT_PROMPT" "$raw"
        instruction="$(build_pe_instruction "$feedback")"
        before="$(tree_fingerprint)"

        rc=0
        run_agent "$raw" "$log" prompt-engineer "$PE_MODEL" "$instruction" || rc=$?

        after="$(tree_fingerprint)"
        if [ "$before" != "$after" ]; then
            rm -f "$raw"
            die "Prompt Engineer modified project files (it must be read-only). Inspect with 'git status' / 'git diff'. Aborting before anything is overwritten."
        fi
        if [ "$rc" -ne 0 ]; then
            rm -f "$raw"
            die "Prompt Engineer failed (exit $rc). See ${log#"$ROOT"/}"
        fi

        if [ -s "$DRAFT_PROMPT" ]; then
            candidate="$(sanitize < "$DRAFT_PROMPT" | strip_outer_fence)"
        else
            warn "Draft file not written; falling back to the agent's final message."
            candidate="$(sanitize < "$raw" | from_objective | strip_outer_fence)"
        fi
        rm -f "$raw"

        printf '%s\n' "$candidate" > "$DRAFT_PROMPT"

        missing=""
        if [ -z "${candidate//[[:space:]]/}" ]; then
            missing="(the prompt was empty)"
        else
            missing="$(missing_prompt_sections "$DRAFT_PROMPT")"
        fi

        if [ -z "$missing" ]; then
            archive_file "$LATEST_PROMPT" "$PROMPT_DIR/history"
            mv "$DRAFT_PROMPT" "$LATEST_PROMPT"
            success "Prompt generated: $REL_LATEST_PROMPT"
            return 0
        fi

        warn "Generated prompt is incomplete. Missing: $missing"
        feedback="Your previous prompt was rejected because these required sections were missing or malformed: $missing. Write the COMPLETE prompt again using exactly the required headings (# Objective, # Repository Context, # Current State, # Assumptions, # Requirements, # Constraints, # Non-Goals, # Implementation Guidance, # Validation, # Acceptance Criteria, # Completion Report)."
        attempt=$((attempt + 1))
    done

    die "Prompt Engineer failed to produce a valid prompt. Last draft kept at $REL_DRAFT_PROMPT; log: ${log#"$ROOT"/}"
}

# ------------------------------------------------------------------------------
# Coding Agent
# ------------------------------------------------------------------------------

append_snapshot() {
    {
        printf '\n\n# Repository Snapshot (generated by agent-flow, not by the agent)\n\n'
        printf 'Generated: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        if [ "$IN_GIT" -eq 1 ]; then
            printf '## git status --short\n\n```\n'
            git status --short -uall -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null || true
            # shellcheck disable=SC2016  # backticks are a literal markdown fence
            printf '```\n\n## git diff --stat HEAD\n\n```\n'
            git diff --stat HEAD -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null || true
            printf '```\n'
        else
            printf 'Not a git repository; no snapshot available.\n'
        fi
    } >> "$LATEST_REPORT"
}

report_result() {
    # Print the single result word. Accepts a "Result" heading of any level
    # (optionally bolded, optionally followed by ':') with the value on the next
    # non-empty line, or an inline "Result: VALUE". Only the first word is
    # returned, so "**Result**: BLOCKED because ..." parses as BLOCKED.
    awk '
        function emit(v,   n, w, i) {
            gsub(/^[-*[:space:]]+/, "", v)
            gsub(/[[:space:]]+$/, "", v)
            gsub(/[*`]/, "", v)          # markdown emphasis; keep underscores
            if (v == "") return
            n = split(v, w, /[^A-Za-z_]+/)
            for (i = 1; i <= n; i++) {
                if (w[i] != "") { print w[i]; exit }
            }
        }
        {
            line = $0
            sub(/^[#*[:space:]]+/, "", line)      # heading markers, bullets
            sub(/[[:space:]]+$/, "", line)
            key = tolower(line)
            if (key ~ /^result[*#:]*[[:space:]]*$/) { f = 1; next }
            if (f && NF) { emit(line); next }
            if (key ~ /^result[*#:]+[[:space:]]+[a-z_]+/) {
                v = line
                sub(/^[Rr]esult[*#:]+[[:space:]]+/, "", v)
                emit(v)
                next
            }
        }
    ' "$LATEST_REPORT" 2>/dev/null \
        | tr '[:lower:]' '[:upper:]' \
        | awk 'NF { print $1; exit }' || true
}

execute_prompt() {
    [ -s "$LATEST_PROMPT" ] || die "No prompt found at $REL_LATEST_PROMPT. Run without --implement-only first."

    local dirty log instruction result rc rm_missing

    dirty="$(dirty_file_count)"
    if [ "$dirty" -gt 0 ]; then
        warn "Working tree has $dirty uncommitted path(s). Agent changes will be mixed with them."
        warn "Consider committing or stashing first so the diff stays reviewable."
    fi

    mkdir -p "$LOG_DIR" "$RUNTIME_DIR"
    log="$LOG_DIR/${TS}-coding-agent.log"

    # Archive and remove the old report so a fresh one can be detected reliably.
    archive_file "$LATEST_REPORT" "$REPORT_DIR/history"
    rm -f "$LATEST_REPORT"

    instruction="$(cat <<EOF
Execute the implementation task described in $REL_LATEST_PROMPT (attached to this message; if the attachment is missing, read the file from disk).

Read the prompt completely, inspect the repository, implement, validate, and review your own diff.

You MUST write the completion report to $REL_LATEST_REPORT before finishing, using the report format from your instructions. This is required even if you are blocked or have failed.
Do not commit, push, or discard any existing changes.
EOF
)"

    info "Running Coding Agent..."

    # The message goes BEFORE --file: --file is an option that would otherwise
    # swallow the message as its value.
    rc=0
    run_agent "$RUNTIME_DIR/ca-stdout.$$.tmp" "$log" coding-agent "$CODER_MODEL" \
        "$instruction" --file "$LATEST_PROMPT" || rc=$?

    if [ "$rc" -ne 0 ]; then
        warn "Coding Agent exited with status $rc. Checking for a report..."
    fi

    if [ ! -s "$LATEST_REPORT" ]; then
        error "Coding Agent did not produce $REL_LATEST_REPORT."
        error "It may have been interrupted or failed before reporting. Log: ${log#"$ROOT"/}"
        rm -f "$RUNTIME_DIR/ca-stdout.$$.tmp" 2>/dev/null || true
        return 3
    fi
    rm -f "$RUNTIME_DIR/ca-stdout.$$.tmp" 2>/dev/null || true

    rm_missing="$(missing_report_sections "$LATEST_REPORT")"
    if [ -n "$rm_missing" ]; then
        warn "Report is missing expected sections: $rm_missing"
    fi

    result="$(report_result)"
    case "$result" in
        "$RESULT_COMPLETED"|"$RESULT_PARTIAL"|"$RESULT_BLOCKED"|"$RESULT_FAILED") ;;
        *) result="UNKNOWN" ;;
    esac

    append_snapshot

    printf '\n%s\n' "==================== REPORT ====================" >&2
    cat "$LATEST_REPORT" >&2
    printf '%s\n' "=================================================" >&2

    case "$result" in
        "$RESULT_COMPLETED")
            success "Result: COMPLETED"
            return 0 ;;
        "$RESULT_PARTIAL"|"$RESULT_BLOCKED"|"$RESULT_FAILED")
            warn "Result: $result"
            return 2 ;;
        *)
            warn "Unrecognized or missing result value (expected COMPLETED, PARTIALLY_COMPLETED, BLOCKED or FAILED)."
            return 3 ;;
    esac
}

verify_agents() {
    local rc=0 json_file agent attempt=0 missing
    if ! command_exists "$OPENCODE_BIN"; then
        warn "$OPENCODE_BIN is not in PATH; cannot verify agent definitions."
        return 0
    fi
    check_agent_templates || rc=1

    mkdir -p "$RUNTIME_DIR"
    json_file="$RUNTIME_DIR/agents.json"

    # A cold opencode service can answer before project agents are discovered,
    # and it occasionally truncates its own output, so verify with retries and
    # read from a file instead of a command substitution.
    while : ; do
        "$OPENCODE_BIN" debug agents > "$json_file" 2>/dev/null || true
        missing=""
        for agent in prompt-engineer coding-agent context-builder; do
            if ! grep -Fq "\"$agent\"" "$json_file" 2>/dev/null; then
                missing="${missing:+$missing }$agent"
            fi
        done
        if [ -z "$missing" ]; then
            break
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
            break
        fi
        warn "opencode has not reported [$missing] yet (attempt $attempt); retrying in ${VERIFY_RETRY_WAIT}s..."
        sleep "$VERIFY_RETRY_WAIT"
    done

    for agent in prompt-engineer coding-agent context-builder; do
        if grep -Fq "\"$agent\"" "$json_file" 2>/dev/null; then
            success "Agent loaded by opencode: $agent"
        else
            error "opencode does not know agent '$agent' — check .opencode/agents/$agent.md"
            rc=1
        fi
    done
    rm -f "$json_file"
    return "$rc"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

# Task from file / stdin when not given inline
if [ -n "$TASK_FILE" ]; then
    [ -r "$TASK_FILE" ] || die "Cannot read task file: $TASK_FILE"
    TASK="${TASK:+$TASK

}$(cat "$TASK_FILE")"
elif [ -z "$TASK" ] && [ ! -t 0 ] && { [ "$MODE" = "run" ] || [ "$MODE" = "prompt-only" ]; }; then
    TASK="$(cat)"
fi

# Setup does not need opencode.
if [ "$MODE" = "setup" ]; then
    setup_workflow
    success "Agentic workflow installed."
    cat >&2 <<EOF

Agents:
  ${PROMPT_ENGINEER_FILE#"$ROOT"/}
  ${CODING_AGENT_FILE#"$ROOT"/}
  ${CONTEXT_BUILDER_FILE#"$ROOT"/}

Docs:   .agent/README.md

Workflow files are excluded from git via .git/info/exclude (nothing tracked was modified).
Project context and a dedicated branch are handled automatically on the first run.

Verify the definitions against your opencode build with:
  ./agent-flow.sh --verify-agents

Run:
  ./agent-flow.sh "Your task"
EOF
    exit 0
fi

command_exists "$OPENCODE_BIN" || die "$OPENCODE_BIN is not installed or not in PATH (override with AGENT_FLOW_OPENCODE_BIN)."

if [ "$MODE" = "verify-agents" ]; then
    setup_workflow
    if verify_agents; then
        success "All agent definitions verified."
        exit 0
    fi
    error "Agent verification failed."
    exit 1
fi

if [ "$IN_GIT" -ne 1 ]; then
    warn "Not a git repository: change tracking and safety checks are reduced."
fi
if [ "$NO_BRANCH" -eq 1 ] && [ -n "$BRANCH_NAME" ]; then
    die "--branch and --no-branch are mutually exclusive."
fi

if [ "$MODE" != "implement-only" ] && [ "$MODE" != "context-only" ] && [ -z "$TASK" ]; then
    die "No task supplied. Example: ./agent-flow.sh \"Add authentication\""
fi
if [ "$MODE" = "implement-only" ] && [ -n "$TASK" ]; then
    warn "A task was given together with --implement-only; ignoring the task text."
fi
if [ "$MODE" = "context-only" ] && [ -n "$TASK" ]; then
    warn "A task was given together with --context-only; ignoring the task text."
fi
if [ "$MODE" = "implement-only" ] && [ "$CONTINUE" -eq 1 ]; then
    warn "--continue has no effect with --implement-only."
fi

setup_workflow
acquire_lock
prune_history

EXIT_CODE=0

case "$MODE" in
    context-only)
        REFRESH_CONTEXT=1
        ensure_context
        ensure_explicit_branch
        ;;
    prompt-only)
        ensure_context
        ensure_explicit_branch
        generate_prompt
        printf '\n%s\n' "================ GENERATED PROMPT ================" >&2
        cat "$LATEST_PROMPT" >&2
        printf '%s\n' "====================================================" >&2
        info "Review or edit $REL_LATEST_PROMPT, then run: ./agent-flow.sh --implement-only"
        ;;
    implement-only)
        ensure_context
        ensure_branch "$(prompt_objective)"
        execute_prompt || EXIT_CODE=$?
        ;;
    run)
        ensure_context
        ensure_branch "$TASK"
        generate_prompt
        execute_prompt || EXIT_CODE=$?
        ;;
esac

printf '\n' >&2
if [ "$EXIT_CODE" -eq 0 ]; then
    success "Workflow finished."
else
    warn "Workflow finished with exit code $EXIT_CODE."
fi
FINAL_BRANCH="n/a"
if [ "$IN_GIT" -eq 1 ]; then
    FINAL_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo 'detached HEAD')"
fi
cat >&2 <<EOF

Branch:         $FINAL_BRANCH${BASE_BRANCH:+  (created from $BASE_BRANCH)}
${BRANCH_CREATED:+Created branch:  $BRANCH_CREATED}
Latest prompt:  $REL_LATEST_PROMPT
Latest report:  $REL_LATEST_REPORT
Context:        $REL_CONTEXT
Logs:           .agent/logs/

Review the changes:   git status && git diff
Continue:             ./agent-flow.sh --continue "What should happen next?"
${MERGE_HINT:+Merge when happy:    $MERGE_HINT}
EOF

exit "$EXIT_CODE"