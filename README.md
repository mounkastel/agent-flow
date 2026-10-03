# agent-flow

A two-agent pipeline for [OpenCode](https://opencode.ai): Prompt Engineer → Coding Agent.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/mounkastel/agent-flow/main/agent-flow.sh -o ~/.local/bin/agent-flow
chmod +x ~/.local/bin/agent-flow
command -v agent-flow          # must print the path, not "command not found"
```

If that last line prints nothing, `~/.local/bin` is not on your `PATH` yet. Add it once:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

Or `git clone https://github.com/mounkastel/agent-flow.git` and move `agent-flow.sh` to
`~/.local/bin/agent-flow`. Requires `bash` (3.2+), `git` and `opencode`.

`opencode` is needed too, and its background service must be able to answer a model
listing. If `opencode models` prints nothing, start it once with `opencode service start`
— agent-flow waits and retries for a moment, but cannot wait forever.

Linux is the primary target and gets the fastest code paths. The script still runs on
BSD/macOS userland (`find`, `sed`, `awk` and `cksum` are used through their portable
subset), it just falls back to the slower content-hashing tree fingerprint when `find`
has no `-printf`.

## Quick Start

```sh
agent-flow "Add pagination to the users endpoint"   # full cycle: prompt -> implement
agent-flow --continue "Now add filtering"           # keep going on the same branch
agent-flow --prompt-only "Add pagination"           # prompt only; review, then --implement-only
agent-flow --implement-only                         # run the prompt that is already there
agent-flow --setup                                  # install the agent definitions only
agent-flow --models                                 # pick the models, then exit
agent-flow --pr "Add pagination"                    # run, then commit, push and open a PR
```

Exit codes: `0` done, `2` partial/blocked/failed, `3` no report, `1` workflow error.

## Sending the work: `--pr`

Without it, sending a run to your forge is six commands: inspect the diff, compare against
the base, switch back, stage, push, delete the branch. With it, one:

```sh
agent-flow --pr "Turn off the swaylock idle lock"
```

After the run, the **runner** — not the agent — commits the working tree, pushes the agent
branch and opens a pull request against the branch the run branched from. You read it and
merge it.

That split is deliberate. The coding agent has no permission to commit or push, so
`git add -A` cannot sweep up an unrelated untracked artifact, and the branch that gets
pushed is exactly the one this run created — not wherever an agent decided to point.

```
agent-flow --pr "task"          commit, push, open a PR
agent-flow --pr --draft "task"  ...as a draft
agent-flow --pr --push-only     commit and push, no PR
agent-flow --pr --pr-base dev   target dev instead of the branch the run started from
agent-flow --yes                skip the confirmation
```

`--draft`, `--push-only` and `--pr-base` all imply `--pr`, so they work on their own.

It composes with everything else, so to make it the default:

```sh
alias af='agent-flow --pr'
```

**It never merges.** Nothing is auto-enabled. A run that did not report `COMPLETED` is
opened as a draft with the result in the title, so a blocked run cannot look finished. If a
pull request for the branch is already open, that one is updated instead of a second being
opened.

**It refuses to publish anything that looks like a credential.** `.env`, `.netrc`,
`.npmrc`, `id_rsa`, `*.pem`, `*.key`, `*.p12` and friends are staged but never committed and
never pushed; the run stops and names the files. This check is not skippable by `--yes`.
agent-flow's own files (`.agent/`, `.opencode/agents/`) are taken back out of the commit
and listed, so workflow bookkeeping can never reach a remote.

Before committing, it prints the paths it is about to commit and waits for you to type `pr`.
`--yes` skips that one prompt.

If `gh` is missing or logged out, the commit and the push still happen — the work is safe
on the remote — and you are told the exact `gh pr create` line to finish by hand.

## Finding your way around

```sh
agent-flow --status        # what happened last, and where things stand right now
agent-flow --doctor        # check the environment, get told what is broken
agent-flow --history       # past runs, newest first
agent-flow --show          # the task, prompt and report of the newest run
agent-flow --show 3        # ...or of an older one
agent-flow --undo          # take the last agent branch back
```

**`--status`** answers "where am I?" without changing anything: the last run and its
outcome, the current branch, how many uncommitted paths are lying around, whether the
prompt and report exist, how stale the project context is, which models are in use, and
whether the lock is free.

**`--doctor`** checks bash, git, opencode (can it start an agent? can it list models?),
each agent definition, whether `.agent/` is writable and excluded from git, the lock, and
whether your remembered models still exist. It ends with a verdict and an exit code, so
it is usable from a setup script. It never repairs anything — it would otherwise
reinstall the very files it is about to report as missing.

**`--history` / `--show`** read the run records under `.agent/runs/`. `--show` prints the
task verbatim plus the archived prompt and report.

**`--undo`** removes the agent branch and its work:

- If the branch has commits of its own, `--undo` **refuses** and tells you how to keep
  or inspect them. Committed work is never deleted, and `--yes` does not unlock that.
- Otherwise it lists what will be discarded, and asks you to type `undo`. It resets
  tracked changes **and** deletes the files the agent created (`reset --hard` alone would
  leave every new file behind).
- `.agent/` is kept — it is bookkeeping, and you may still want the report.

After a `--pr` run, `--undo` only tidies up locally. The pushed branch and the open pull
request stay where they are, because closing a pull request is the reviewer's business.

A clean working tree needs no confirmation, because nothing can be lost.

## Limits

Every agent call is capped at `--timeout` seconds (default 3600, `0` disables it) so a
wedged agent cannot hang a run forever. `AGENT_FLOW_TIMEOUT` overrides it.

The project context is rebuilt on demand and called out as stale once it falls more than
30 commits behind `HEAD` or is more than 30 days old (`AGENT_FLOW_CONTEXT_MAX_DAYS`).
Until it is rebuilt with `--refresh-context`, the agents are reading an old map.

## Models

Each agent can use a different model. The candidate list comes from `opencode models`,
so it is exactly what your account can reach — no hardcoded catalogue to go stale.

The **first run in a repository** offers a one-time picker. The choice is remembered in
`.agent/models.conf` (never committed), and every later run just prints which models it
is about to use. Re-pick any time with `--models`, or override for a single run:

```sh
agent-flow --pe-model anthropic/claude-opus-4-1 --coder-model openai/gpt-5.2 "task"
```

Precedence is **flag → environment → remembered choice → opencode's own default**. An
empty value means no `--model` flag is passed at all, which is a legitimate choice the
picker offers explicitly. Only remembered choices are validated against the cached
listing; an explicit flag is always taken at face value.

The picker filters by substring and then takes a number, so it stays usable with a few
hundred models installed, and `Ctrl-D` cancels without changing anything. In a
non-interactive context (CI, a script, a pipe) it never prompts and never blocks.

The listing is cached under `.agent/runtime` for `AGENT_FLOW_MODELS_TTL` seconds
(default 24h) because it costs a round trip to the opencode server. After changing
accounts or adding a provider, re-check the list with `AGENT_FLOW_MODELS_REFRESH=1
agent-flow "task"`.

If the listing cannot be read at all, the run is **not** blocked: agent-flow says what to
try and continues on opencode's own default model. Picking models is a convenience, not a
precondition.

## How it works

1. **Context** — a read-only agent maps the repo once into `.agent/context/PROJECT.md`.
2. **Branch** — each task runs on its own `agent/<slug>-<timestamp>` branch; the agent never commits.
   Latin text is slugified as usual, Cyrillic is transliterated
   (`Исправить валидацию токена` → `agent/ispravit-validatsiyu-tokena-...`), and scripts
   with no transliteration table fall back to a stable `task-<hash>` slug rather than an
   empty one.
3. **Isolation** — all workflow files stay out of git via `.git/info/exclude`; you review the diff and commit.

Both read-only agents are enforced, not trusted: the runner fingerprints the working tree
before and after each of them and aborts if anything changed. Outside a git repository the
fingerprint is built from file metadata (path, size, mtime, ctime, inode, mode) — as
sensitive as git's own index, but it never reads file contents.

### What the agents are allowed

OpenCode V2 decides permissions from ordered `action`/`resource`/`effect` rules, last match
wins, and `bash` matches the *parsed command* (`git status --porcelain`).

| Agent | shell | writes | cannot |
|---|---|---|---|
| `context-builder` | read-only, plus `make`/`npm test`/`bash -n`/`cargo check` | its own `PROJECT.draft.md` | `git commit`, `rm`, `chmod`, `curl`, `sudo` |
| `prompt-engineer` | same | its own `draft.md` | same |
| `coding-agent` | everything but history rewriting and privilege | the repository | `git commit`, `git push`, `git reset`, `sudo`, `curl \| sh`, editing the prompt |

There is deliberately **no catch-all `action: "*" → deny`** in any definition. That exact
shape — the last matching `*/*` rule being a deny — makes opencode refuse to serve its own
free models to that agent:

```
Error from provider (Console): OpenCode's free tier can only be used from within OpenCode
```

The agent cannot run at all, so the strictest possible block disables the tool for exactly
the accounts that only have free models. A deny on a single action (`action: "edit"`) or a
single command pattern (`resource: "rm*"`) is served normally, so the protection is written
the long way: everything wanted is allowed by name and everything dangerous is denied by
name. `--doctor` and the pre-run check both refuse to start a run whose definitions still
carry the catch-all, so this cannot come back unnoticed.

## Tests

```sh
bash tests/test_agent_flow.sh            # everything
bash tests/test_agent_flow.sh -v         # also print each command's output
bash tests/test_agent_flow.sh -f lock    # only tests whose filter matches
```

The suite drives the real script against a mocked `opencode` binary inside a temporary
sandbox: no API calls, no network, nothing written outside `$TMPDIR`. It covers the CLI
surface, setup, the full cycle and its exit codes, every mode, branch handling, paths with
spaces and quotes, locking and signal handling, retention, the timeout watchdog, model
selection, the run records behind `--status`/`--history`/`--show`/`--undo` and its refusal
to delete commits, publishing with `--pr` (what it opens and everything it refuses to),
the agent contracts, and a set of hostile-input cases. Exit code 0
means every assertion passed; `shellcheck -S warning` is also asserted when `shellcheck` is
installed.