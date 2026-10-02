# agent-flow

A two-agent pipeline for [OpenCode](https://opencode.ai): Prompt Engineer → Coding Agent.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/mounkastel/agent-flow/main/agent-flow.sh -o ~/.local/bin/agent-flow
chmod +x ~/.local/bin/agent-flow
```

Or `git clone https://github.com/mounkastel/agent-flow.git` and move `agent-flow.sh` to
`~/.local/bin/agent-flow`. Requires `bash` (3.2+), `git` and `opencode`.

Linux is the primary target and gets the fastest code paths. The script still runs on
BSD/macOS userland (`find`, `sed`, `awk` and `cksum` are used through their portable
subset), it just falls back to the slower content-hashing tree fingerprint when `find`
has no `-printf`.

## Quick Start

```sh
agent-flow "Add pagination to the users endpoint"   # full cycle: prompt -> implement
agent-flow --continue "Now add filtering"           # keep going on the same branch
agent-flow --prompt-only "Add pagination"           # prompt only; review, then --implement-only
agent-flow --setup                                  # install the agent definitions only
agent-flow --models                                 # pick the models, then exit
```

Exit codes: `0` done, `2` partial/blocked/failed, `3` no report, `1` workflow error.

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
(default 24h) because it costs a round trip to the opencode server.

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
selection, the agent contracts, and a set of hostile-input cases. Exit code 0 means every
assertion passed; `shellcheck -S warning` is also asserted when `shellcheck` is installed.