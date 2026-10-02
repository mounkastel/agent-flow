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

# How this invocation should be typed back at the user, so hints stay correct
# whether it was run as ./agent-flow.sh, agent-flow, or an absolute path.
SELF_NAME="${0##*/}"

TEMPLATE_VERSION="v5"
TEMPLATE_MARKER="agent-flow-template: ${TEMPLATE_VERSION}"

if [ -t 2 ]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
    C_DIM=""; C_BOLD=""
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
  agent-flow.sh --models                       Pick the models interactively, then exit
  agent-flow.sh --status                       What happened last, and where things stand
  agent-flow.sh --doctor                       Check the environment, report what is broken
  agent-flow.sh --history                      List past runs, newest first
  agent-flow.sh --show [N]                     Show run N (default 1 = the newest)
  agent-flow.sh --undo                         Remove the agent branch and its uncommitted work
  echo "task" | agent-flow.sh                  Read the task from stdin

Options:
  --branch NAME          Use/create this branch instead of agent/<slug>-<time>
  --no-branch            Do not create a branch; work on the current one
  --refresh-context      Rebuild .agent/context/PROJECT.md before running
  --keep N               Keep the newest N history/log files (0 = keep all)
  --timeout SEC          Hard limit per agent call (default 3600, 0 = no limit)
  --lock-wait SEC        Wait up to SEC for a concurrent run to release its lock
  --no-auto              Do not pass --auto to `opencode run` (stricter, may stall)
  --pe-model MODEL       Model for Prompt Engineer (provider/model)
  --coder-model MODEL    Model for Coding Agent    (provider/model)
  --context-model MODEL  Model for Context Builder (defaults to the PE model)
  --models               Interactively pick the models and save them for this repo
  --undo                 Return to the base branch and delete the agent branch
  --yes, -y              With --undo: skip the confirmation before discarding work
  --force                With --setup: overwrite existing agent definitions
  -h, --help             Show this help

Environment:
  AGENT_FLOW_PE_MODEL       Model for Prompt Engineer
  AGENT_FLOW_CODER_MODEL    Model for Coding Agent
  AGENT_FLOW_CONTEXT_MODEL  Model for Context Builder
  AGENT_FLOW_MODELS_TTL     Seconds to reuse the cached model list (default 86400)
  AGENT_FLOW_MODELS_REFRESH Set to 1 to re-list models and re-check the remembered
                            choice before a run (e.g. after changing account)
  AGENT_FLOW_CONTEXT_MAX_DAYS  Days after which the project context counts as
                            stale and is called out (default 30)
  AGENT_FLOW_TIMEOUT     Override the per-agent-call timeout (0 = no limit)
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
  * Project context (.agent/context/PROJECT.md) is built on first run, and is
    called out as stale once it falls too far behind HEAD or gets too old.
  * Each agent call is capped at --timeout seconds (default 3600) so a wedged
    agent cannot hang the run forever.
  * On the first run in a repository you are offered a one-time model picker;
    the choice is remembered in .agent/models.conf and every later run just
    prints which models it is using. Re-pick any time with --models.
  * An empty model means "no --model flag", i.e. the opencode default is used.
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
TIMEOUT="${AGENT_FLOW_TIMEOUT:-3600}"
LOCK_WAIT="${AGENT_FLOW_LOCK_WAIT:-0}"
VERIFY_RETRY_WAIT="${AGENT_FLOW_VERIFY_WAIT:-2}"
AUTO="1"
if [ "${AGENT_FLOW_AUTO:-1}" = "0" ]; then
    AUTO="0"
fi
PE_MODEL="${AGENT_FLOW_PE_MODEL:-}"
CODER_MODEL="${AGENT_FLOW_CODER_MODEL:-}"
CONTEXT_MODEL="${AGENT_FLOW_CONTEXT_MODEL:-}"
PE_MODEL_FLAGGED=0
CODER_MODEL_FLAGGED=0
CONTEXT_MODEL_FLAGGED=0
CHOOSE_MODELS=0
SHOW_RUN="1"
ASSUME_YES=0
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
            PE_MODEL="$2"; PE_MODEL_FLAGGED=1; shift ;;
        --coder-model)
            need_value "$1" "$#"
            CODER_MODEL="$2"; CODER_MODEL_FLAGGED=1; shift ;;
        --context-model)
            need_value "$1" "$#"
            CONTEXT_MODEL="$2"; CONTEXT_MODEL_FLAGGED=1; shift ;;
        --models|--choose-models) CHOOSE_MODELS=1 ;;
        --status)          MODE="status" ;;
        --doctor)          MODE="doctor" ;;
        --history)         MODE="history" ;;
        --show)
            MODE="show"
            case "${2:-}" in
                ''|-*) SHOW_RUN=1 ;;
                *)     SHOW_RUN="$2"; shift ;;
            esac ;;
        --undo)            MODE="undo" ;;
        --yes|-y)          ASSUME_YES=1 ;;
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
    "Assumptions"        # mandated by the Prompt Engineer template and by the
    "Requirements"       # retry feedback; the validator must agree with both
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
  # Read-only shell. An agent that cannot run `git log` or `ls` does not stop:
  # it works around it by reading .git/HEAD, .git/config and .git/logs/HEAD as
  # files and globbing .git/refs/*, which costs many times more calls for
  # strictly less information, and still misses what it needed.
  - action: "bash"
    resource: "git *"
    effect: allow
  - action: "bash"
    resource: "ls*"
    effect: allow
  - action: "bash"
    resource: "find*"
    effect: allow
  - action: "bash"
    resource: "cat*"
    effect: allow
  - action: "bash"
    resource: "head*"
    effect: allow
  - action: "bash"
    resource: "tail*"
    effect: allow
  - action: "bash"
    resource: "wc*"
    effect: allow
  - action: "bash"
    resource: "stat*"
    effect: allow
  - action: "bash"
    resource: "file*"
    effect: allow
  - action: "bash"
    resource: "du*"
    effect: allow
  - action: "bash"
    resource: "tree*"
    effect: allow
  - action: "bash"
    resource: "diff*"
    effect: allow
  - action: "bash"
    resource: "grep*"
    effect: allow
  - action: "bash"
    resource: "rg*"
    effect: allow
  - action: "bash"
    resource: "fd*"
    effect: allow
  - action: "bash"
    resource: "jq*"
    effect: allow
  - action: "bash"
    resource: "sed*"
    effect: allow
  - action: "bash"
    resource: "sort*"
    effect: allow
  - action: "bash"
    resource: "uniq*"
    effect: allow
  - action: "bash"
    resource: "cut*"
    effect: allow
  - action: "bash"
    resource: "tr*"
    effect: allow
  - action: "bash"
    resource: "pwd*"
    effect: allow
  - action: "bash"
    resource: "which*"
    effect: allow
  - action: "bash"
    resource: "echo*"
    effect: allow
  - action: "bash"
    resource: "uname*"
    effect: allow
  - action: "bash"
    resource: "uptime*"
    effect: allow
  - action: "bash"
    resource: "date*"
    effect: allow
  - action: "bash"
    resource: "id*"
    effect: allow
  - action: "bash"
    resource: "df*"
    effect: allow
  - action: "bash"
    resource: "free*"
    effect: allow
  - action: "bash"
    resource: "ps*"
    effect: allow
  # Checks are allowed because a briefing that says "run the tests" without ever
  # running them is a guess.
  - action: "bash"
    resource: "bash -n*"
    effect: allow
  - action: "bash"
    resource: "shellcheck*"
    effect: allow
  - action: "bash"
    resource: "make*"
    effect: allow
  - action: "bash"
    resource: "cargo test*"
    effect: allow
  - action: "bash"
    resource: "cargo build*"
    effect: allow
  - action: "bash"
    resource: "cargo check*"
    effect: allow
  - action: "bash"
    resource: "npm test*"
    effect: allow
  - action: "bash"
    resource: "npm run*"
    effect: allow
  - action: "bash"
    resource: "pytest*"
    effect: allow
  # git is readable above but never mutating: the earlier `git *` rule allowed
  # everything, so every writing subcommand is taken back here.
  - action: "bash"
    resource: "git commit*"
    effect: deny
  - action: "bash"
    resource: "git push*"
    effect: deny
  - action: "bash"
    resource: "git reset*"
    effect: deny
  - action: "bash"
    resource: "git checkout*"
    effect: deny
  - action: "bash"
    resource: "git switch*"
    effect: deny
  - action: "bash"
    resource: "git clean*"
    effect: deny
  - action: "bash"
    resource: "git stash*"
    effect: deny
  - action: "bash"
    resource: "git rebase*"
    effect: deny
  - action: "bash"
    resource: "git merge*"
    effect: deny
  - action: "bash"
    resource: "git revert*"
    effect: deny
  - action: "bash"
    resource: "git add*"
    effect: deny
  # Mutations, privilege and anything reaching off the machine are denied again:
  # this agent has no business performing them.
  - action: "bash"
    resource: "rm*"
    effect: deny
  - action: "bash"
    resource: "mv*"
    effect: deny
  - action: "bash"
    resource: "cp*"
    effect: deny
  - action: "bash"
    resource: "chmod*"
    effect: deny
  - action: "bash"
    resource: "chown*"
    effect: deny
  - action: "bash"
    resource: "mkdir*"
    effect: deny
  - action: "bash"
    resource: "touch*"
    effect: deny
  - action: "bash"
    resource: "dd*"
    effect: deny
  - action: "bash"
    resource: "mkfs*"
    effect: deny
  - action: "bash"
    resource: "curl*"
    effect: deny
  - action: "bash"
    resource: "wget*"
    effect: deny
  - action: "bash"
    resource: "ssh*"
    effect: deny
  - action: "bash"
    resource: "sudo*"
    effect: deny
  - action: "bash"
    resource: "su*"
    effect: deny
  - action: "bash"
    resource: "systemctl*"
    effect: deny
  - action: "bash"
    resource: "kill*"
    effect: deny
  - action: "bash"
    resource: "pkill*"
    effect: deny
  - action: "bash"
    resource: "npm install*"
    effect: deny
  - action: "bash"
    resource: "pip install*"
    effect: deny
  - action: "bash"
    resource: "cargo install*"
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
no dependency changes, no patches, no "quick fixes", no running installers or
anything that writes files.

The only file you may write is `.agent/prompts/draft.md` — that is where your
final prompt goes. Your shell is read-only: `git status`, `git log`, `git diff`,
`git show`, `ls`, `find`, `cat`, `wc`, `grep` and friends are available, and you
SHOULD use them rather than reconstructing git state by reading `.git/HEAD` and
`.git/config` as text — that is slow and lossy. Writing git commands (`git
commit`, `git push`, `git reset`, `git add`) are denied, as are `rm`, `mv`,
`chmod`, `curl` and `sudo`. You may run non-mutating checks (`bash -n`,
`shellcheck`, `cargo check`) when a claim in your prompt depends on them; do not
run long test suites or installs. File contents are best read with your read and
grep tools, which are additionally blocked for `.env` files.

`.agent/` is this workflow's own bookkeeping, not part of the project. Only
`.agent/context/PROJECT.md` is input for you; do not map the rest of the
directory and do not go looking for files that it mentions — those belong to the
tool, not to this repository.

