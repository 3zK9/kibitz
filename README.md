# revdiff

A vim-style terminal diff reviewer for code written by AI agents — and it talks back to
your [Claude Code](https://claude.com/claude-code) session.

```
 revdiff ── agent/add-coupons-and-rate-limit ← main   [diff] files   3 files  +26 -5
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
into the Claude Code session that made the changes — without leaving the terminal.

## Features

- **Diff view** — every changed file in one scrolling view, with a file list, 24-bit
  red/green tints, word-level change highlighting and syntax colouring.
- **File browser** — a `tree`-style view of the whole repo; open any file read-only with
  changed lines marked in the gutter.
- **Review comments** — comment on a line or a visual selection; `S` writes them to a
  review file and tells Claude to address them.
- **Talk to Claude** — `t` sends a message into your Claude Code session; a live panel shows
  Claude's replies while you keep reviewing.
- **Live reload** — the diff refreshes every 2 seconds, so you can watch an agent work.
- Untracked files are included; any `git diff` arguments work (`revdiff main`, `revdiff --cached`).

## Install

Requires [Zig](https://ziglang.org) 0.17 (`brew install zig`) and macOS or Linux.

```sh
git clone https://github.com/3zK9/revdiff && cd revdiff
./build.sh        # builds and installs to ~/.local/bin/revdiff
```

## Usage

Inside Claude Code, from your repo:

```
! revdiff          # HEAD + working tree
! revdiff main     # everything since main
```

When run without a terminal (as Claude Code's `!` does), revdiff opens itself in a new pane
next to Claude using the Rex terminal's `rex` CLI, and links that pane to
your session. In a plain terminal, just run `revdiff`; comments are saved to
`.git/revdiff/` but can't be sent automatically.

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
| `S` | send all comments to Claude |
| `t` · `C` | ask Claude · show / hide the Claude panel |
| `e` | open in `$EDITOR` at this line |
| `z` · `r` · `?` · `q` | zoom pane · reload · help · quit |
