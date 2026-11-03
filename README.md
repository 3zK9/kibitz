# kibitz

[![ci](https://github.com/3zK9/kibitz/actions/workflows/ci.yml/badge.svg)](https://github.com/3zK9/kibitz/actions/workflows/ci.yml) [![security](https://github.com/3zK9/kibitz/actions/workflows/security.yml/badge.svg)](https://github.com/3zK9/kibitz/actions/workflows/security.yml)

A vim-style terminal diff reviewer for code written by AI agents — and it talks back to
the agent: [Claude Code](https://claude.com/claude-code), [Codex CLI](https://github.com/openai/codex),
[Pi](https://pi.dev) or [Antigravity CLI](https://github.com/google-antigravity/antigravity-cli) (`agy`).

```
 kibitz ── agent/add-coupons-and-rate-limit ← main   [diff] files   3 files  +26 -5
────────────────────────────────────────────────────────────────────────────────
  M src/orders.py  +7 -0 ─────────────────────────────────────────────────  2/3
        @@ -19 +19 @@ class Order:
  20  20       def amount(self, coupon=None):
  21  21           sub = self.cart.subtotal()
▌     22 +         self.coupon = coupon
        ╰─▶ side effect in a getter?  [unsent]
  22  23           return total(sub, self.state, coupon) + shipping(sub)
▌DIFF  src/orders.py:22             ● 1 unsent   c comment  S send  t claude   60%
```

Review every changed file with vim keys, leave comments on lines, and send them straight
into the agent session that made the changes — without leaving the terminal.

## Features

- **Diff view** — every changed file in one scrolling view, with a file list, 24-bit
  red/green tints, word-level change highlighting and syntax colouring.
- **File browser** — a `tree`-style view of the whole repo; open any file read-only with
  changed lines marked in the gutter.
- **Review comments** — comment on a line or a visual selection; `S` writes them to a
  review file and tells the agent to address them.
- **Your agent, inside kibitz** — the agent's real screen runs in a panel on the right.
  `i` (or a click) types straight into it, colors, shortcuts and all; `t` does the same with
  the line you're on already typed. `Ctrl+]` or a click on the diff takes you back, and `Esc` closes the panel.
- **Live reload** — the diff refreshes every 2 seconds, so you can watch an agent work.
- Untracked files are included; any `git diff` arguments work (`kibitz main`, `kibitz --cached`).

## Install

Requires [Zig](https://ziglang.org) 0.17 (`brew install zig`) and macOS or Linux.

```sh
git clone https://github.com/3zK9/kibitz && cd kibitz
./build.sh        # builds and installs to ~/.local/bin/kibitz
```

## Usage

Inside your agent, from your repo (all four run `!` lines as shell commands):

```
! kibitz          # HEAD + working tree
! kibitz main     # everything since main
```

| Agent | Detected as | Notes |
|---|---|---|
| Claude Code | `claude` | |
| Codex CLI | `codex` | works with Codex's background daemon, which runs `!` commands outside your pane |
| Pi | `pi` | |
| Antigravity CLI | `agy` | |

When run without a terminal (as `!` does), kibitz finds the pane your agent is running in
and opens itself next to it using the Rex terminal's `rex` CLI. The agent is detected from
the running processes; pass `--agent claude|codex|pi|agy` to pick one yourself. Running
`! kibitz` again jumps back to the open review instead of starting a new one. In a plain terminal, just run `kibitz`; comments are saved to
`.git/kibitz/` but can't be sent automatically.

## Keys

| | |
|---|---|
| `j` `k` · `^d` `^u` · `gg` `G` | move · half page · top / bottom |
| `J` `K` / `Tab` | next / previous file |
| `{` `}` | previous / next hunk |
| `/` `n` `N` | search |
| `H` `L` | scroll sideways |
| `Enter` / `f` | open the file in the browser · switch diff ⇄ files |
| `h` `l` | (files) tree ⇄ file, collapse / expand |
| `c` · `v` · `x` | comment · visual select · delete comment |
| `S` | send all comments to the agent |
| `t` · `i` | talk to the agent about this line · type to the agent |
| `Esc` / `C` · `Ctrl+]` | close / toggle the agent panel · back to the diff |
| `e` | open in `$EDITOR` at this line |
| `z` · `r` · `?` · `q` | zoom pane · reload · help · quit |

## Development

```sh
zig test src/main.zig -lc     # unit + fuzz tests, safety-checked
zig fmt src                   # format
./build.sh                    # release build + install
```

CI runs on macOS and Linux: format check, tests, and a ReleaseSafe build. The security
workflow runs gitleaks (secrets), CodeQL and zizmor (GitHub Actions workflows) and
ShellCheck on every push, PR, and daily. There is no mainstream SAST engine for Zig yet,
so the parsers that handle untrusted repo content are covered by randomized tests run
with Zig's runtime safety checks enabled.

## License

[Apache License 2.0](LICENSE)