If a command you want is denied, do not look for a workaround: record the need
under "Constraints" in the prompt so the Coding Agent knows.

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
  #
  # NOTE: these were written against `action: "shell"`, which is not an action
  # in OpenCode V2 -- the tool is called `bash`. Every one of them was silently
  # inert, so the Coding Agent could in fact commit, push, `sudo` and
  # `curl | sh`, and only the prose instruction stopped it. Do not reintroduce
  # `shell` here.
  - action: "bash"
    resource: "*"
    effect: allow
  - action: "bash"
    resource: "git commit"
    effect: deny
  - action: "bash"
    resource: "git commit *"
    effect: deny
  - action: "bash"
    resource: "git push"
    effect: deny
  - action: "bash"
    resource: "git push *"
    effect: deny
  - action: "bash"
    resource: "git merge"
    effect: deny
  - action: "bash"
    resource: "git merge *"
    effect: deny
  - action: "bash"
    resource: "git rebase"
    effect: deny
  - action: "bash"
    resource: "git rebase *"
    effect: deny
  - action: "bash"
    resource: "git cherry-pick *"
    effect: deny
  - action: "bash"
    resource: "git revert *"
    effect: deny
  - action: "bash"
    resource: "git reset"
    effect: deny
  - action: "bash"
    resource: "git reset *"
    effect: deny
  - action: "bash"
    resource: "git clean"
    effect: deny
  - action: "bash"
    resource: "git clean *"
    effect: deny
  - action: "bash"
    resource: "git stash"
    effect: deny
  - action: "bash"
    resource: "git stash *"
    effect: deny
  - action: "bash"
    resource: "git checkout"
    effect: deny
  - action: "bash"
    resource: "git checkout *"
    effect: deny
  - action: "bash"
    resource: "git switch"
    effect: deny
  - action: "bash"
    resource: "git switch *"
    effect: deny
  - action: "bash"
    resource: "git restore"
    effect: deny
  - action: "bash"
    resource: "git restore *"
    effect: deny
  - action: "bash"
    resource: "git reflog *"
    effect: deny
  - action: "bash"
    resource: "git update-ref *"
    effect: deny
  - action: "bash"
    resource: "git symbolic-ref *"
    effect: deny
  - action: "bash"
    resource: "git replace"
    effect: deny
  - action: "bash"
    resource: "git replace *"
    effect: deny
  - action: "bash"
    resource: "git filter-branch *"
    effect: deny
  - action: "bash"
    resource: "git filter-repo *"
    effect: deny
  - action: "bash"
    resource: "git rebase --abort"
    effect: deny
  - action: "bash"
    resource: "git remote"
    effect: deny
  - action: "bash"
    resource: "git remote *"
    effect: deny
  - action: "bash"
    resource: "git config"
    effect: deny
  - action: "bash"
    resource: "git config *"
    effect: deny
  - action: "bash"
    resource: "git rm *"
    effect: deny
  - action: "bash"
    resource: "git mv *"
    effect: deny
  - action: "bash"
    resource: "git apply *"
    effect: deny
  - action: "bash"
    resource: "git am *"
    effect: deny
  - action: "bash"
    resource: "git format-patch *"
    effect: deny
  - action: "bash"
    resource: "git bundle *"
    effect: deny
  - action: "bash"
    resource: "git gc *"
    effect: deny
  - action: "bash"
    resource: "git prune *"
    effect: deny
  - action: "bash"
    resource: "git repack *"
    effect: deny
  - action: "bash"
    resource: "git worktree *"
    effect: deny
  - action: "bash"
    resource: "git bisect"
    effect: deny
  - action: "bash"
    resource: "git bisect *"
    effect: deny
  - action: "bash"
    resource: "git submodule *"
    effect: deny
  - action: "bash"
    resource: "git notes *"
    effect: deny
  - action: "bash"
    resource: "git send-email *"
    effect: deny
  - action: "bash"
    resource: "git request-pull *"
    effect: deny
  - action: "bash"
    resource: "git p4 *"
    effect: deny
  - action: "bash"
    resource: "git svn *"
    effect: deny
  - action: "bash"
    resource: "git mergetool *"
    effect: deny
  - action: "bash"
    resource: "git difftool *"
    effect: deny
  - action: "bash"
    resource: "git gui"
    effect: deny
  - action: "bash"
    resource: "git daemon *"
    effect: deny
  - action: "bash"
    resource: "sudo"
    effect: deny
  - action: "bash"
    resource: "sudo *"
    effect: deny
  - action: "bash"
    resource: "sudoedit *"
    effect: deny
  - action: "bash"
    resource: "doas *"
    effect: deny
  - action: "bash"
    resource: "su *"
    effect: deny
  - action: "bash"
    resource: "chmod *"
    effect: deny
  - action: "bash"
    resource: "chown *"
    effect: deny
  - action: "bash"
    resource: "chgrp *"
    effect: deny
  - action: "bash"
    resource: "systemctl *"
    effect: deny
  - action: "bash"
    resource: "launchctl *"
    effect: deny
  - action: "bash"
    resource: "crontab"
    effect: deny
  - action: "bash"
    resource: "crontab *"
    effect: deny
  - action: "bash"
    resource: "shutdown *"
    effect: deny
  - action: "bash"
    resource: "reboot *"
    effect: deny
  - action: "bash"
    resource: "poweroff *"
    effect: deny
  - action: "bash"
    resource: "halt *"
    effect: deny
  - action: "bash"
    resource: "killall *"
    effect: deny
  - action: "bash"
    resource: "dd *"
    effect: deny
  - action: "bash"
    resource: "mkfs *"
    effect: deny
  - action: "bash"
    resource: "rm -rf /"
    effect: deny
  - action: "bash"
    resource: "rm -fr /"
    effect: deny
  - action: "bash"
    resource: "rm -rf /*"
    effect: deny
  - action: "bash"
    resource: "rm -fr /*"
    effect: deny
  - action: "bash"
    resource: "rm -rf ~"
    effect: deny
  - action: "bash"
    resource: "rm -rf ~/*"
    effect: deny
  - action: "bash"
    resource: "rm -rf $HOME*"
    effect: deny
  - action: "bash"
    resource: "rm -rf .git*"
    effect: deny
  - action: "bash"
    resource: "rm -rf .agent*"
    effect: deny
  - action: "bash"
    resource: "npm publish *"
    effect: deny
  - action: "bash"
    resource: "yarn publish *"
    effect: deny
  - action: "bash"
    resource: "pnpm publish *"
    effect: deny
  - action: "bash"
    resource: "cargo publish *"
    effect: deny
  - action: "bash"
    resource: "twine upload *"
    effect: deny
  - action: "bash"
    resource: "npm login *"
    effect: deny
  - action: "bash"
    resource: "pip install --user *"
    effect: deny
  - action: "bash"
    resource: "pipx install *"
    effect: deny
  - action: "bash"
    resource: "gem install *"
    effect: deny
  - action: "bash"
    resource: "npm install -g *"
    effect: deny
  - action: "bash"
    resource: "yarn global add *"
    effect: deny
  - action: "bash"
    resource: "pnpm add -g *"
    effect: deny
  - action: "bash"
    resource: "curl *| sh"
    effect: deny
  - action: "bash"
    resource: "curl *| bash"
    effect: deny
  - action: "bash"
    resource: "wget *| sh"
    effect: deny
  - action: "bash"
    resource: "wget *| bash"
    effect: deny
  - action: "bash"
    resource: "* .agent/prompts/*"
    effect: deny
  - action: "bash"
    resource: "*> .agent/prompts/*"
    effect: deny
  - action: "bash"
    resource: "history -c *"
    effect: deny
  - action: "bash"
    resource: "history -c"
    effect: deny  # Publishing and global installs.
  # Piping remote code into a shell.
  # Never touch the prompt that defines this task, never drop shell history.
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
  # Read-only shell. An agent that cannot run `git log` or `ls` does not stop:
  # it works around it by reading .git/HEAD, .git/config and .git/logs/HEAD as
  # files and globbing .git/refs/*, which costs many times more calls for
  # strictly less information, and still misses what it needed.
  - action: "bash"
    resource: "git *"
    effect: allow
  - action: "bash"
    resource: "ls*"
    effect: allow
  - action: "bash"
    resource: "find*"
    effect: allow
  - action: "bash"
    resource: "cat*"
    effect: allow
  - action: "bash"
    resource: "head*"
    effect: allow
  - action: "bash"
    resource: "tail*"
    effect: allow
  - action: "bash"
    resource: "wc*"
    effect: allow
  - action: "bash"
    resource: "stat*"
    effect: allow
  - action: "bash"
    resource: "file*"
    effect: allow
  - action: "bash"
    resource: "du*"
    effect: allow
  - action: "bash"
    resource: "tree*"
    effect: allow
  - action: "bash"
    resource: "diff*"
    effect: allow
  - action: "bash"
    resource: "grep*"
    effect: allow
  - action: "bash"
    resource: "rg*"
    effect: allow
  - action: "bash"
    resource: "fd*"
    effect: allow
  - action: "bash"
    resource: "jq*"
    effect: allow
  - action: "bash"
    resource: "sed*"
    effect: allow
  - action: "bash"
    resource: "sort*"
    effect: allow
  - action: "bash"
    resource: "uniq*"
    effect: allow
  - action: "bash"
    resource: "cut*"
    effect: allow
  - action: "bash"
    resource: "tr*"
    effect: allow
  - action: "bash"
    resource: "pwd*"
    effect: allow
  - action: "bash"
    resource: "which*"
    effect: allow
  - action: "bash"
    resource: "echo*"
    effect: allow
  - action: "bash"
    resource: "uname*"
    effect: allow
  - action: "bash"
    resource: "uptime*"
    effect: allow
  - action: "bash"
    resource: "date*"
    effect: allow
  - action: "bash"
    resource: "id*"
    effect: allow
  - action: "bash"
    resource: "df*"
    effect: allow
  - action: "bash"
    resource: "free*"
    effect: allow
  - action: "bash"
    resource: "ps*"
    effect: allow
  # Checks are allowed because a briefing that says "run the tests" without ever
  # running them is a guess.
  - action: "bash"
    resource: "bash -n*"
    effect: allow
  - action: "bash"
    resource: "shellcheck*"
    effect: allow
  - action: "bash"
    resource: "make*"
    effect: allow
  - action: "bash"
    resource: "cargo test*"
    effect: allow
  - action: "bash"
    resource: "cargo build*"
    effect: allow
  - action: "bash"
    resource: "cargo check*"
    effect: allow
  - action: "bash"
    resource: "npm test*"
    effect: allow
  - action: "bash"
    resource: "npm run*"
    effect: allow
  - action: "bash"
    resource: "pytest*"
    effect: allow
  # git is readable above but never mutating: the earlier `git *` rule allowed
  # everything, so every writing subcommand is taken back here.
  - action: "bash"
    resource: "git commit*"
    effect: deny
  - action: "bash"
    resource: "git push*"
    effect: deny
  - action: "bash"
    resource: "git reset*"
    effect: deny
  - action: "bash"
    resource: "git checkout*"
    effect: deny
  - action: "bash"
    resource: "git switch*"
    effect: deny
  - action: "bash"
    resource: "git clean*"
    effect: deny
  - action: "bash"
    resource: "git stash*"
    effect: deny
  - action: "bash"
    resource: "git rebase*"
    effect: deny
  - action: "bash"
    resource: "git merge*"
    effect: deny
  - action: "bash"
    resource: "git revert*"
    effect: deny
  - action: "bash"
    resource: "git add*"
    effect: deny
  # Mutations, privilege and anything reaching off the machine are denied again:
  # this agent has no business performing them.
  - action: "bash"
    resource: "rm*"
    effect: deny
  - action: "bash"
    resource: "mv*"
    effect: deny
  - action: "bash"
    resource: "cp*"
    effect: deny
  - action: "bash"
    resource: "chmod*"
    effect: deny
  - action: "bash"
    resource: "chown*"
    effect: deny
  - action: "bash"
    resource: "mkdir*"
    effect: deny
  - action: "bash"
    resource: "touch*"
    effect: deny
  - action: "bash"
    resource: "dd*"
    effect: deny
  - action: "bash"
    resource: "mkfs*"
    effect: deny
  - action: "bash"
    resource: "curl*"
    effect: deny
  - action: "bash"
    resource: "wget*"
    effect: deny
  - action: "bash"
    resource: "ssh*"
    effect: deny
  - action: "bash"
    resource: "sudo*"
    effect: deny
  - action: "bash"
    resource: "su*"
    effect: deny
  - action: "bash"
    resource: "systemctl*"
    effect: deny
  - action: "bash"
    resource: "kill*"
    effect: deny
  - action: "bash"
    resource: "pkill*"
    effect: deny
  - action: "bash"
    resource: "npm install*"
    effect: deny
  - action: "bash"
    resource: "pip install*"
    effect: deny
  - action: "bash"
    resource: "cargo install*"
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
---

