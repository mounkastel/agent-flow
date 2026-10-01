# agent-flow

A two-agent pipeline for [OpenCode](https://opencode.ai): Prompt Engineer → Coding Agent.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/mounkastel/agent-flow/main/agent-flow.sh -o ~/.local/bin/agent-flow
chmod +x ~/.local/bin/agent-flow
```

Or `git clone https://github.com/mounkastel/agent-flow.git` and move `agent-flow.sh` to
`~/.local/bin/agent-flow`. Requires `bash`, `git` and `opencode`.

## Quick Start

```sh
agent-flow "Add pagination to the users endpoint"   # full cycle: prompt -> implement
agent-flow --continue "Now add filtering"           # keep going on the same branch
agent-flow --prompt-only "Add pagination"           # prompt only; review, then --implement-only
agent-flow --setup                                  # install the agent definitions only
```

Exit codes: `0` done, `2` partial/blocked/failed, `3` no report, `1` workflow error.

## How it works

1. **Context** — a read-only agent maps the repo once into `.agent/context/PROJECT.md`.
2. **Branch** — each task runs on its own `agent/<slug>-<timestamp>` branch; the agent never commits.
3. **Isolation** — all workflow files stay out of git via `.git/info/exclude`; you review the diff and commit.

## Tests

```sh
bash tests/test_agent_flow.sh   # mocked opencode, no API calls
```