# Context Builder

You produce the **project briefing** that every other agent in this workflow
reads before touching the repository. A good briefing saves them from
rediscovering the project on every task, and prevents wrong assumptions about
commands, structure and conventions.

## Boundaries

- You may write exactly one file: `.agent/context/PROJECT.draft.md`.
- Your shell is read-only. `git status`, `git log`, `git diff`, `ls`, `find`,
  `cat`, `wc`, `grep` and friends are available and you SHOULD use them:
  reconstructing git state by reading `.git/HEAD` and `.git/config` as text is
  slow, lossy and unreliable. Writing git commands (`git commit`, `git push`,
  `git reset`, `git add`) are denied, as are `rm`, `mv`, `chmod`, `curl` and
  `sudo`. File contents are better read with your read and grep tools, which
  additionally block `.env` files.
- You may run syntax and validation checks that do not change the repository
  (`bash -n`, `shellcheck`, `jq empty`, a config validator, `cargo check`).
  Do NOT run installers, `npm install`, builds that rewrite lockfiles, or any
  long test suite — validating the code is the Coding Agent's job, and your
  briefing only needs to state the exact commands.
- `.agent/` is this workflow's own bookkeeping, not part of the project. Do not
  describe it, do not map it, and do not go looking for the files it mentions
  (they belong to the tool, not to this repository).
- If a command you want is denied, do not look for a workaround. Note it in
  the "Pitfalls" section instead.
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
# Agent workflow (bookkeeping, not your project)

> This file documents the `agent-flow` tool. It says nothing about the
> repository you happen to be in. Nothing it mentions -- the runner, its tests,
> its scripts -- is expected to exist here. Agents must not read it as a
> description of the project, and must not go looking for those paths.

Two OpenCode agents cooperate through files in this directory.

| Agent             | Access                            | Produces                      |
|-------------------|-----------------------------------|-------------------------------|
| `prompt-engineer` | read-only shell, writes the draft | `.agent/prompts/latest.md`    |
| `coding-agent`    | read/write, no commit/push        | `.agent/reports/latest.md`    |
| `context-builder` | read-only shell, writes the draft | `.agent/context/PROJECT.md`   |

Agent definitions live in `.opencode/agents/`. Edit them freely: the runner
never overwrites them unless you run the setup with `--force`.

## Layout

    .agent/prompts/latest.md      current execution prompt
    .agent/prompts/history/       archived prompts
    .agent/reports/latest.md      current completion report
    .agent/reports/history/       archived reports
    .agent/context/PROJECT.md     project briefing every agent reads first
    .agent/runs/                  one small record per run (what/when/branch)
    .agent/logs/                  raw agent output per run
    .agent/runtime/               lock, model cache, temp files

Only `PROJECT.md` is project documentation. Everything else here is the tool's
own state.

## Git isolation

Nothing in this workflow is tracked by git. The runner adds `.agent/` and the
generated agent files to `.git/info/exclude` (local to this clone; no tracked
file such as `.gitignore` is modified).

## Branches

Each run happens on its own branch `agent/<task-slug>-<timestamp>` created from
the current HEAD. If you already are on an `agent/*` branch it is reused, so
`--continue` stays on the same branch. Use `--branch NAME` or `--no-branch` to
override. `agent-flow --undo` removes the branch together with its uncommitted
work, but refuses to delete commits that exist only on it.

## Project context

`.agent/context/PROJECT.md` is built automatically on the first run and is
rebuildable on demand (`--refresh-context`). It is called out as stale once it
falls far behind HEAD or gets old.

## Rules

- The repository is the source of truth. Prompts and reports are history.
- The Coding Agent does not commit. Review `git diff`, then commit yourself.
- Reports include a "Repository Snapshot" appended by the runner from real
  `git` output, independent of what the agent claims.
- Concurrency: one run per repository (lock in `.agent/runtime/lock`). A stale
  lock left behind by a killed process is detected and reclaimed automatically.
- The read-only agents get a read-only shell: `git log`, `ls`, `grep`, `make`
  and syntax checks are available, `git commit`, `rm`, `chmod`, `curl` and
  `sudo` are not.

## Agent permissions

The generated agent files use the OpenCode V2 `permissions:` schema (ordered
rules, last match wins). `agent-flow --verify-agents` asks opencode which agent
definitions it actually loaded, and `--doctor` reports a stale or hand-mangled
file, so the rules above are checkable rather than assumed.
EOF
}

# ------------------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------------------

stamp_template() {
    # The marker sits inside a quoted heredoc, where it cannot be expanded, so
    # it used to be a literal. That meant TEMPLATE_VERSION was never reflected in
    # the files that got installed: bumping it changed only the comparison, so
    # every install looked outdated forever and `--setup --force` could never
    # clear the warning.
    local path="$1" tmp
    [ -f "$path" ] || return 0
    tmp="$path.stamp.$$"
    if sed "s|agent-flow-template: v[0-9][0-9]*|${TEMPLATE_MARKER}|" "$path" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
    return 0
}

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
    stamp_template "$path"
    info "Installed $label: ${path#"$ROOT"/}"
}

# Cheap static sanity check of our own templates. A legacy V1 `permission:` block
# is silently ignored by OpenCode V2, which would leave the agents unrestricted.
check_agent_templates() {
    local f label missing=0 noshell=0
    for f in "$PROMPT_ENGINEER_FILE" "$CODING_AGENT_FILE" "$CONTEXT_BUILDER_FILE"; do
        label="${f##*/}"
        label="${label%.md}"
        [ -f "$f" ] || continue
        if grep -Eq '^permission:' "$f"; then
            error "$label uses the legacy V1 'permission:' block; OpenCode V2 ignores it, and the agent then runs with permissive defaults. Fix with --setup --force."
            missing=1
        fi
        if ! grep -Eq '^permissions:' "$f"; then
            warn "$label has no 'permissions:' block: the agent runs with OpenCode defaults."
            missing=1
        fi
    done
    # The two research agents start from `action: "*" -> deny`. If nothing ever
    # allows `bash`, they cannot run `git log` or `ls`, and they do not fail --
    # they quietly rebuild git state by reading .git/HEAD as text, which costs
    # many times more calls for less information. Running anyway just burns
    # tokens on a result we already know will be poor.
    for f in "$PROMPT_ENGINEER_FILE" "$CONTEXT_BUILDER_FILE"; do
        [ -f "$f" ] || continue
        if ! agent_allows_shell "$f"; then
            noshell=1
            error "${f##*/} allows no shell command: it cannot run git log, ls or grep, and will reconstruct repository state by reading files such as .git/HEAD."
        fi
    done
    if [ "$noshell" -eq 1 ]; then
        printf '\n'
        error "This run would waste tokens: the agents above cannot inspect the repository."
        printf '  Refresh the agent definitions once:\n\n'
        printf '      %s --setup --force\n\n' "$SELF_NAME"
        printf '  They are installed per repository, so an older copy in another\n'
        printf '  checkout needs the same command.\n'
        return 1
    fi
    return "$missing"
}

agent_allows_shell() { # agent_allows_shell FILE -> 0 if any bash rule allows
    awk '
        /^permissions:/ { inblock = 1; next }
        inblock && /^---[[:space:]]*$/ { exit }
        inblock && /action:[[:space:]]*"?bash"?/ { inbash = 1; next }
        inblock && /action:/ { inbash = 0 }
        inblock && inbash && /effect:[[:space:]]*"?allow"?/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$1" 2>/dev/null
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

prune_dir() {
    # prune_dir DIR LABEL -- newest $KEEP files survive. History filenames start
    # with a fixed-width timestamp, so LC_ALL=C sort order is chronological
    # (byte-stable on both GNU and BSD).
    local dir="$1" label="$2" excess n i base
    local -a files=() batch=()
    [ "$KEEP" -gt 0 ] || return 0
    [ -d "$dir" ] || return 0

    # One find + one sed + one sort for the whole decision. The old form ran find
    # twice (history_count, then the listing) and pushed the deletion loop into a
    # pipeline subshell. The .md suffix is stripped before sorting, otherwise a
    # collision-suffixed archive (TS-2.md) sorts BEFORE the base archive (TS.md)
    # of the same second ('-' < '.') and "newest KEEP survive" would drop the
    # newer file.
    while IFS= read -r base; do
        [ -n "$base" ] && files+=("$base")
    done <<< "$(find "$dir" -maxdepth 1 -type f ! -name '.*' 2>/dev/null \
        | sed -E 's/\.md$//' \
        | LC_ALL=C sort || true)"

    n="${#files[@]}"
    excess=$((n - KEEP))
    [ "$excess" -gt 0 ] || return 0

    # Batch the deletions: one `rm` per 200 paths instead of one fork per file.
    # Pruning a few hundred history files went from ~800 ms to ~5 ms.
    for ((i = 0; i < excess; i++)); do
        batch+=("${files[i]}.md")
        info "Pruned old $label: ${files[i]##*/}.md"
        if [ "${#batch[@]}" -ge 200 ]; then
            rm -f "${batch[@]}" 2>/dev/null || true
            batch=()
        fi
    done
    if [ "${#batch[@]}" -gt 0 ]; then
        rm -f "${batch[@]}" 2>/dev/null || true
    fi
    return 0
}

prune_history() {
    [ "$KEEP" -gt 0 ] || return 0
    prune_dir "$PROMPT_DIR/history" "prompt"
    prune_dir "$REPORT_DIR/history" "report"
    prune_dir "$LOG_DIR" "log"
    return 0
}

# ------------------------------------------------------------------------------
# Model selection
# ------------------------------------------------------------------------------
#
# The candidate list comes from `opencode models`, i.e. exactly the models this
# account can currently reach -- no hardcoded catalogue that goes stale. That
# call queries the opencode server and costs ~0.4s, so the listing is cached
# under .agent/runtime and only refreshed when it is actually needed.
#
# Choices are remembered per repository in .agent/models.conf (which never
# reaches git) instead of being asked for on every run: the first run in a
# repository offers the picker once, every later run just states which models it
# is about to use and mentions --models. Re-asking each time would mean scrolling
# a few hundred lines per run, and would break any non-interactive use.
#
# An empty value means "do not pass --model at all", i.e. let opencode apply its
# own configured default. That is a legitimate choice and the picker offers it
# explicitly rather than silently falling back to it.

MODELS_CONF="$WORKFLOW_DIR/models.conf"
MODELS_CACHE="$RUNTIME_DIR/models.list"
MODELS_CACHE_TS="$RUNTIME_DIR/models.list.ts"
MODELS_TTL="${AGENT_FLOW_MODELS_TTL:-86400}"
# A run deliberately does not pay for a fresh listing, because the models are
# remembered; set this after changing accounts or adding a provider.
MODELS_FORCE_REFRESH=0
[ "${AGENT_FLOW_MODELS_REFRESH:-0}" = "1" ] && MODELS_FORCE_REFRESH=1

SAVED_PE_MODEL=""
SAVED_CODER_MODEL=""
SAVED_CONTEXT_MODEL=""
PICK_RESULT=""

is_interactive() {
    # A picker must never be able to hang a script, a cron job or CI.
    [ -t 0 ] && [ -t 1 ]
}

PROMPT_REPLY=""
PICK_EOF=0
ask() { # ask TEXT PROMPT -> PROMPT_REPLY; returns 1 on EOF (Ctrl-D, closed stdin)
    PROMPT_REPLY=""
    printf '%s' "$2"
    IFS= read -r PROMPT_REPLY || return 1
    return 0
}

set_saved_model() { # KEY VALUE
    case "$1" in
        PE_MODEL)      SAVED_PE_MODEL="$2" ;;
        CODER_MODEL)   SAVED_CODER_MODEL="$2" ;;
        CONTEXT_MODEL) SAVED_CONTEXT_MODEL="$2" ;;
    esac
}

load_models_conf() {
    # Parsed line by line rather than sourced: a hand-edited or corrupt file must
    # not be able to turn into executable code.
    SAVED_PE_MODEL=""
    SAVED_CODER_MODEL=""
    SAVED_CONTEXT_MODEL=""
    [ -f "$MODELS_CONF" ] || return 1
    local line key value found=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            PE_MODEL|CODER_MODEL|CONTEXT_MODEL) found=1 ;;
            *) continue ;;
        esac
        value="${value%%#*}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        set_saved_model "$key" "$value"
    done < "$MODELS_CONF"
    [ "$found" -eq 1 ]
}

save_models_conf() {
    {
        printf '# Models chosen for this repository by agent-flow.\n'
        printf '# Edit freely, or re-run: agent-flow.sh --models\n'
        printf '# An empty value means: do not pass --model, use the opencode default.\n'
        printf 'PE_MODEL=%s\n'      "$SAVED_PE_MODEL"
        printf 'CODER_MODEL=%s\n'   "$SAVED_CODER_MODEL"
        printf 'CONTEXT_MODEL=%s\n' "$SAVED_CONTEXT_MODEL"
    } > "$MODELS_CONF" 2>/dev/null \
        || die "Cannot write ${MODELS_CONF#"$ROOT"/} (check permissions)."
}

refresh_models_cache() {
    local raw attempt
    raw="$RUNTIME_DIR/models.raw.$$"
    # The listing is answered by opencode's background service. Just after it
    # has been started or restarted the service accepts the request but cannot
    # answer it yet, and the command then *succeeds while reporting no models at
    # all*. An empty result therefore means "not ready yet", not "no models",
    # and is retried a few times before being called a failure.
    for attempt in 1 2 3 4; do
        if ! "$OPENCODE_BIN" models > "$raw" 2>/dev/null; then
            rm -f "$raw" 2>/dev/null || true
            return 1
        fi
        # Keep only well-formed provider/model lines and drop duplicates.
        grep -E '^[^[:space:]/]+/[^[:space:]]+$' "$raw" 2>/dev/null \
            | LC_ALL=C sort -u > "$MODELS_CACHE" 2>/dev/null || true
        if [ -s "$MODELS_CACHE" ]; then
            rm -f "$raw" 2>/dev/null || true
            date '+%s' > "$MODELS_CACHE_TS" 2>/dev/null || : > "$MODELS_CACHE_TS"
            return 0
        fi
        [ "$attempt" -lt 4 ] && sleep 1
    done
    # Never leave a half-written listing behind: an empty file must not be
    # mistaken for a cached answer on the next run.
    rm -f "$raw" "$MODELS_CACHE" "$MODELS_CACHE_TS" 2>/dev/null || true
    return 1
}

models_cache_fresh() {
    [ -s "$MODELS_CACHE" ] && [ -s "$MODELS_CACHE_TS" ] || return 1
    local ts now age
    ts="$(cat "$MODELS_CACHE_TS" 2>/dev/null || printf 0)"
    case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    now="$(date '+%s' 2>/dev/null || printf 0)"
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    age=$((now - ts))
    [ "$age" -ge 0 ] && [ "$age" -le "$MODELS_TTL" ]
}

ensure_models_cache() {
    [ "$MODELS_FORCE_REFRESH" -eq 1 ] || { models_cache_fresh && return 0; }
    refresh_models_cache
}

model_is_available() { # MODEL -> 0 available, 1 confirmed gone, 2 unknown
    models_cache_fresh || return 2
    grep -Fxq -- "$1" "$MODELS_CACHE" 2>/dev/null && return 0
    return 1
}

render_models_menu() { # FILE  -- prints the numbered list, entry 0 = opencode default
    local file="$1" line provider="" last="" n=1
    printf '\n'
    printf '    %s0%s  (opencode default -- no --model flag is passed)\n' "$C_DIM" "$C_OFF"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        provider="${line%%/*}"
        if [ "$provider" != "$last" ]; then
            printf '\n  %s%s/%s\n' "$C_DIM" "$provider" "$C_OFF"
            last="$provider"
        fi
        printf '    %s%3d%s  %s\n' "$C_DIM" "$n" "$C_OFF" "$line"
        n=$((n + 1))
    done < "$file"
    printf '\n'
}

pick_model() { # pick_model ROLE CURRENT -> sets PICK_RESULT and PICK_EOF
    local role="$1" current="$2"
    local candidates="$MODELS_CACHE" reply n idx line
    local narrowed=""
    local -a items=()

    PICK_EOF=0
    if ! is_interactive; then
        PICK_RESULT="$current"
        return 0
    fi
    if ! ensure_models_cache; then
        warn "Cannot list models via '$OPENCODE_BIN models'; keeping the current choice."
        PICK_RESULT="$current"
        return 0
    fi

    while :; do
        items=()
        while IFS= read -r line; do
            [ -n "$line" ] && items+=("$line")
        done < "$candidates"
        if [ "${#items[@]}" -eq 0 ]; then
            warn "No model matches that filter."
            rm -f "$candidates" 2>/dev/null || true
            candidates="$MODELS_CACHE"
            continue
        fi

        printf '%sModel for the %s%s' "$C_BOLD" "$role" "$C_OFF"
        if [ -n "$current" ]; then
            printf '  %s(current: %s)%s' "$C_DIM" "$current" "$C_OFF"
        else
            printf '  %s(current: opencode default)%s' "$C_DIM" "$C_OFF"
        fi
        printf '\n'
        render_models_menu "$candidates"

        # Ctrl-D means "cancel", not "keep the default": answer it once and the
        # whole configuration is abandoned instead of asking three more questions
        # that can no longer be read.
        if ! ask "" "  Number, or part of a name to filter (empty = keep current): "; then
            PICK_EOF=1
            PICK_RESULT="$current"
            rm -f "$narrowed" 2>/dev/null || true
            [ "$candidates" = "$MODELS_CACHE" ] || rm -f "$candidates" 2>/dev/null || true
            return 0
        fi
        reply="$PROMPT_REPLY"

        case "$reply" in
            '')   PICK_RESULT="$current"; rm -f "$narrowed" 2>/dev/null || true; return 0 ;;
            *[!0-9]*)
                # Not a number: treat it as a case-insensitive substring filter.
                narrowed="$RUNTIME_DIR/models.filter.$$"
                grep -i -F -e "$reply" "$MODELS_CACHE" > "$narrowed" 2>/dev/null || true
                if [ -s "$narrowed" ]; then
                    # Only ever discard our own temp file, never the cache.
                    [ "$candidates" = "$MODELS_CACHE" ] || rm -f "$candidates" 2>/dev/null || true
                    candidates="$narrowed"
                else
                    rm -f "$narrowed" 2>/dev/null || true
                    warn "No model matches '$reply'; showing the full list."
                fi
                ;;
            *)
                n="$reply"
                idx=$((n - 1))
                if [ "$n" -eq 0 ]; then
                    PICK_RESULT=""
                elif [ "$idx" -ge 0 ] && [ "$idx" -lt "${#items[@]}" ]; then
                    PICK_RESULT="${items[$idx]}"
                else
                    warn "There is no model number $n."
                    continue
                fi
                rm -f "$narrowed" 2>/dev/null || true
                [ "$candidates" = "$MODELS_CACHE" ] || rm -f "$candidates" 2>/dev/null || true
                return 0
                ;;
        esac
    done
}

report_models_unavailable() {
    # The message has to name the actual cause. `opencode models` is served by
    # the background service, so the usual reason for an empty answer is that
    # service not being up (or not up yet) -- not a missing login: an account
    # with no linked provider still gets the models opencode offers itself.
    printf '\n'
    warn "Could not read the model list from '$OPENCODE_BIN models'."
    printf '  Try, in this order:\n'
    printf '    %s service start    start the background service\n' "$OPENCODE_BIN"
    printf '    %s models           confirm that it prints a list\n' "$OPENCODE_BIN"
    printf '\n'
    printf '  Nothing is lost by skipping this: with no model chosen, opencode\n'
    printf '  falls back to its own configured default. Pick models any time with\n'
    printf '  %s --models, or per run with --pe-model / --coder-model.\n' "${SELF_NAME:-agent-flow.sh}"
}

configure_models() {
    if ! is_interactive; then
        die "--models needs an interactive terminal. In scripts, pass --pe-model / --coder-model instead."
    fi
    if ! ensure_models_cache; then
        report_models_unavailable
        return 1
    fi

    pick_model "Prompt Engineer" "$SAVED_PE_MODEL"
    [ "$PICK_EOF" -eq 0 ] || return 1
    SAVED_PE_MODEL="$PICK_RESULT"

    pick_model "Coding Agent" "$SAVED_CODER_MODEL"
    [ "$PICK_EOF" -eq 0 ] || return 1
    SAVED_CODER_MODEL="$PICK_RESULT"

    # The Context Builder maps the whole repository: a lot of work that a faster,
    # cheaper model handles well. One extra keypress to give it its own.
    printf '\n%sContext Builder%s  [1] share the Prompt Engineer model  [2] pick separately: ' \
        "$C_BOLD" "$C_OFF"
    if ! ask "" ""; then
        PICK_EOF=1
        return 1
    fi
    if [ "$PROMPT_REPLY" = "2" ]; then
        pick_model "Context Builder" "$SAVED_CONTEXT_MODEL"
        [ "$PICK_EOF" -eq 0 ] || return 1
        SAVED_CONTEXT_MODEL="$PICK_RESULT"
    else
        SAVED_CONTEXT_MODEL=""
    fi
    save_models_conf
    return 0
}

maybe_offer_models() {
    # Offered once, on the first real run in a repository, and never when the
    # caller is not a terminal or has already stated a model explicitly.
    case "$MODE" in
        run|prompt-only|implement-only|context-only) ;;
        *) return 0 ;;
    esac
    [ "$PE_MODEL_FLAGGED" -eq 0 ] && [ "$CODER_MODEL_FLAGGED" -eq 0 ] && [ "$CONTEXT_MODEL_FLAGGED" -eq 0 ] \
        || return 0
    load_models_conf && return 0
    is_interactive || return 0
    printf '\n'
    info "No models configured for this repository yet."
    # Ctrl-D here means "not now", not "yes": falling through would only lead to
    # three more questions that can no longer be answered.
    ask "" "  Pick them now? [Y/n] " || return 0
    case "$PROMPT_REPLY" in
        n|N|no|No) return 0 ;;
    esac
    if ! configure_models; then
        # Choosing models is a convenience, not a precondition. A failed lookup
        # must never cost the user the run they actually asked for: fall through
        # with opencode's own default and keep going.
        printf '\n'
        warn "Continuing without changing any model; the run itself is unaffected."
        return 0
    fi
    printf '\n'
    info "Models saved to ${MODELS_CONF#"$ROOT"/}. Change them any time with --models."
}

resolve_models() {
    # Precedence: command-line flag > environment > remembered choice > let
    # opencode decide. Only remembered values are validated: an explicit flag is
    # taken at face value, because the caller may know about a model the listing
    # does not mention.
    # An explicit refresh is also a request to re-check the remembered choices
    # below, so pull a current listing first when the caller asked for one.
    if [ "$MODELS_FORCE_REFRESH" -eq 1 ]; then
        ensure_models_cache || true
    fi
    local role flagged env_value saved
    for role in PE CODER CONTEXT; do
        flagged=0
        eval "flagged=\${${role}_MODEL_FLAGGED}"
        eval "env_value=\${AGENT_FLOW_${role}_MODEL:-}"
        eval "saved=\${SAVED_${role}_MODEL}"
        if [ "$flagged" -eq 0 ] && [ -z "$env_value" ] && [ -n "$saved" ]; then
            validate_saved_model "$role" "$saved"
            eval "${role}_MODEL=\$saved"
        fi
    done
    # The Context Builder follows the Prompt Engineer unless told otherwise.
    [ -n "$CONTEXT_MODEL" ] || CONTEXT_MODEL="$PE_MODEL"
}

validate_saved_model() { # ROLE MODEL
    local role="$1" model="$2" rc
    [ -n "$model" ] || return 0
    # `if` rather than `cmd; rc=$?`: under `set -e` a bare failing command would
    # abort the whole script before rc was ever assigned.
    if model_is_available "$model"; then
        return 0
    else
        rc=$?
    fi
    case "$rc" in
        0) return 0 ;;
        # No fresh listing: trust the stored value rather than paying for a
        # network call on every single run.
        2) return 0 ;;
        *) die "The model remembered for the $role is no longer available: $model
Pick another one with:  ./agent-flow.sh --models
Or override it for this run with the matching --*-model flag." ;;
    esac
}

describe_model() { # MODEL -> printable
    [ -n "$1" ] && printf '%s' "$1" || printf 'opencode default'
}

print_models_line() {
    info "Models: Prompt Engineer=$(describe_model "$PE_MODEL") | Coding Agent=$(describe_model "$CODER_MODEL") | Context Builder=$(describe_model "$CONTEXT_MODEL")"
    info "Change with --models, or per-run with --pe-model / --coder-model / --context-model."
}

# ------------------------------------------------------------------------------
# Run records, and the commands built on them
# ------------------------------------------------------------------------------
#
# A run used to leave nothing but files: prompts, reports, logs. There was no way
# to ask "what did the last run do", "where are its artefacts" or "how do I take
# this back", so .agent/ could only be read by hand. Every run now also writes a
# small record, and --status, --history, --show and --undo are all built on it.
#
# Two files per run, deliberately plain:
#   runs/<TS>.meta   key=value scalars, safe to read back without sourcing
#   runs/<TS>.task   the task text verbatim, since it may be several lines

RUNS_DIR="$WORKFLOW_DIR/runs"
RUN_META=""
RUN_ID=""
RUN_BASE=""
RUN_RESULT=""

read_meta_value() { # read_meta_value KEY FILE -> value on stdout, "" if absent
    local line
    [ -f "$2" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$1="*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < "$2"
    return 0
}

one_line() { # one_line TEXT [MAX] -> single truncated line
    printf '%s' "${1:-}" | tr '\n\r\t' '   ' | tr -s ' ' | cut -c1-"${2:-160}"
}

current_branch_name() {
    if [ "$IN_GIT" -ne 1 ]; then
        printf 'n/a (not a git repository)'
        return 0
    fi
    git symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached HEAD'
}

write_run_record() {
    local branch
    [ -n "$RUN_META" ] || return 0
    branch="$(current_branch_name)"
    {
        printf 'ts=%s\n' "$TS"
        printf 'id=%s\n' "$RUN_ID"
        printf 'mode=%s\n' "$MODE"
        printf 'task_file=%s\n' "${RUNS_DIR#"$ROOT"/}/${RUN_ID}.task"
        printf 'branch=%s\n' "$branch"
        printf 'base=%s\n' "$RUN_BASE"
        printf 'created_branch=%s\n' "$BRANCH_CREATED"
        printf 'result=%s\n' "$RUN_RESULT"
        printf 'rc=%s\n' "$EXIT_CODE"
        printf 'started=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$RUN_META" 2>/dev/null || true
    return 0
}

record_run_start() {
    local n=2
    # Two runs can land in the same second, and a slow one can collide with a
    # fast one. The record must never overwrite the other, so the id is made
    # unique here and used for every file of this run.
    RUN_ID="$TS"
    RUN_META="$RUNS_DIR/${TS}.meta"
    while [ -e "$RUN_META" ]; do
        RUN_ID="${TS}-${n}"
        RUN_META="$RUNS_DIR/${TS}-${n}.meta"
        n=$((n + 1))
    done
    RUN_BASE=""
    RUN_RESULT="running"
    mkdir -p "$RUNS_DIR" 2>/dev/null || { RUN_META=""; RUN_ID=""; return 0; }
    if [ -n "$TASK" ]; then
        printf '%s\n' "$TASK" > "${RUNS_DIR}/${RUN_ID}.task" 2>/dev/null || true
    fi
    RUN_BASE="${BASE_BRANCH:-}"
    write_run_record
}

record_run_end() {
    # BASE_BRANCH is only known after the branch step, so the record is written
    # again here with the real outcome.
    [ -n "$RUN_META" ] || return 0
    [ -n "$RUN_BASE" ] || RUN_BASE="${BASE_BRANCH:-}"
    RUN_RESULT="$1"
    write_run_record
}

latest_run_meta() { # latest_run_meta -> path on stdout, "" if no run yet
    local f
    for f in "$RUNS_DIR"/*.meta; do
        [ -f "$f" ] || continue
        printf '%s' "$f"
        return 0
    done
    return 0
}

# --- status -----------------------------------------------------------------

context_status_line() { # a one-line age/drift summary
    local drift behind days built
    if [ ! -f "$CONTEXT_META" ]; then
        printf 'not built yet'
        return 0
    fi
    if [ ! -s "$CONTEXT_FILE" ]; then
        printf 'built but empty'
        return 0
    fi
    built="$(read_meta_value generated "$CONTEXT_META")"
    drift="$(context_drift)"
    behind=""
    days=""
    case "$drift" in *commits:*) behind="${drift#*commits:}"; behind="${behind%% *}" ;; esac
    case "$drift" in *days:*)    days="${drift##*days:}" ;; esac
    case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
    case "$days" in ''|*[!0-9]*) days=0 ;; esac
    if [ "$behind" -gt 30 ] || [ "$days" -ge "${AGENT_FLOW_CONTEXT_MAX_DAYS:-30}" ]; then
        printf 'STALE (%s commits behind, %s days old) -- rebuild with --refresh-context' \
            "$behind" "$days"
    elif [ "$behind" -eq 0 ] && [ "$days" -eq 0 ]; then
        printf 'up to date (built %s)' "${built:-unknown}"
    else
        printf '%s commits behind HEAD, %s days old' "$behind" "$days"
    fi
}

do_status() {
    local meta branch result task rc dirty prompt_state report_state
    meta="$(latest_run_meta)"
    printf '\n%sagent-flow status%s\n\n' "$C_BOLD" "$C_OFF"
    printf '  %-16s %s\n' "Repository:" "$ROOT"
    printf '  %-16s %s\n' "Branch:" "$(current_branch_name)"
    case "$(current_branch_name)" in
        agent/*) printf '  %-16s %s\n' "" "this is an agent branch; --undo can take it back" ;;
    esac

    if [ -n "$meta" ]; then
        branch="$(read_meta_value branch "$meta")"
        result="$(read_meta_value result "$meta")"
        rc="$(read_meta_value rc "$meta")"
        task="$(one_line "$(cat "${RUNS_DIR}/$(read_meta_value ts "$meta").task" 2>/dev/null || true)" 60)"
        printf '  %-16s %s\n' "Last run:" "$(read_meta_value ts "$meta") (${result:-unknown}, exit ${rc:-?})"
        printf '  %-16s %s\n' "  branch:" "${branch:-n/a}"
        printf '  %-16s %s\n' "  task:" "${task:-(none recorded)}"
    else
        printf '  %-16s %s\n' "Last run:" "none recorded yet"
    fi

    dirty="$(dirty_file_count)"
    printf '  %-16s %s\n' "Uncommitted:" "$dirty path(s) in the working tree"

    if [ -s "$LATEST_PROMPT" ]; then prompt_state="present"; else prompt_state="absent"; fi
    if [ -s "$LATEST_REPORT" ]; then report_state="present"; else report_state="absent"; fi
    printf '  %-16s %s\n' "Prompt:" "$prompt_state ($REL_LATEST_PROMPT)"
    printf '  %-16s %s\n' "Report:" "$report_state ($REL_LATEST_REPORT)"
    printf '  %-16s %s\n' "Context:" "$(context_status_line)"
    printf '  %-16s %s\n' "Models:" \
        "PE=$(describe_model "$PE_MODEL") CA=$(describe_model "$CODER_MODEL") CB=$(describe_model "$CONTEXT_MODEL")"
    if [ "$LOCK_HELD" -eq 1 ]; then
        printf '  %-16s %s\n' "Lock:" "held by this process"
    elif [ -d "$LOCK_DIR" ]; then
        printf '  %-16s %s\n' "Lock:" "present (pid $(lock_owner_pid))"
    else
        printf '  %-16s %s\n' "Lock:" "free"
    fi
    printf '\n'
    return 0
}

# --- doctor -----------------------------------------------------------------

check_ok()   { printf '  %sok%s    %-34s %s\n' "$C_GREEN" "$C_OFF" "$1" "${2:-}"; }
check_warn() { printf '  %swarn%s  %-34s %s\n' "$C_YELLOW" "$C_OFF" "$1" "${2:-}"; }
check_bad()  { printf '  %sfail%s  %-34s %s\n' "$C_RED" "$C_OFF" "$1" "${2:-}"; }

do_doctor() {
    local role file n rc=0

    printf '\n%sagent-flow doctor%s\n\n' "$C_BOLD" "$C_OFF"

    if [ "${BASH_VERSINFO[0]}" -gt 3 ] \
        || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
        check_ok "bash" "${BASH_VERSION} (3.2+ required)"
    else
        check_bad "bash" "${BASH_VERSION} is too old, 3.2 is required"; rc=1
    fi

    if command -v git >/dev/null 2>&1; then
        check_ok "git" "$(git --version 2>/dev/null | head -1)"
    else
        check_bad "git" "not found in PATH"; rc=1
    fi

    if [ "$IN_GIT" -eq 1 ]; then
        check_ok "inside a git work tree" "$(current_branch_name)"
    elif command -v git >/dev/null 2>&1; then
        check_warn "git repository" "not one -- branches and --undo are unavailable"
    fi

    if command -v "$OPENCODE_BIN" >/dev/null 2>&1; then
        check_ok "opencode" "$(command -v "$OPENCODE_BIN")"
        # A binary that cannot answer `run --help` cannot run an agent either,
        # so that is a hard failure, not a warning.
        if "$OPENCODE_BIN" run --help >/dev/null 2>&1; then
            if opencode_supports_auto; then
                check_ok "opencode run --auto" "supported"
            else
                check_warn "opencode run --auto" "not advertised; agents may stall"
            fi
        else
            check_bad "opencode run --help" "does not work -- no agent can be started"; rc=1
        fi
        if "$OPENCODE_BIN" models >/dev/null 2>&1; then
            check_ok "opencode models" "answering"
        else
            check_warn "opencode models" "not answering -- run '$OPENCODE_BIN service start' (--models stays unavailable until then)"
        fi
    else
        check_bad "opencode" "not found in PATH"; rc=1
    fi

    for role in "Prompt Engineer:$PROMPT_ENGINEER_FILE" \
                "Coding Agent:$CODING_AGENT_FILE" \
                "Context Builder:$CONTEXT_BUILDER_FILE"; do
        file="${role#*:}"
        name="${role%%:*}"
        if [ ! -f "$file" ]; then
            check_bad "agent $name" "missing -- run --setup"
            rc=1
        elif ! grep -Fq "$TEMPLATE_MARKER" "$file" 2>/dev/null; then
            check_warn "agent $name" "outdated -- run --setup --force"
        else
            check_ok "agent $name" "up to date"
        fi
    done

    if [ -w "$WORKFLOW_DIR" ] && [ -d "$WORKFLOW_DIR" ]; then
        check_ok "workflow directory" "$WORKFLOW_DIR is writable"
    else
        check_bad "workflow directory" "$WORKFLOW_DIR is not writable"; rc=1
    fi

    if [ "$IN_GIT" -eq 1 ]; then
        n="$(git check-ignore -q "$WORKFLOW_DIR" 2>/dev/null && echo ignored || echo not-ignored)"
        if [ "$n" = "ignored" ]; then
            check_ok "workflow files ignored" "$WORKFLOW_DIR is excluded from git"
        else
            check_warn "workflow files ignored" \
                "$WORKFLOW_DIR is not excluded -- it could be committed by accident"
        fi
    fi

    if [ -d "$LOCK_DIR" ]; then
        check_warn "lock" "present (pid $(lock_owner_pid)); a stale one is reclaimed automatically"
    else
        check_ok "lock" "free"
    fi

    if load_models_conf; then
        check_ok "remembered models" "loaded from ${MODELS_CONF#"$ROOT"/}"
        if models_cache_fresh; then
            for role in PE CODER CONTEXT; do
                eval "m=\${${role}_MODEL}"
                [ -n "$m" ] || continue
                if model_is_available "$m"; then
                    check_ok "model $role" "$m"
                else
                    check_warn "model $role" "$m is not in the current listing -- run --models"
                fi
            done
        else
            check_warn "model listing" "not cached -- run with AGENT_FLOW_MODELS_REFRESH=1 to check"
        fi
    else
        check_warn "remembered models" "none -- opencode's own default will be used"
    fi

    printf '\n'
    if [ "$rc" -eq 0 ]; then
        check_ok "verdict" "ready to run"
    else
        check_bad "verdict" "not ready, see the failures above"
    fi
    printf '\n'
    return "$rc"
}

# --- history ----------------------------------------------------------------

untracked_file_count() {
    # Only files the run could have created. `.agent/` and the agent
    # definitions are excluded from git on purpose, so they must never be
    # counted here or deleted by --undo.
    if [ "$IN_GIT" -ne 1 ]; then
        echo 0
        return 0
    fi
    local n
    n="$(git ls-files --others --exclude-standard -- . \
            ':(exclude).agent' ':(exclude).opencode' 2>/dev/null \
        | wc -l | tr -d ' ' || true)"
    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    printf '%s' "$n"
}

list_dirty_paths() {
    # Show what is about to be discarded, capped so a large run cannot bury the
    # question it is being asked as part of.
    local p shown=0 total
    [ "$IN_GIT" -eq 1 ] || return 0
    total="$(dirty_file_count)"
    [ "$total" -gt 0 ] || return 0
    printf '\n'
    git status --porcelain=v1 -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null \
    | while IFS= read -r p; do
        [ -n "$p" ] || continue
        shown=$((shown + 1))
        if [ "$shown" -le 10 ]; then
            printf '    %s\n' "$p"
        elif [ "$shown" -eq 11 ]; then
            printf '    ... and more\n'
        fi
    done
    return 0
}

do_history() {
    local f id result rc branch task
    printf '\n%sagent-flow history%s  (newest first)\n\n' "$C_BOLD" "$C_OFF"
    if [ ! -d "$RUNS_DIR" ] || [ -z "$(latest_run_meta)" ]; then
        printf '  No runs recorded yet.\n\n'
        return 0
    fi
    printf '  %-16s %-9s %-28s %s\n' "WHEN" "RESULT" "BRANCH" "TASK"
    for f in "$RUNS_DIR"/*.meta; do
        [ -f "$f" ] || continue
        id="$(read_meta_value id "$f")"
        [ -n "$id" ] || id="${f##*/}"
        id="${id%.meta}"
        result="$(read_meta_value result "$f")"
        rc="$(read_meta_value rc "$f")"
        branch="$(read_meta_value branch "$f")"
        task="$(one_line "$(cat "$RUNS_DIR/${id}.task" 2>/dev/null || true)" 40)"
        case "$result" in
            done) result="done" ;;
            *)    result="${result:-?}${rc:+/$rc}" ;;
        esac
        printf '  %-16s %-9s %-28s %s\n' "$(read_meta_value ts "$f")" "$result" "${branch:0:28}" "${task:--}"
    done
    printf '\n  Show one with:  %s --show N      (N counts back from the newest)\n\n' "$SELF_NAME"
    return 0
}

# --- show -------------------------------------------------------------------

resolve_run_id() { # resolve_run_id N -> run id on stdout
    local want="${1:-1}" f id i=0
    for f in "$RUNS_DIR"/*.meta; do
        [ -f "$f" ] || continue
        i=$((i + 1))
        id="${f##*/}"
        id="${id%.meta}"
        if [ "$i" -eq "$want" ]; then
            printf '%s' "$id"
            return 0
        fi
    done
    return 0
}

do_show() {
    local want="${1:-1}" id meta branch result rc prompt report
    if [ ! -d "$RUNS_DIR" ] || [ -z "$(latest_run_meta)" ]; then
        die "No runs recorded yet."
    fi
    id="$(resolve_run_id "$want")"
    [ -n "$id" ] || die "There is no run #$want. See: $SELF_NAME --history"
    meta="$RUNS_DIR/${id}.meta"
    branch="$(read_meta_value branch "$meta")"
    result="$(read_meta_value result "$meta")"
    rc="$(read_meta_value rc "$meta")"

    printf '\n%srun %s%s  mode=%s  result=%s  exit=%s\n' \
        "$C_BOLD" "$(read_meta_value ts "$meta")" "$C_OFF" \
        "$(read_meta_value mode "$meta")" "${result:-?}" "${rc:-?}"
    printf '  branch: %s\n' "${branch:-n/a}"
    if [ -s "$RUNS_DIR/${id}.task" ]; then
        printf '\n%sTask%s\n' "$C_BOLD" "$C_OFF"
        sed 's/^/  /' "$RUNS_DIR/${id}.task"
    fi
    prompt="$PROMPT_DIR/history/${id}.md"
    report="$REPORT_DIR/history/${id}.md"
    if [ -s "$prompt" ]; then
        printf '\n%sPrompt%s  (%s)\n' "$C_BOLD" "$C_OFF" "${prompt#"$ROOT"/}"
        cat "$prompt"
    fi
    if [ -s "$report" ]; then
        printf '\n%sReport%s  (%s)\n' "$C_BOLD" "$C_OFF" "${report#"$ROOT"/}"
        cat "$report"
    fi
    if [ ! -s "$prompt" ] && [ ! -s "$report" ]; then
        printf '\n  (no archived prompt or report for this run)\n'
    fi
    printf '\n'
    return 0
}

# --- undo -------------------------------------------------------------------

base_branch_for() { # base_branch_for BRANCH -> the branch it was created from
    local want="$1" f
    for f in "$RUNS_DIR"/*.meta; do
        [ -f "$f" ] || continue
        if [ "$(read_meta_value branch "$f")" = "$want" ]; then
            read_meta_value base "$f"
            return 0
        fi
    done
    return 0
}

do_undo() {
    local target base unique dirty untracked
    if [ "$IN_GIT" -ne 1 ]; then
        die "--undo needs a git repository; there is nothing to take back."
    fi

    target="${BRANCH_NAME:-$(current_branch_name)}"
    case "$target" in
        agent/*) ;;
        *)
            die "Not on an agent branch (you are on '$target').
--undo only removes branches agent-flow created. Run it on an agent/* branch."
            ;;
    esac

    if ! git show-ref --verify --quiet "refs/heads/$target"; then
        die "Branch '$target' does not exist any more."
    fi

    # The base is whatever the run recorded; if the record is gone (retention,
    # manual cleanup) fall back to the merge base with the default branch.
    base="$(base_branch_for "$target")"
    if [ -z "$base" ] || ! git show-ref --verify --quiet "refs/heads/$base"; then
        for candidate in main master trunk develop; do
            if git show-ref --verify --quiet "refs/heads/$candidate"; then
                base="$candidate"
                break
            fi
        done
    fi
    [ -n "$base" ] || die "Cannot tell which branch '$target' came from, so --undo will not guess. Delete it yourself: git branch -D $target"

    # Commits that exist only on the agent branch are real work. Deleting the
    # branch would destroy them, so this is refused rather than confirmed.
    unique="$(git rev-list --count "${base}..${target}" 2>/dev/null || echo 0)"
    case "$unique" in ''|*[!0-9]*) unique=0 ;; esac
    if [ "$unique" -gt 0 ]; then
        warn "Branch '$target' has $unique commit(s) that are not on '$base'."
        printf '\n  --undo will not delete commits. Keep them:\n'
        printf '    git switch %s && git cherry-pick <sha>     # take them to %s\n' "$target" "$base"
        printf '    git switch %s && git log -p               # read them first\n' "$target"
        printf '  Throw them away on purpose:\n'
        printf '    git switch %s && git branch -D %s\n' "$base" "$target"
        printf '\n'
        return 1
    fi

    dirty="$(dirty_file_count)"
    untracked="$(untracked_file_count)"
    if [ "$dirty" -gt 0 ]; then
        printf '\n'
        warn "The working tree has $dirty uncommitted path(s) from the run."
        list_dirty_paths
        printf '  Tracked changes will be reset. New files (%s of them) will be deleted.\n' "$untracked"
        printf '  Keep everything instead:  git stash push -u -m "agent-flow %s"\n' "$target"
        printf '  Inspect first:           git diff && git status --short\n'
        if [ "$ASSUME_YES" -ne 1 ]; then
            printf '  Discard all of it? Type "undo" to confirm: '
            if ! ask "" ""; then
                printf '\n'
                warn "Nothing was changed."
                return 1
            fi
            case "$PROMPT_REPLY" in
                undo) ;;
                *) printf '\n'; warn "Nothing was changed."; return 1 ;;
            esac
        else
            warn "--yes: discarding uncommitted work without asking."
        fi
        # `reset --hard` only touches tracked files. Anything the agent created
        # is untracked, so removing it needs `clean` too -- otherwise "discard"
        # would quietly leave most of the run's work in place.
        git reset -q --hard "$base" || die "Cannot reset to '$base'."
        if [ "$untracked" -gt 0 ]; then
            git clean -qfd -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null || true
        fi
    else
        warn "Nothing is uncommitted, so nothing can be lost."
        git reset -q --hard "$base" || die "Cannot reset to '$base'."
    fi

    git checkout -q "$base" || die "Cannot switch to '$base'."
    git branch -q -D "$target" || die "Cannot delete branch '$target'."
    success "Removed branch '$target'; you are back on '$base'."
    printf '  %s\n' "Workflow files under .agent/ are kept -- they are only bookkeeping."
    printf '  %s\n' "Remove them with: rm -rf ${WORKFLOW_DIR#"$ROOT"/}"
    printf '\n'
    return 0
}

ensure_dirs() {
    mkdir -p "$AGENT_DIR" "$PROMPT_DIR/history" "$REPORT_DIR/history" \
             "$RUNS_DIR" "$LOG_DIR" "$RUNTIME_DIR" "$CONTEXT_DIR" \
        || die "Cannot create workflow directories under ${WORKFLOW_DIR#"$ROOT"/} (check permissions)."
}

setup_workflow() {
    # Only real runs get the full treatment. --doctor must never repair
    # anything: it would reinstall the very agent files it is about to report as
    # missing, and then have nothing left to report.
    ensure_dirs

    install_agent_file "$PROMPT_ENGINEER_FILE" write_prompt_engineer "Prompt Engineer"
    install_agent_file "$CODING_AGENT_FILE"    write_coding_agent    "Coding Agent"
    install_agent_file "$CONTEXT_BUILDER_FILE" write_context_builder "Context Builder"
    # Not swallowed with `|| true`: an agent whose permissions are known to wreck
    # the run is a reason to stop before spending anything on it, not a warning
    # to scroll past. The lock is not held yet, so exiting here is clean.
    if ! check_agent_templates; then
        exit 1
    fi

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

watchdog_job() { # watchdog_job TIMEOUT JOB_PID MARKER
    sleep "$1" || exit 0
    # The job may well have finished in the meantime; killing it then would hit
    # an unrelated process that reused the pid.
    kill -0 "$2" 2>/dev/null || exit 0
    : > "$3"
    kill -TERM "-$2" 2>/dev/null || kill -TERM "$2" 2>/dev/null || true
    sleep 10
    kill -KILL "-$2" 2>/dev/null || kill -KILL "$2" 2>/dev/null || true
    return 0
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
        # The watchdog gets its own process group so it can be killed together
        # with the `sleep` it is sitting in. Without that, killing the watchdog
        # leaves that `sleep` orphaned: it inherits the script's stdout, so
        # anything piping this script's output would keep waiting for the pipe to
        # close -- for the whole timeout -- long after the run was over.
        set -m
        watchdog_job "$TIMEOUT" "$pid" "$marker" >/dev/null 2>&1 &
        watchdog=$!
        set +m
        # Published so the signal handler can stop it too: a watchdog left running
        # after Ctrl-C would sit in `sleep` for the rest of the timeout, for
        # every interrupted run.
        WATCHDOG_PGID="$watchdog"
    fi

    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi
    AGENT_PGID=""

    if [ "$watchdog" -gt 0 ]; then
        kill -TERM "-$watchdog" 2>/dev/null || kill -TERM "$watchdog" 2>/dev/null || true
        wait "$watchdog" 2>/dev/null || true
        WATCHDOG_PGID=""
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
WATCHDOG_PGID=""

# shellcheck disable=SC2329  # installed as an EXIT trap
release_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        LOCK_HELD=0
        # Only remove the lock while it is still OURS. If our lock was reclaimed
        # as stale by another run (which then wrote its own pid file), an
        # unconditional `rm -rf` here would delete the new owner's lock and let a
        # third run start alongside it.
        if [ "$(lock_owner_pid 2>/dev/null || true)" = "$$" ]; then
            rm -rf "$LOCK_DIR" 2>/dev/null || true
        fi
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
    # The timeout watchdog has to go as well. It is a separate process group, so
    # killing the agent's group leaves it sitting in `sleep` for the rest of the
    # timeout -- one stray process per interrupted run.
    if [ -n "$WATCHDOG_PGID" ] && [ "$WATCHDOG_PGID" != "$$" ]; then
        kill -TERM "-$WATCHDOG_PGID" 2>/dev/null || kill -TERM "$WATCHDOG_PGID" 2>/dev/null || true
        sleep 0.2
        kill -KILL "-$WATCHDOG_PGID" 2>/dev/null || kill -KILL "$WATCHDOG_PGID" 2>/dev/null || true
        WATCHDOG_PGID=""
    fi
    local dirty=""
    if [ "$IN_GIT" -eq 1 ]; then
        dirty="$(dirty_file_count 2>/dev/null || printf 0)"
    fi
    if [ -n "$dirty" ] && [ "$dirty" -gt 0 ] 2>/dev/null; then
        warn "Received SIG$1 — stopping. The lock is released and nothing was committed."
        warn "The working tree has $dirty uncommitted path(s) from the partial run: review with 'git diff' before you re-run."
    else
        warn "Received SIG$1 — stopping. The lock is released and nothing was committed."
    fi
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

# Remove carriage returns and ANSI CSI escape sequences. A single sed does both
# (one process instead of the old `tr | sed` pair); $'...' carries a literal CR
# and ESC, which every sed understands.
sanitize() {
    LC_ALL=C sed -E -e $'s/\r//g' -e "s/$(printf '\033')\[[0-9;?]*[A-Za-z]//g" || true
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

# Print only from the first project-context heading onward (drops tool-call
# noise). Used when the Context Builder could not write its draft file and only
# printed the briefing as its final message.
from_context_start() {
    awk '/^#+[[:space:]]+(Overview|Tech Stack|Repository Layout|Architecture)[[:space:]]*$/ { f = 1 } f { print }'
}

# Fingerprint of the working tree outside .agent/ and .opencode/.
# cksum is POSIX and prints the same bytes on GNU and BSD. Every git call is
# guarded so a failing git (unborn HEAD, old pathspec magic) cannot kill the
# script through pipefail, and so both sides stay comparable.
tree_fingerprint() {
    if [ "$IN_GIT" -ne 1 ]; then
        # Without git there is no porcelain/diff to hash, so the constant "no-git"
        # placeholder made the read-only check in generate_prompt/build_context a
        # no-op: a rogue agent could rewrite the project undetected. Hash the tree
        # directly instead.
        #
        # Only METADATA is hashed (path + size + mtime + ctime + inode + mode),
        # never file content: this costs one stat(2) per file instead of a full
        # read, so the fingerprint is ~4x faster and the cost scales with file
        # COUNT rather than tree SIZE (measured: 143 MB / 9401 files -> 28 ms vs
        # 105 ms, and the gap widens with disk cache pressure). It is exactly as
        # sensitive as git's own index: writing, chmod, replacing, renaming or
        # deleting a file all change ctime/inode/mode, so a modification is still
        # caught. LC_ALL=C sort keeps the digest stable against directory read
        # order. The content-hashing variant stays as a non-GNU-find fallback.
        local out
        out="$(find . \
            \( -name .agent -o -name .opencode -o -name .git \) -prune -o \
            -type f -printf '%p\t%s\t%T@\t%C@\t%i\t%m\n' 2>/dev/null \
            | LC_ALL=C sort \
            | cksum)" || out=""
        if [ -n "$out" ]; then
            printf '%s' "$out"
        else
            find . \
                \( -name .agent -o -name .opencode -o -name .git \) -prune -o \
                -type f -exec cksum {} + 2>/dev/null \
                | LC_ALL=C sort \
                | cksum || printf 'no-git\n'
        fi
        return 0
    fi
    # -uall is required here (the default -unormal collapses an untracked
    # directory to a single "dir/" line, which would hide a file added inside an
    # already-untracked directory). `git diff --cached` is not needed: `git diff
    # HEAD` already spans HEAD -> working tree, so the staged diff is a subset.
    {
        git status --porcelain=v1 -uall -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null || true
        git diff HEAD -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null || true
    } | cksum
}

dirty_file_count() {
    if [ "$IN_GIT" -ne 1 ]; then
        echo 0
        return 0
    fi
    # This only feeds the "N uncommitted path(s)" warning, so the default
    # untracked mode is enough and avoids walking every untracked file.
    local n
    n="$(git status --porcelain=v1 -- . ':(exclude).agent' ':(exclude).opencode' 2>/dev/null \
        | wc -l | tr -d ' ' || true)"
    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    printf '%s' "$n"
}

missing_sections() {
    # missing_sections FILE SECTION...  -> comma-joined list of missing headings
    #
    # One awk pass instead of one `grep -Eiq` per section: the old form re-read
    # the file N times (2.3x slower on a 130 KB prompt, 33 ms -> 14 ms). The
    # report is emitted in the caller's section order so it stays stable.
    local file="$1"; shift
    local joined="" section
    for section in "$@"; do
        joined="${joined:+$joined|}$section"
    done
    if [ ! -f "$file" ]; then
        # Every section counts as missing (as before), but without grep's
        # per-section "No such file" spew.
        printf '%s' "${joined//|/, }"
        return 0
    fi
    awk -v want_list="$joined" '
        BEGIN {
            n = split(want_list, names, "|")
            for (i = 1; i <= n; i++) want[names[i]] = 1
        }
        {
            line = $0
            sub(/[[:space:]]+$/, "", line)
            if (match(line, /^#{1,3}[ \t]+/) == 0) next
            rest = substr(line, RSTART + RLENGTH)
            if (rest in want) delete want[rest]
        }
        END {
            out = ""
            for (i = 1; i <= n; i++)
                if (names[i] in want)
                    out = (out == "") ? names[i] : out ", " names[i]
            printf "%s", out
        }
    ' "$file"
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
        run_agent "$raw" "$log" context-builder "$CONTEXT_MODEL" "$instruction" || rc=$?

        after="$(tree_fingerprint)"

        if [ "$rc" -ne 0 ]; then
            rm -f "$raw"
            die "Context Builder failed (exit $rc). See ${log#"$ROOT"/}"
        fi
        if [ "$before" != "$after" ]; then
            rm -f "$raw"
            if [ "$IN_GIT" -eq 1 ]; then
                die "Context Builder modified project files (it must be read-only). Inspect with 'git status' / 'git diff'."
            fi
            die "Context Builder modified project files (it must be read-only). Not a git repository, so there is no diff to inspect; compare the tree against a backup."
        fi

        if [ -s "$CONTEXT_DRAFT" ]; then
            candidate="$(sanitize < "$CONTEXT_DRAFT" | strip_outer_fence)"
        else
            # Same fallback as generate_prompt: the agent may have been unable to
            # write the draft (permissions, full disk) and printed the briefing as
            # its final message instead. Dying here would fail the whole run.
            warn "Context draft not written; falling back to the agent's final message."
            candidate="$(sanitize < "$raw" | from_context_start | strip_outer_fence)"
        fi
        rm -f "$raw"

        if [ -z "${candidate//[[:space:]]/}" ]; then
            missing="(the draft file was not written and the agent printed no briefing)"
        else
            printf '%s\n' "$candidate" > "$CONTEXT_DRAFT"
            missing="$(missing_context_sections "$CONTEXT_DRAFT")"
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

context_drift() { # context_drift -> "commits:BEHIND days:DAYS", missing parts are empty
    local saved current n gen built_at now
    printf ''
    [ "$IN_GIT" -eq 1 ] || return 0
    [ -f "$CONTEXT_META" ] || return 0
    saved="$(read_meta_value commit "$CONTEXT_META")"
    if [ -n "$saved" ] && [ "$saved" != "none" ]; then
        current="$(git rev-parse HEAD 2>/dev/null || true)"
        if [ -n "$current" ] && [ "$saved" != "$current" ]; then
            n="$(git rev-list --count "${saved}..${current}" 2>/dev/null || echo 0)"
            case "$n" in ''|*[!0-9]*) n=0 ;; esac
            printf 'commits:%s ' "$n"
        fi
    fi
    # Age matters even when the commit did not move: a context written three
    # months ago describes a repository that has since been edited on another
    # branch, and nothing would have noticed.
    gen="$(read_meta_value generated "$CONTEXT_META")"
    if [ -n "$gen" ]; then
        built_at="$(date -d "$gen" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "$gen" '+%s' 2>/dev/null || echo '')"
        now="$(date '+%s')"
        if [ -n "$built_at" ]; then
            n=$(( (now - built_at) / 86400 ))
            [ "$n" -ge 0 ] && printf 'days:%s' "$n"
        fi
    fi
    return 0
}

ensure_context() {
    local drift behind days reason=""

    if [ "$REFRESH_CONTEXT" -eq 1 ] || [ ! -s "$CONTEXT_FILE" ]; then
        build_context
        return 0
    fi

    drift="$(context_drift)"
    behind=""
    days=""
    case "$drift" in
        *commits:*) behind="${drift#*commits:}"; behind="${behind%% *}"; behind="${behind%%days:*}" ;;
    esac
    case "$drift" in
        *days:*) days="${drift##*days:}" ;;
    esac
    case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
    case "$days" in ''|*[!0-9]*) days=0 ;; esac

    if [ "$behind" -gt 30 ]; then
        reason="$behind commits behind HEAD"
    fi
    if [ "$days" -ge "${AGENT_FLOW_CONTEXT_MAX_DAYS:-30}" ]; then
        if [ -n "$reason" ]; then
            reason="$reason and $days days old"
        else
            reason="$days days old"
        fi
    fi
    if [ -n "$reason" ]; then
        warn "Project context is stale ($reason). Rebuild with --refresh-context."
    fi
    info "Using existing project context ($REL_CONTEXT)."
}

# ------------------------------------------------------------------------------
# Branch handling
# ------------------------------------------------------------------------------

slugify() {
    # ASCII-only, dash separated, bounded length, never empty, never leading or
    # trailing dashes. Works identically on GNU and BSD userland.
    #
    # Cyrillic is transliterated first. Without it the ASCII stage below deletes
    # every character of a Russian (or Ukrainian/Bulgarian/...) task and the slug
    # collapses to "", so every such branch would be called "task". The mapping
    # is a loop of literal ${var//from/to} substitutions: no associative arrays
    # (bash 3.2), no locale-dependent character slicing, no external translit.
    local r="${1:-}" kv k v
    for kv in \
        "А:A" "а:a" "Б:B" "б:b" "В:V" "в:v" "Г:G" "г:g" "Д:D" "д:d" \
        "Е:E" "е:e" "Ё:Yo" "ё:yo" "Ж:Zh" "ж:zh" "З:Z" "з:z" "И:I" "и:i" \
        "Й:J" "й:j" "К:K" "к:k" "Л:L" "л:l" "М:M" "м:m" "Н:N" "н:n" \
        "О:O" "о:o" "П:P" "п:p" "Р:R" "р:r" "С:S" "с:s" "Т:T" "т:t" \
        "У:U" "у:u" "Ф:F" "ф:f" "Х:X" "х:h" "Ц:Ts" "ц:ts" "Ч:Ch" "ч:ch" \
        "Ш:Sh" "ш:sh" "Щ:Sch" "щ:sch" "Ъ:" "ъ:" "Ы:Y" "ы:y" "Ь:" "ь:" \
        "Э:E" "э:e" "Ю:Yu" "ю:yu" "Я:Ya" "я:ya"
    do
        k="${kv%%:*}"
        v="${kv#*:}"
        r="${r//$k/$v}"
    done

    printf '%s' "$r" \
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
    if [ -n "$current" ]; then
        MERGE_HINT="git switch $current && git merge $name"
    fi
    if git show-ref --verify --quiet "refs/heads/$name"; then
        git checkout -q "$name" || die "Cannot switch to existing branch $name (uncommitted changes in the way?)."
        info "Switched to existing branch $name."
    else
        # BASE_BRANCH is only set when this run actually created something, so the
        # final summary never claims "(created from X)" for a branch it merely
        # switched to.
        BASE_BRANCH="${current:-detached HEAD}"
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
    if [ -z "$slug" ]; then
        # Nothing ASCII-representable survived (task written only in CJK, emoji,
        # ...). Fall back to a stable hash of the task text so that different
        # tasks still get different branches instead of all colliding on "task".
        slug="task-$(printf '%s' "$slug_source" | cksum | cut -d ' ' -f 1)"
    fi
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

    # Only runner-controlled variables ($REL_*) are ever interpolated into the
    # heredocs below. The user's task text is printed with printf instead of
    # being embedded as heredoc SOURCE, so it can neither terminate a heredoc
    # nor be re-expanded: a task containing a line "EOF" (or "$(id)") is inert.
    printf '%s\n' \
        'Create an execution-ready prompt for the Coding Agent.' \
        '' \
        'USER REQUEST:'
    printf '%s\n' "$TASK"

    if [ "$CONTINUE" -eq 1 ]; then
        cat <<EOF

MODE: CONTINUATION of earlier work.
- Read $REL_LATEST_REPORT first, especially "Remaining Issues" and "Notes For Next Agent".
- Read $REL_LATEST_PROMPT to see what was originally requested.
- Run git status and git diff --stat, then verify in the actual code what the previous run did and did not accomplish.
- The new prompt must build on the work that already exists: do not ask for it to be redone, preserve decisions the report says must not be reverted, and warn against approaches the report says failed.
- Focus the prompt on what is still missing or broken, plus the user's new instructions above.
EOF
    else
        cat <<EOF

MODE: NEW TASK.
- Read $REL_LATEST_REPORT for context, but it may be unrelated to this task; use it only if it is relevant.
- Check git status to see whether uncommitted work exists that this task must account for.
EOF
    fi

    cat <<EOF

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
            if [ "$IN_GIT" -eq 1 ]; then
                die "Prompt Engineer modified project files (it must be read-only). Inspect with 'git status' / 'git diff'. Aborting before anything is overwritten."
            fi
            die "Prompt Engineer modified project files (it must be read-only). Not a git repository, so there is no diff to inspect; compare the tree against a backup. Aborting before anything is overwritten."
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
    #
    # Markdown emphasis is stripped from the whole line before matching, not just
    # from the emitted value: without it "# **Result**: **COMPLETED**" matched no
    # branch at all (the "**" between "Result" and ":" is not a space), the result
    # came back empty and every run ended in exit code 3.
    #
    # Uppercasing and the "first non-empty result line wins" rule are folded into
    # this single awk (the old awk | tr | awk chain cost three processes).
    awk '
        function emit(v,   n, w, i) {
            gsub(/^[-*[:space:]]+/, "", v)
            gsub(/[[:space:]]+$/, "", v)
            gsub(/[*`]/, "", v)          # markdown emphasis; keep underscores
            if (v == "") return
            n = split(v, w, /[^A-Za-z_]+/)
            for (i = 1; i <= n; i++) {
                if (w[i] != "") { word = w[i]; found = 1; exit }
            }
        }
        {
            line = $0
            gsub(/[*`]/, "", line)               # bold/italic markers anywhere
            sub(/^[[:space:]#]+/, "", line)     # heading markers, bullets
            sub(/[[:space:]]+$/, "", line)
            key = tolower(line)
            if (key ~ /^result[[:space:]]*$/) { f = 1; next }
            if (f && NF) { emit(line); next }
            if (key ~ /^result[[:space:]]*[:.]?[[:space:]]*[a-z_]+/) {
                v = line
                sub(/^[Rr]esult[[:space:]]*[:.]?[[:space:]]+/, "", v)
                emit(v)
                next
            }
        }
        END { if (found) print toupper(word) }
    ' "$LATEST_REPORT" 2>/dev/null || true
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

if [ "$CHOOSE_MODELS" -eq 0 ] \
    && [ "$MODE" != "implement-only" ] && [ "$MODE" != "context-only" ] \
    && [ "$MODE" != "status" ] && [ "$MODE" != "doctor" ] && [ "$MODE" != "history" ] \
    && [ "$MODE" != "undo" ] && [ "$MODE" != "show" ] && [ -z "$TASK" ]; then
    die "No task supplied. Example: ./agent-flow.sh \"Add authentication\""
fi
if [ "$CHOOSE_MODELS" -eq 1 ] && [ -n "$TASK" ]; then
    warn "A task was given together with --models; ignoring the task text."
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

prune_history

# The read-only commands must never queue behind a run, or block one: they take
# no lock and they never wait for it. They also skip setup_workflow, so that
# --doctor reports what is actually on disk instead of repairing it first.
case "$MODE" in
    status)  ensure_dirs; resolve_models; do_status; exit 0 ;;
    doctor)  ensure_dirs; resolve_models; do_doctor; exit "$?" ;;
    history) ensure_dirs; do_history; exit 0 ;;
    show)    ensure_dirs; do_show "$SHOW_RUN"; exit 0 ;;
    undo)    ensure_dirs; do_undo || exit 1; exit 0 ;;
esac

setup_workflow
acquire_lock
EXIT_CODE=0
record_run_start

load_models_conf || true
if [ "$CHOOSE_MODELS" -eq 1 ]; then
    if ! configure_models; then
        if [ "$PICK_EOF" -eq 1 ]; then
            printf '\n'
            warn "Model selection cancelled; nothing was changed."
            exit 0
        fi
        # The details have already been reported by report_models_unavailable.
        exit 1
    fi
    success "Models saved to ${MODELS_CONF#"$ROOT"/}."
    printf '\n%sPrompt Engineer: %s%s\n%sCoding Agent:    %s%s\n%sContext Builder: %s%s\n' \
        "$C_BOLD" "$(describe_model "$SAVED_PE_MODEL")" "$C_OFF" \
        "$C_BOLD" "$(describe_model "$SAVED_CODER_MODEL")" "$C_OFF" \
        "$C_BOLD" "$(describe_model "$SAVED_CONTEXT_MODEL")" "$C_OFF"
    exit 0
fi
maybe_offer_models
resolve_models
print_models_line

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
        # Checked before ensure_branch: otherwise a missing prompt would still
        # leave the user on a freshly created, empty agent/... branch.
        [ -s "$LATEST_PROMPT" ] \
            || die "No prompt found at $REL_LATEST_PROMPT. Run without --implement-only first."
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

if [ "$EXIT_CODE" -eq 0 ]; then
    record_run_end "done"
else
    record_run_end "failed"
fi

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