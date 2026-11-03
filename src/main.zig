//! kibitz: a vim-style git diff reviewer that talks back to your coding agent.
//!
//! From inside Claude Code, Codex, Pi or Antigravity type `! kibitz` (any
//! `git diff` args work too, e.g. `! kibitz main`). It opens in a Rex pane next
//! to the agent; comments you leave get sent straight into that session. Press
//! ? inside for keys.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const c = std.c;
const posix = std.posix;

// ───────────────────────────────────────────── palette (24-bit, dark)

/// 0xRRGGBB, or DEF for the terminal's own colour.
const Col = u32;
const DEF: Col = 0xFF000000;
const P = struct {
    const def: Col = DEF;
    const fg: Col = 0xc9d1d9;
    const bright: Col = 0xf0f6fc;
    const dim: Col = 0x8b949e;
    const faint: Col = 0x545d68;
    const rule: Col = 0x30363d;
    const accent: Col = 0x5af78e;
    const visual: Col = 0xd2a8ff;
    const kw: Col = 0xff7b72;
    const str: Col = 0xa5d6ff;
    const num: Col = 0x79c0ff;
    const com: Col = 0x6e7681;
    const func: Col = 0xd2a8ff;
    const typ: Col = 0xffa657;
    const punct: Col = 0x9da5ae;
    const dir: Col = 0x79c0ff;
    const cursor: Col = 0x161b22;
    const sel: Col = 0x1c2a3f;
    const add_bg: Col = 0x0f2418;
    const add_emph: Col = 0x1f5530;
    const add_fg: Col = 0x3fb950;
    const add_num: Col = 0x3a7d4f;
    const del_bg: Col = 0x2a1215;
    const del_emph: Col = 0x692227;
    const del_fg: Col = 0xf85149;
    const del_num: Col = 0x8e3b3b;
    const hunk: Col = 0x6e7681;
    const note: Col = 0xe3b341;
};

fn statusCol(s: u8) Col {
    return switch (s) {
        'A' => 0x3fb950,
        'D' => 0xf85149,
        'R' => 0xa371f7,
        else => 0xd29922,
    };
}

/// Nearest xterm-256 colour, for terminals without truecolor.
fn to256(col: Col) u8 {
    const r = (col >> 16) & 0xff;
    const g = (col >> 8) & 0xff;
    const b = col & 0xff;
    if (r == g and g == b) {
        if (r < 8) return 16;
        if (r > 248) return 231;
        return @intCast(232 + (r - 8) * 24 / 247);
    }
    const q = struct {
        fn f(v: u32) u32 {
            return if (v < 48) 0 else if (v < 115) 1 else (v - 35) / 40;
        }
    }.f;
    return @intCast(16 + 36 * q(r) + 6 * q(g) + q(b));
}

const BOLD: u8 = 1;
const ITAL: u8 = 2;
const UNDER: u8 = 4;
const REV: u8 = 8;
const DIM: u8 = 16;
const STRIKE: u8 = 32;
/// Colors with this tag are terminal palette indices (low byte), not RGB.
const PAL: Col = 0xFE000000;

// ───────────────────────────────────────────── agents

/// A coding agent kibitz can sit next to. All of them run `! cmd` as a shell
/// command and submit on Enter; they differ in name, color and how fast they
/// can take a typed line before Enter counts as a submit.
const Agent = struct {
    key: []const u8,
    name: []const u8,
    color: Col,
    /// Process names that identify the agent in kibitz's ancestry.
    procs: []const []const u8,
    /// Pause between typing the message and pressing Enter.
    submit_ms: u32 = 150,
};

const agents = [_]Agent{
    .{ .key = "claude", .name = "Claude", .color = 0xd97757, .procs = &.{"claude"} },
    // Codex treats keys that arrive in a burst as a paste, Enter included
    .{ .key = "codex", .name = "Codex", .color = 0x9ad0c2, .procs = &.{"codex"}, .submit_ms = 400 },
    .{ .key = "pi", .name = "Pi", .color = 0xc4a7e7, .procs = &.{"pi"} },
    .{ .key = "agy", .name = "Antigravity", .color = 0x7aa2f7, .procs = &.{ "agy", "antigravity" } },
};

const generic_agent = Agent{ .key = "agent", .name = "the agent", .color = 0xa9b1d6, .procs = &.{} };

fn agentByKey(key: []const u8) ?*const Agent {
    for (&agents) |*a| {
        if (std.ascii.eqlIgnoreCase(a.key, key) or std.ascii.eqlIgnoreCase(a.name, key)) return a;
        for (a.procs) |pn| if (mem.eql(u8, pn, key)) return a;
    }
    return null;
}

/// Which agent a `ps` command line belongs to. Node-based agents show up as
/// `node /path/to/pi`, so the script name is checked too.
fn agentOfCommand(cmdline: []const u8) ?*const Agent {
    var it = mem.tokenizeScalar(u8, cmdline, ' ');
    for (0..2) |_| {
        const tok = it.next() orelse return null;
        const base = tok[if (mem.lastIndexOfScalar(u8, tok, '/')) |i| i + 1 else 0..];
        for (&agents) |*a| for (a.procs) |pn| if (mem.eql(u8, base, pn)) return a;
        if (!mem.eql(u8, base, "node") and !mem.eql(u8, base, "bun")) return null;
    }
    return null;
}

const help_sections = [_]struct { title: []const u8, keys: []const [2][]const u8 }{
    .{ .title = "Move", .keys = &.{
        .{ "j k", "down / up  (counts work: 10j)" }, .{ "^d ^u  ^f ^b", "half page / page" },
        .{ "gg G", "top / bottom" },                 .{ "{ }", "prev / next hunk" },
        .{ "H L", "scroll sideways" },               .{ "/  n N", "search, next / prev" },
    } },
    .{ .title = "Diff", .keys = &.{
        .{ "J K  Tab", "next / prev file" }, .{ "Enter", "open file in the browser at this line" },
        .{ "s", "toggle file list" },
    } },
    .{ .title = "Files", .keys = &.{
        .{ "h l  ← →", "tree ⇄ file, collapse / expand" },
        .{ "Enter", "open file or folder" },
        .{ "J K  ] [", "next / prev changed file" },
    } },
    .{ .title = "Review", .keys = &.{
        .{ "c", "comment on line or visual selection" }, .{ "v", "visual select" },
        .{ "x", "delete comment" },                      .{ "S", "send all comments to the agent" },
    } },
    .{ .title = "Agent", .keys = &.{
        .{ "t", "talk to the agent about this line" }, .{ "i", "type to the agent" },
        .{ "^space", "jump between diff and agent" },  .{ "C  esc", "show / hide the agent panel" },
    } },
    .{ .title = "Other", .keys = &.{
        .{ "f", "switch diff ⇄ files" },
        .{ "e", "open in $EDITOR" },
        .{ "r", "reload" },
        .{ "z", "zoom pane" },
        .{ "q", "quit" },
    } },
};

// ───────────────────────────────────────────── low-level terminal

fn writeAll(fd: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    writeAll(2, std.fmt.bufPrint(&buf, fmt, args) catch fmt);
}

fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    writeAll(1, std.fmt.bufPrint(&buf, fmt, args) catch fmt);
}

var orig_termios: ?posix.termios = null;

fn enterRaw() void {
    const t0 = posix.tcgetattr(0) catch return;
    if (orig_termios == null) orig_termios = t0;
    var t = t0;
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.iflag.IXON = false;
    t.iflag.ICRNL = false;
    t.iflag.BRKINT = false;
    t.iflag.INPCK = false;
    t.iflag.ISTRIP = false;
    t.cc[@backingInt(c.V.MIN)] = 0;
    t.cc[@backingInt(c.V.TIME)] = 0;
    posix.tcsetattr(0, .FLUSH, t) catch {};
    writeAll(1, "\x1b[?1049h\x1b[?25l\x1b[?1004h");
}

fn leaveRaw() void {
    writeAll(1, "\x1b[0m\x1b[?25h\x1b[?1004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?1l\x1b[=0;1u\x1b[>4;0m\x1b[?1049l");
    if (orig_termios) |t| posix.tcsetattr(0, .FLUSH, t) catch {};
}

fn termSize() [2]usize {
    var ws: posix.winsize = undefined;
    if (c.ioctl(1, c.T.IOCGWINSZ, &ws) == 0 and ws.col > 0 and ws.row > 0) return .{ ws.col, ws.row };
    return .{ 80, 24 };
}

const Decoded = struct { cp: u21, len: usize };

fn decode(s: []const u8) Decoded {
    const b = s[0];
    if (b < 0x80) return .{ .cp = if (b < 0x20 or b == 0x7f) '?' else b, .len = 1 };
    const n: usize = if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 0;
    if (n == 0 or n > s.len) return .{ .cp = 0xFFFD, .len = 1 };
    var cp: u32 = @as(u32, b) & (@as(u32, 0x7F) >> @intCast(n));
    for (s[1..n]) |cb| {
        if (cb & 0xC0 != 0x80) return .{ .cp = 0xFFFD, .len = 1 };
        cp = (cp << 6) | (cb & 0x3F);
    }
    if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return .{ .cp = 0xFFFD, .len = n };
    return .{ .cp = @intCast(cp), .len = n };
}

fn cpLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Byte offset of the codepoint `n` codepoints from the end (for left-truncation).
fn tailCp(s: []const u8, n: usize) []const u8 {
    const total = cpLen(s);
    if (total <= n) return s;
    var skip = total - n;
    var i: usize = 0;
    while (i < s.len and skip > 0) {
        i += 1;
        while (i < s.len and s[i] & 0xC0 == 0x80) i += 1;
        skip -= 1;
    }
    return s[i..];
}

// ───────────────────────────────────────────── screen (double-buffered cells)

const Cell = extern struct { ch: u32 = ' ', fg: Col = DEF, bg: Col = DEF, at: u8 = 0, pad: [3]u8 = .{ 0, 0, 0 } };

const Screen = struct {
    gpa: Allocator,
    w: usize = 0,
    h: usize = 0,
    cells: []Cell = &.{},
    prev: []Cell = &.{},
    out: std.ArrayList(u8) = .empty,
    force: bool = true,
    truecolor: bool = true,

    fn resize(s: *Screen, w: usize, h: usize) !void {
        if (w == s.w and h == s.h) return;
        s.gpa.free(s.cells);
        s.gpa.free(s.prev);
        s.cells = try s.gpa.alloc(Cell, w * h);
        s.prev = try s.gpa.alloc(Cell, w * h);
        s.w = w;
        s.h = h;
        s.force = true;
    }

    fn clear(s: *Screen) void {
        @memset(s.cells, .{});
    }

    fn set(s: *Screen, y: usize, x: usize, cp: u21, fg: Col, bg: Col, at: u8) void {
        if (y >= s.h or x >= s.w) return;
        s.cells[y * s.w + x] = .{ .ch = cp, .fg = fg, .bg = bg, .at = at };
    }

    fn putMax(s: *Screen, y: usize, x: usize, text: []const u8, fg: Col, bg: Col, at: u8, maxw: usize) usize {
        if (y >= s.h) return x;
        var cx = x;
        var i: usize = 0;
        var n: usize = 0;
        while (i < text.len and cx < s.w and n < maxw) {
            const d = decode(text[i..]);
            i += d.len;
            s.cells[y * s.w + cx] = .{ .ch = d.cp, .fg = fg, .bg = bg, .at = at };
            cx += 1;
            n += 1;
        }
        return cx;
    }

    fn put(s: *Screen, y: usize, x: usize, text: []const u8, fg: Col, bg: Col, at: u8) usize {
        return s.putMax(y, x, text, fg, bg, at, std.math.maxInt(usize));
    }

    fn fill(s: *Screen, y: usize, x: usize, n: usize, fg: Col, bg: Col) void {
        if (y >= s.h) return;
        var i = x;
        while (i < x + n and i < s.w) : (i += 1) s.cells[y * s.w + i] = .{ .fg = fg, .bg = bg };
    }

    fn sgrColor(s: *Screen, base: u8, col: Col) !void {
        if (col == DEF) return;
        if (col & 0xFF000000 == PAL) return s.out.print(s.gpa, ";{d};5;{d}", .{ base, col & 0xff });
        if (s.truecolor) {
            try s.out.print(s.gpa, ";{d};2;{d};{d};{d}", .{ base, (col >> 16) & 0xff, (col >> 8) & 0xff, col & 0xff });
        } else {
            try s.out.print(s.gpa, ";{d};5;{d}", .{ base, to256(col) });
        }
    }

    fn flush(s: *Screen, cursor: ?[2]usize) void {
        const g = s.gpa;
        s.out.clearRetainingCapacity();
        s.out.appendSlice(g, "\x1b[?2026h\x1b[?25l") catch return;
        var y: usize = 0;
        while (y < s.h) : (y += 1) {
            const row = s.cells[y * s.w ..][0..s.w];
            const prow = s.prev[y * s.w ..][0..s.w];
            if (!s.force and mem.eql(u8, mem.sliceAsBytes(row), mem.sliceAsBytes(prow))) continue;
            s.out.print(g, "\x1b[{d};1H", .{y + 1}) catch return;
            var cf: Col = 0xFD000000;
            var cb: Col = 0xFD000000;
            var ca: u8 = 255;
            for (row) |cell| {
                if (cell.ch == WIDE_CONT) continue;
                if (cell.fg != cf or cell.bg != cb or cell.at != ca) {
                    s.out.appendSlice(g, "\x1b[0") catch return;
                    s.sgrColor(38, cell.fg) catch return;
                    s.sgrColor(48, cell.bg) catch return;
                    if (cell.at & BOLD != 0) s.out.appendSlice(g, ";1") catch return;
                    if (cell.at & ITAL != 0) s.out.appendSlice(g, ";3") catch return;
                    if (cell.at & DIM != 0) s.out.appendSlice(g, ";2") catch return;
                    if (cell.at & UNDER != 0) s.out.appendSlice(g, ";4") catch return;
                    if (cell.at & REV != 0) s.out.appendSlice(g, ";7") catch return;
                    if (cell.at & STRIKE != 0) s.out.appendSlice(g, ";9") catch return;
                    s.out.append(g, 'm') catch return;
                    cf = cell.fg;
                    cb = cell.bg;
                    ca = cell.at;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cell.ch), &buf) catch blk: {
                    buf[0] = '?';
                    break :blk 1;
                };
                s.out.appendSlice(g, buf[0..n]) catch return;
            }
        }
        s.out.appendSlice(g, "\x1b[0m") catch return;
        if (cursor) |cu| s.out.print(g, "\x1b[{d};{d}H\x1b[?25h", .{ cu[0] + 1, cu[1] + 1 }) catch return;
        s.out.appendSlice(g, "\x1b[?2026l") catch return;
        writeAll(1, s.out.items);
        @memcpy(s.prev, s.cells);
        s.force = false;
    }
};

// ───────────────────────────────────────────── keyboard

const KEY_UP: u32 = 0x110001;
const KEY_DOWN: u32 = 0x110002;
const KEY_LEFT: u32 = 0x110003;
const KEY_RIGHT: u32 = 0x110004;
const KEY_PGUP: u32 = 0x110005;
const KEY_PGDN: u32 = 0x110006;
const KEY_HOME: u32 = 0x110007;
const KEY_END: u32 = 0x110008;
const KEY_BTAB: u32 = 0x110009;
const KEY_DEL: u32 = 0x11000A;
/// The terminal reports that this pane got focus back (mode 1004).
const KEY_FOCUS: u32 = 0x11000B;
/// SGR mouse report; details in Input.mouse.
const KEY_MOUSE: u32 = 0x11000C;
/// Ctrl+Space, which terminals send as a NUL byte.
const KEY_CSPACE: u32 = 0x11000D;
const KEY_ESC: u32 = 27;
const KEY_ENTER: u32 = 13;
const KEY_TAB: u32 = 9;

fn ctrl(ch: u8) u32 {
    return ch & 0x1f;
}

const Mouse = struct { b: u32 = 0, x: usize = 0, y: usize = 0, press: bool = false };

const Input = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    mouse: Mouse = .{},

    fn waitData(timeout_ms: i32) bool {
        var fds = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, timeout_ms) catch return false;
        return n > 0;
    }

    fn readMore(self: *Input) void {
        if (self.len >= self.buf.len) return;
        const n = posix.read(0, self.buf[self.len..]) catch return;
        self.len += n;
    }

    fn consume(self: *Input, n: usize) void {
        mem.copyForwards(u8, self.buf[0..], self.buf[n..self.len]);
        self.len -= n;
    }

    /// Next key, or null on timeout. 0 means "unknown key, ignore".
    fn next(self: *Input, timeout_ms: i32) ?u32 {
        if (self.len == 0) {
            if (!waitData(timeout_ms)) return null;
            self.readMore();
            if (self.len == 0) return null;
        }
        const b = self.buf[0];
        if (b == 27) {
            if (self.len == 1 and waitData(30)) self.readMore();
            if (self.len == 1) {
                self.consume(1);
                return KEY_ESC;
            }
            if (self.buf[1] == '[' or self.buf[1] == 'O') {
                var i: usize = 2;
                while (i < self.len and !(self.buf[i] >= 0x40 and self.buf[i] <= 0x7e)) i += 1;
                if (i >= self.len) {
                    self.consume(self.len);
                    return KEY_ESC;
                }
                const final = self.buf[i];
                var pbuf: [16]u8 = undefined;
                const plen = @min(i - 2, pbuf.len);
                @memcpy(pbuf[0..plen], self.buf[2..][0..plen]);
                const params = pbuf[0..plen];
                self.consume(i + 1);
                if (params.len > 0 and params[0] == '<' and (final == 'M' or final == 'm')) {
                    const ps = params[1..];
                    self.mouse = .{ .b = csiNum(ps, 0, 0), .x = csiNum(ps, 1, 1) -| 1, .y = csiNum(ps, 2, 1) -| 1, .press = final == 'M' };
                    return KEY_MOUSE;
                }
                return switch (final) {
                    'A' => KEY_UP,
                    'B' => KEY_DOWN,
                    'C' => KEY_RIGHT,
                    'D' => KEY_LEFT,
                    'H' => KEY_HOME,
                    'F' => KEY_END,
                    'Z' => KEY_BTAB,
                    'I' => if (params.len == 0) KEY_FOCUS else 0,
                    '~' => if (mem.eql(u8, params, "5")) KEY_PGUP else if (mem.eql(u8, params, "6")) KEY_PGDN else if (mem.eql(u8, params, "3")) KEY_DEL else if (mem.eql(u8, params, "1") or mem.eql(u8, params, "7")) KEY_HOME else if (mem.eql(u8, params, "4") or mem.eql(u8, params, "8")) KEY_END else 0,
                    else => 0,
                };
            }
            self.consume(1);
            return KEY_ESC;
        }
        if (b >= 0x80) {
            const need: usize = if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 1;
            if (self.len < need and waitData(30)) self.readMore();
            if (self.len < need) {
                self.consume(self.len);
                return 0;
            }
            const d = decode(self.buf[0..need]);
            self.consume(need);
            return d.cp;
        }
        self.consume(1);
        return if (b == 0) KEY_CSPACE else b;
    }
};

// ───────────────────────────────────────────── agent mirror
//
// The agent keeps running in its own Rex pane. kibitz reads that pane's screen
// (`format` in vt form), draws it in a panel, and writes your keystrokes back
// to it, so the agent looks and behaves exactly as it does on its own.

/// Placeholder for the right half of a double-width character.
const WIDE_CONT: u32 = 0;

/// Display width of a codepoint: 0 for combining marks, 2 for wide CJK/emoji.
fn cpWidth(cp: u21) u2 {
    if ((cp >= 0x300 and cp <= 0x36F) or (cp >= 0x200B and cp <= 0x200F) or (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0x20E3) return 0;
    if ((cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F680 and cp <= 0x1F6FF) or (cp >= 0x1F900 and cp <= 0x1F9FF) or (cp >= 0x20000 and cp <= 0x3FFFD)) return 2;
    return 1;
}

/// Input modes the agent asked its terminal for; kibitz turns the same ones on
/// while you type into the panel so keys arrive exactly as the agent expects.
const Modes = struct {
    kitty: u8 = 0,
    other_keys: u8 = 0,
    paste: bool = false,
    app_cursor: bool = false,
    /// 0 off, 1 clicks (1000), 2 drags (1002), 3 all motion (1003)
    mouse: u2 = 0,
    focus: bool = false,
    cursor: bool = true,
};

const Mirror = struct {
    cols: usize = 0,
    rows: usize = 0,
    cells: []Cell = &.{},
    cursor: ?[2]usize = null,
    modes: Modes = .{},
};

fn csiNum(params: []const u8, idx: usize, default: u32) u32 {
    var it = mem.splitAny(u8, params, ";");
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (i != idx) continue;
        const main_part = p[0 .. mem.indexOfScalar(u8, p, ':') orelse p.len];
        return std.fmt.parseInt(u32, main_part, 10) catch default;
    }
    return default;
}

fn applyPrivateMode(m: *Modes, params: []const u8, on: bool) void {
    var it = mem.splitScalar(u8, params, ';');
    while (it.next()) |p| {
        const n = std.fmt.parseInt(u32, p, 10) catch continue;
        switch (n) {
            1 => m.app_cursor = on,
            25 => m.cursor = on,
            1000 => m.mouse = if (on) @max(m.mouse, 1) else 0,
            1002 => m.mouse = if (on) @max(m.mouse, 2) else @min(m.mouse, 1),
            1003 => m.mouse = if (on) 3 else @min(m.mouse, 2),
            1004 => m.focus = on,
            2004 => m.paste = on,
            else => {},
        }
    }
}

const Pen = struct { fg: Col = DEF, bg: Col = DEF, at: u8 = 0 };

fn sgrApply(pen: *Pen, params: []const u8) void {
    if (params.len == 0) {
        pen.* = .{};
        return;
    }
    var vals: [32]u32 = undefined;
    var n: usize = 0;
    var it = mem.splitScalar(u8, params, ';');
    while (it.next()) |p| {
        if (n == vals.len) break;
        // colon sub-parameters (4:3, 38:2::r:g:b) — keep the leading number only
        const head = p[0 .. mem.indexOfScalar(u8, p, ':') orelse p.len];
        vals[n] = std.fmt.parseInt(u32, head, 10) catch 0;
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = vals[i];
        switch (v) {
            0 => pen.* = .{},
            1 => pen.at |= BOLD,
            2 => pen.at |= DIM,
            3 => pen.at |= ITAL,
            4 => pen.at |= UNDER,
            7 => pen.at |= REV,
            9 => pen.at |= STRIKE,
            21, 22 => pen.at &= ~(BOLD | DIM),
            23 => pen.at &= ~ITAL,
            24 => pen.at &= ~UNDER,
            27 => pen.at &= ~REV,
            29 => pen.at &= ~STRIKE,
            30...37 => pen.fg = PAL | (v - 30),
            90...97 => pen.fg = PAL | (v - 90 + 8),
            40...47 => pen.bg = PAL | (v - 40),
            100...107 => pen.bg = PAL | (v - 100 + 8),
            39 => pen.fg = DEF,
            49 => pen.bg = DEF,
            38, 48, 58 => {
                var col: ?Col = null;
                if (i + 1 < n and vals[i + 1] == 5 and i + 2 < n) {
                    col = PAL | (vals[i + 2] & 0xff);
                    i += 2;
                } else if (i + 1 < n and vals[i + 1] == 2 and i + 4 < n) {
                    col = ((vals[i + 2] & 0xff) << 16) | ((vals[i + 3] & 0xff) << 8) | (vals[i + 4] & 0xff);
                    i += 4;
                }
                if (col) |c2| {
                    if (v == 38) pen.fg = c2 else if (v == 48) pen.bg = c2;
                }
            },
            else => {},
        }
    }
}

/// Mode switches at the very start of a capture (before the first line).
fn parseLeadModes(head: []const u8, m: *Modes) void {
    var i: usize = 0;
    while (i + 2 < head.len and head[i] == 0x1b and head[i + 1] == '[') {
        var j = i + 2;
        while (j < head.len and !(head[j] >= 0x40 and head[j] <= 0x7e)) j += 1;
        if (j >= head.len) return;
        const params = head[i + 2 .. j];
        if (params.len > 0 and params[0] == '?' and (head[j] == 'h' or head[j] == 'l')) applyPrivateMode(m, params[1..], head[j] == 'h');
        i = j + 1;
    }
}

/// Build the agent's screen from a vt capture. `body` is the whole capture or
/// its tail (`cut` = the first line may be partial). The screen is the last
/// `rows` lines; the trailing escapes carry the cursor and keyboard modes.
fn parseScreen(gpa: Allocator, body: []const u8, cut: bool, cols: usize, rows: usize, m: *Mirror) !void {
    m.cols = cols;
    m.rows = rows;
    m.cells = try gpa.alloc(Cell, cols * rows);
    @memset(m.cells, .{});
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = mem.splitSequence(u8, body, "\r\n");
    if (cut) _ = it.next();
    while (it.next()) |l| try lines.append(gpa, l);
    const first = lines.items.len -| rows;
    for (lines.items[first..], 0..) |line, r| {
        var pen: Pen = .{};
        var x: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            const b = line[i];
            if (b == 0x1b and i + 1 < line.len) {
                if (line[i + 1] == '[') {
                    var j = i + 2;
                    while (j < line.len and !(line[j] >= 0x40 and line[j] <= 0x7e)) j += 1;
                    if (j >= line.len) break;
                    const raw = line[i + 2 .. j];
                    const lead: u8 = if (raw.len > 0 and (raw[0] == '?' or raw[0] == '>' or raw[0] == '=' or raw[0] == '<')) raw[0] else 0;
                    const params = if (lead != 0) raw[1..] else raw;
                    switch (line[j]) {
                        'm' => if (lead == 0) sgrApply(&pen, params) else if (lead == '>' and csiNum(params, 0, 0) == 4) {
                            m.modes.other_keys = @intCast(@min(csiNum(params, 1, 0), 3));
                        },
                        'C' => if (lead == 0) {
                            x += @max(1, csiNum(params, 0, 1));
                        },
                        'H' => if (lead == 0) {
                            m.cursor = .{ csiNum(params, 0, 1) -| 1, csiNum(params, 1, 1) -| 1 };
                        },
                        'h', 'l' => if (lead == '?') applyPrivateMode(&m.modes, params, line[j] == 'h'),
                        'u' => if (lead == '=') {
                            m.modes.kitty = @intCast(csiNum(params, 0, 0) & 0x1f);
                        },
                        else => {},
                    }
                    i = j + 1;
                } else if (line[i + 1] == ']') {
                    // OSC (hyperlinks, titles): skip to BEL or ST
                    var j = i + 2;
                    while (j < line.len and line[j] != 7 and !(line[j] == 0x1b and j + 1 < line.len and line[j + 1] == '\\')) j += 1;
                    i = if (j < line.len and line[j] == 7) j + 1 else j + 2;
                } else i += 2;
                continue;
            }
            if (b < 0x20 or b == 0x7f) {
                if (b == '\r') x = 0;
                i += 1;
                continue;
            }
            const d = decode(line[i..]);
            i += d.len;
            const cw = cpWidth(d.cp);
            if (cw == 0) continue;
            if (x + cw <= cols) {
                m.cells[r * cols + x] = .{ .ch = d.cp, .fg = pen.fg, .bg = pen.bg, .at = pen.at };
                if (cw == 2) m.cells[r * cols + x + 1] = .{ .ch = WIDE_CONT, .fg = pen.fg, .bg = pen.bg, .at = pen.at };
            }
            x += cw;
        }
    }
    if (!m.modes.cursor) m.cursor = null;
}

/// JSON string body for `write`, escaping what JSON needs. Input must be UTF-8.
fn jsonEscape(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    for (bytes) |b| switch (b) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        0...0x1f, 0x7f => try out.print(gpa, "\\u{x:0>4}", .{b}),
        else => try out.append(gpa, b),
    };
}

/// Is this CSI sequence the panel switch key (ctrl+space, or ctrl+] as a
/// fallback) in kitty or modifyOtherKeys encoding?
fn isSwitchKey(params: []const u8, final: u8) bool {
    const key, const mods = switch (final) {
        'u' => .{ csiNum(params, 0, 0), csiNum(params, 1, 1) },
        '~' => if (csiNum(params, 0, 0) == 27) .{ csiNum(params, 2, 0), csiNum(params, 1, 1) } else return false,
        else => return false,
    };
    return (key == ' ' or key == ']') and (mods -| 1) & 0b100 != 0;
}

// ───────────────────────────────────────────── diff model

const NONE = std.math.maxInt(u32);
const Kind = enum(u8) { hunk, add, del, ctx, meta };
const Line = struct { kind: Kind, text: []const u8, old: u32 = 0, new: u32 = 0, pair: u32 = NONE };
const Span = struct { s: u32, e: u32 };

const FileDiff = struct {
    path: []const u8,
    old_path: []const u8,
    status: u8 = 'M',
    adds: u32 = 0,
    dels: u32 = 0,
    lines: std.ArrayList(Line) = .empty,
    emph: std.AutoHashMapUnmanaged(u32, []Span) = .empty,
};

/// Expand tabs, drop CRs, neutralise control bytes. Returns `s` itself when clean.
fn cleanText(a: Allocator, s: []const u8) ![]const u8 {
    var dirty = false;
    for (s) |b| {
        if (b < 0x20 or b == 0x7f) {
            dirty = true;
            break;
        }
    }
    if (!dirty) return s;
    var out: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    for (s) |b| {
        if (b == '\t') {
            const n = 4 - (col % 4);
            try out.appendNTimes(a, ' ', n);
            col += n;
        } else if (b == '\r') {
            continue;
        } else if (b < 0x20 or b == 0x7f) {
            try out.append(a, '?');
            col += 1;
        } else {
            try out.append(a, b);
            if (b & 0xC0 != 0x80) col += 1;
        }
    }
    return out.items;
}

fn parseNum(s: []const u8, i: *usize) u32 {
    var n: u32 = 0;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') : (i.* += 1) n = n *% 10 +% (s[i.*] - '0');
    return n;
}

fn parseDiff(a: Allocator, text: []const u8) ![]FileDiff {
    var files: std.ArrayList(FileDiff) = .empty;
    var it = mem.splitScalar(u8, text, '\n');
    var in_header = false;
    var o: u32 = 0;
    var n: u32 = 0;
    while (it.next()) |line| {
        if (mem.startsWith(u8, line, "diff --git ")) {
            const rest = line[11..];
            var pa: []const u8 = rest;
            var pb: []const u8 = rest;
            if (mem.lastIndexOf(u8, rest, " b/")) |i| {
                pa = rest[0..i];
                pb = rest[i + 3 ..];
            }
            if (mem.startsWith(u8, pa, "a/")) pa = pa[2..];
            try files.append(a, .{ .path = pb, .old_path = pa });
            in_header = true;
            continue;
        }
        if (files.items.len == 0) continue;
        const f = &files.items[files.items.len - 1];
        if (in_header and !mem.startsWith(u8, line, "@@")) {
            if (mem.startsWith(u8, line, "new file")) {
                f.status = 'A';
            } else if (mem.startsWith(u8, line, "deleted file")) {
                f.status = 'D';
            } else if (mem.startsWith(u8, line, "rename from ")) {
                f.old_path = line[12..];
                f.status = 'R';
            } else if (mem.startsWith(u8, line, "rename to ")) {
                f.path = line[10..];
            } else if (mem.startsWith(u8, line, "Binary files")) {
                try f.lines.append(a, .{ .kind = .meta, .text = "binary file" });
            } else if (mem.startsWith(u8, line, "+++ ") and !mem.eql(u8, line[4..], "/dev/null")) {
                f.path = if (mem.startsWith(u8, line, "+++ b/")) line[6..] else line[4..];
            }
            continue;
        }
        in_header = false;
        if (mem.startsWith(u8, line, "@@")) {
            var i: usize = 0;
            while (i < line.len and line[i] != '-') i += 1;
            i += 1;
            o = parseNum(line, &i);
            while (i < line.len and line[i] != '+') i += 1;
            i += 1;
            n = parseNum(line, &i);
            var ctx: []const u8 = "";
            if (mem.indexOfPos(u8, line, 2, "@@")) |j| {
                var k = j;
                while (k < line.len and line[k] == '@') k += 1;
                ctx = mem.trimStart(u8, line[k..], " ");
            }
            try f.lines.append(a, .{ .kind = .hunk, .text = try cleanText(a, ctx), .old = o, .new = n });
        } else if (line.len > 0 and line[0] == '+') {
            try f.lines.append(a, .{ .kind = .add, .text = try cleanText(a, line[1..]), .new = n });
            n += 1;
            f.adds += 1;
        } else if (line.len > 0 and line[0] == '-') {
            try f.lines.append(a, .{ .kind = .del, .text = try cleanText(a, line[1..]), .old = o });
            o += 1;
            f.dels += 1;
        } else if (line.len > 0 and line[0] == ' ') {
            try f.lines.append(a, .{ .kind = .ctx, .text = try cleanText(a, line[1..]), .old = o, .new = n });
            o += 1;
            n += 1;
        } else if (line.len > 1 and line[0] == '\\') {
            try f.lines.append(a, .{ .kind = .meta, .text = line[2..] });
        }
    }
    // pair each run of -lines with the +lines that follow, for word-level highlight
    for (files.items) |*f| {
        const L = f.lines.items;
        var i: usize = 0;
        while (i < L.len) {
            if (L[i].kind != .del) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < L.len and L[j].kind == .del) j += 1;
            var k = j;
            while (k < L.len and L[k].kind == .add) k += 1;
            var d = i;
            var p = j;
            while (d < j and p < k) : ({
                d += 1;
                p += 1;
            }) {
                L[d].pair = @intCast(p);
                L[p].pair = @intCast(d);
            }
            i = @max(k, i + 1);
        }
    }
    return files.items;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

fn tokenize(a: Allocator, s: []const u8) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const st = i;
        if (isWordByte(s[i])) {
            while (i < s.len and isWordByte(s[i])) i += 1;
        } else if (s[i] == ' ') {
            while (i < s.len and s[i] == ' ') i += 1;
        } else {
            i += 1;
        }
        try out.append(a, .{ .s = @intCast(st), .e = @intCast(i) });
    }
    return out.items;
}

/// Token-level LCS between a removed and an added line; returns the changed spans.
fn computeEmph(a: Allocator, gpa: Allocator, s1: []const u8, s2: []const u8) !?[2][]Span {
    const t1 = try tokenize(a, s1);
    const t2 = try tokenize(a, s2);
    if (t1.len == 0 or t2.len == 0 or t1.len > 300 or t2.len > 300) return null;
    const W = t2.len + 1;
    const dp = try gpa.alloc(u16, (t1.len + 1) * W);
    defer gpa.free(dp);
    @memset(dp, 0);
    var i: usize = t1.len;
    while (i > 0) {
        i -= 1;
        var j: usize = t2.len;
        while (j > 0) {
            j -= 1;
            const eq = mem.eql(u8, s1[t1[i].s..t1[i].e], s2[t2[j].s..t2[j].e]);
            dp[i * W + j] = if (eq) dp[(i + 1) * W + j + 1] + 1 else @max(dp[(i + 1) * W + j], dp[i * W + j + 1]);
        }
    }
    const lcs = dp[0];
    if (@as(f32, @floatFromInt(2 * @as(u32, lcs))) / @as(f32, @floatFromInt(t1.len + t2.len)) < 0.4) return null;
    const m1 = try gpa.alloc(bool, t1.len);
    defer gpa.free(m1);
    const m2 = try gpa.alloc(bool, t2.len);
    defer gpa.free(m2);
    @memset(m1, false);
    @memset(m2, false);
    i = 0;
    var j: usize = 0;
    while (i < t1.len and j < t2.len) {
        if (mem.eql(u8, s1[t1[i].s..t1[i].e], s2[t2[j].s..t2[j].e])) {
            m1[i] = true;
            m2[j] = true;
            i += 1;
            j += 1;
        } else if (dp[(i + 1) * W + j] >= dp[i * W + j + 1]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    return .{ try mergeUnmatched(a, t1, m1), try mergeUnmatched(a, t2, m2) };
}

fn mergeUnmatched(a: Allocator, toks: []const Span, matched: []const bool) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    for (toks, 0..) |t, k| {
        if (matched[k]) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1].e == t.s) {
            out.items[out.items.len - 1].e = t.e;
        } else {
            try out.append(a, t);
        }
    }
    return out.items;
}

// ───────────────────────────────────────────── syntax highlighting

const Style = enum { none, hash, slash, dash };
const HKind = enum(u8) { kw, str, num, com, func, typ, punct };
const HSpan = struct { s: u32, e: u32, k: HKind };

const keywords = [_][]const u8{
    "and",      "as",       "assert",     "async",     "await",    "break",      "case",      "catch",       "class",
    "const",    "continue", "crate",      "def",       "default",  "defer",      "del",       "delete",      "do",
    "elif",     "else",     "enum",       "except",    "export",   "extends",    "extern",    "false",       "False",
    "final",    "finally",  "fn",         "for",       "from",     "func",       "function",  "go",          "goto",
    "if",       "impl",     "implements", "import",    "in",       "instanceof", "interface", "is",          "lambda",
    "let",      "loop",     "match",      "mod",       "module",   "mut",        "new",       "nil",         "None",
    "nonlocal", "not",      "null",       "or",        "package",  "pass",       "private",   "protected",   "pub",
    "public",   "raise",    "readonly",   "return",    "self",     "Self",       "static",    "struct",      "super",
    "switch",   "this",     "throw",      "throws",    "trait",    "true",       "True",      "try",         "type",
    "typeof",   "unsafe",   "use",        "var",       "void",     "where",      "while",     "with",        "yield",
    "pub",      "comptime", "orelse",     "undefined", "errdefer", "inline",     "usize",     "unreachable",
};

fn isKeyword(w: []const u8) bool {
    for (keywords) |k| if (mem.eql(u8, k, w)) return true;
    return false;
}

fn langStyle(path: []const u8) Style {
    const base = if (mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    var lower_buf: [64]u8 = undefined;
    const ext_raw = if (mem.lastIndexOfScalar(u8, base, '.')) |i| base[i + 1 ..] else base;
    if (ext_raw.len > lower_buf.len) return .slash;
    const ext = std.ascii.lowerString(&lower_buf, ext_raw);
    const plain = [_][]const u8{ "md", "markdown", "txt", "rst", "csv", "tsv", "log", "lock", "svg", "xml", "html" };
    const hash = [_][]const u8{ "py", "sh", "bash", "zsh", "fish", "rb", "yaml", "yml", "toml", "pl", "r", "conf", "ini", "cfg", "mk", "makefile", "dockerfile", "cmake", "nix", "ex", "exs", "tf", "gitignore", "env", "ps1", "jl", "nim", "cr", "pyi" };
    const dash = [_][]const u8{ "sql", "lua", "hs", "elm" };
    for (plain) |e| if (mem.eql(u8, e, ext)) return .none;
    for (hash) |e| if (mem.eql(u8, e, ext)) return .hash;
    for (dash) |e| if (mem.eql(u8, e, ext)) return .dash;
    return .slash;
}

fn isPunct(b: u8) bool {
    return mem.indexOfScalar(u8, "{}()[];,.:=+-*/<>!&|%^~?@", b) != null;
}

/// Tiny language-agnostic highlighter, appends byte spans to `out`.
fn highlight(gpa: Allocator, text: []const u8, style: Style, out: *std.ArrayList(HSpan)) !void {
    if (style == .none) return;
    const s = text;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        const st = i;
        const is_com = switch (style) {
            .hash => b == '#',
            .slash => b == '/' and i + 1 < s.len and (s[i + 1] == '/' or s[i + 1] == '*'),
            .dash => b == '-' and i + 1 < s.len and s[i + 1] == '-',
            .none => false,
        };
        if (is_com) {
            var e = s.len;
            if (style == .slash and s[i + 1] == '*') {
                if (mem.indexOfPos(u8, s, i + 2, "*/")) |k| e = k + 2;
            }
            try out.append(gpa, .{ .s = @intCast(st), .e = @intCast(e), .k = .com });
            i = e;
        } else if (b == '"' or b == '\'' or b == '`') {
            i += 1;
            while (i < s.len and s[i] != b) : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
            i = @min(i + 1, s.len);
            try out.append(gpa, .{ .s = @intCast(st), .e = @intCast(i), .k = .str });
        } else if (std.ascii.isDigit(b) and (i == 0 or !isWordByte(s[i - 1]))) {
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '.')) i += 1;
            try out.append(gpa, .{ .s = @intCast(st), .e = @intCast(i), .k = .num });
        } else if (std.ascii.isAlphabetic(b) or b == '_' or b == '$') {
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '$')) i += 1;
            const w = s[st..i];
            const k: ?HKind = if (isKeyword(w)) .kw else if (i < s.len and s[i] == '(') .func else if (std.ascii.isUpper(w[0])) .typ else null;
            if (k) |kk| try out.append(gpa, .{ .s = @intCast(st), .e = @intCast(i), .k = kk });
        } else if (isPunct(b)) {
            while (i < s.len and isPunct(s[i])) i += 1;
            try out.append(gpa, .{ .s = @intCast(st), .e = @intCast(i), .k = .punct });
        } else {
            i += 1;
        }
    }
}

fn hcol(k: HKind) Col {
    return switch (k) {
        .kw => P.kw,
        .str => P.str,
        .num => P.num,
        .com => P.com,
        .func => P.func,
        .typ => P.typ,
        .punct => P.punct,
    };
}

// ───────────────────────────────────────────── views, anchors, comments

const RowT = enum(u8) { file, line, comment, gap };
const Row = struct { t: RowT, fi: u32 = 0, idx: u32 = 0 };

const AKind = enum(u8) { file, new, old, hunk, meta, gap };
const Anchor = struct {
    path: []const u8,
    k: AKind,
    a: u32 = 0,
    b: u32 = 0,
    fn eql(x: Anchor, y: Anchor) bool {
        return x.k == y.k and x.a == y.a and x.b == y.b and mem.eql(u8, x.path, y.path);
    }
};

const Comment = struct { anchor: Anchor, loc: []u8, code: []u8, text: []u8, sent: bool = false };

const ViewKind = enum { diff, file };
const View = struct {
    kind: ViewKind,
    rows: std.ArrayList(Row) = .empty,
    cursor: usize = 0,
    top: usize = 0,
    hscroll: usize = 0,
    sel: ?usize = null,

    fn clamp(v: *View) void {
        if (v.rows.items.len == 0) {
            v.cursor = 0;
        } else if (v.cursor >= v.rows.items.len) v.cursor = v.rows.items.len - 1;
    }

    fn ensure(v: *View, h: usize) void {
        const so: usize = @min(3, (h -| 1) / 2);
        if (v.cursor < v.top + so) v.top = v.cursor -| so;
        if (v.cursor + so + 1 > v.top + h) v.top = v.cursor + so + 1 - h;
        const maxtop = v.rows.items.len -| h;
        if (v.top > maxtop) v.top = maxtop;
    }

    fn selection(v: *View) ?[2]usize {
        const a = v.sel orelse return null;
        return .{ @min(a, v.cursor), @max(a, v.cursor) };
    }
};

const Node = struct { name: []const u8, path: []const u8, is_dir: bool, kids: std.ArrayList(u32) = .empty, changed: u32 = 0 };
/// A visible tree row. `mask` bit d is set when the ancestor at depth d was a last child.
const Vis = struct { depth: u16, node: u32, mask: u64 = 0, last: bool = false };

fn lineAnchor(f: *const FileDiff, li: usize) Anchor {
    const l = f.lines.items[li];
    return switch (l.kind) {
        .add, .ctx => .{ .path = f.path, .k = .new, .a = l.new },
        .del => .{ .path = f.path, .k = .old, .a = l.old },
        .hunk => .{ .path = f.path, .k = .hunk, .a = l.old, .b = l.new },
        .meta => .{ .path = f.path, .k = .meta, .a = @intCast(li) },
    };
}

fn splitPath(p: []const u8) [2][]const u8 {
    if (mem.lastIndexOfScalar(u8, p, '/')) |i| return .{ p[0 .. i + 1], p[i + 1 ..] };
    return .{ "", p };
}

fn padNum(buf: []u8, n: u32, w: usize) []const u8 {
    var tmp: [16]u8 = undefined;
    const s = if (n == 0) "" else std.fmt.bufPrint(&tmp, "{d}", .{n}) catch "";
    const pad = if (w > s.len) w - s.len else 0;
    @memset(buf[0..pad], ' ');
    @memcpy(buf[pad..][0..s.len], s);
    return buf[0 .. pad + s.len];
}

fn digits(n: usize) usize {
    var d: usize = 1;
    var x = n;
    while (x >= 10) : (x /= 10) d += 1;
    return d;
}

// ───────────────────────────────────────────── processes

const RunOut = struct { out: []u8, ok: bool };

fn runCmd(gpa: Allocator, io: Io, argv: []const []const u8) ?RunOut {
    const r = std.process.run(gpa, io, .{ .argv = argv }) catch return null;
    gpa.free(r.stderr);
    return .{ .out = r.stdout, .ok = r.term.success() };
}

fn findInPath(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, name: []const u8) ?[]u8 {
    const path = env.get("PATH") orelse return null;
    var it = mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch return null;
        Io.Dir.cwd().access(io, full, .{ .execute = true }) catch {
            gpa.free(full);
            continue;
        };
        return full;
    }
    return null;
}

// ───────────────────────────────────────────── the app

const Mode = enum { diff, files };
const Focus = enum { tree, viewer };

const App = struct {
    gpa: Allocator,
    io: Io,
    revs: []const []const u8,
    target: ?[]const u8,
    session: ?[]const u8,
    own_block: ?[]const u8,
    rex: ?[]const u8,
    zoomed: bool,
    scr: Screen,
    input: Input = .{},
    arena: std.heap.ArenaAllocator,
    raw: []u8 = &.{},
    files: []FileDiff = &.{},
    changed: std.StringHashMapUnmanaged(u32) = .empty,
    diff: View = .{ .kind = .diff },
    file_start: std.ArrayList(u32) = .empty,
    numw: usize = 3,
    // file viewer
    fv: View = .{ .kind = .file },
    fv_open: bool = false,
    fv_path: []u8 = &.{},
    fv_arena: std.heap.ArenaAllocator,
    fv_lines: []const []const u8 = &.{},
    fv_added: []bool = &.{},
    fv_del: []bool = &.{},
    fv_note: ?[]const u8 = null,
    fv_style: Style = .none,
    fv_fi: ?u32 = null,
    fv_numw: usize = 3,
    // tree
    nodes: std.ArrayList(Node) = .empty,
    all_files: [][]const u8 = &.{},
    vis: std.ArrayList(Vis) = .empty,
    vis_dirty: bool = true,
    t_cursor: usize = 0,
    t_top: usize = 0,
    expanded: std.StringHashMapUnmanaged(void) = .empty,
    // review
    comments: std.ArrayList(Comment) = .empty,
    mode: Mode = .diff,
    focus: Focus = .tree,
    sidebar: bool = true,
    agent: *const Agent = &generic_agent,
    // agent panel: a live copy of the agent's pane, filled by mirrorLoop
    panel_open: std.atomic.Value(bool) = .init(false),
    agent_focus: std.atomic.Value(bool) = .init(false),
    quit: std.atomic.Value(bool) = .init(false),
    mirror_mu: Io.Mutex = .init,
    mirror: Mirror = .{},
    applied: Modes = .{},
    /// Where the panel was last drawn: screen x/y, size, and first agent row shown.
    pan: struct { x: usize = 0, y: usize = 0, w: usize = 0, h: usize = 0, row0: usize = 0 } = .{},
    agent_cursor: ?[2]usize = null,
    /// Set after typing so the mirror refreshes right away.
    mirror_due: std.atomic.Value(bool) = .init(false),
    search: std.ArrayList(u8) = .empty,
    msg_buf: [512]u8 = undefined,
    msg_len: usize = 0,
    count: usize = 0,
    pending_g: bool = false,
    last_check: i64 = 0,
    page: usize = 20,
    branch: []const u8 = "",
    review_dir: []const u8 = "",
    hl: std.ArrayList(HSpan) = .empty,

    fn now(self: *App) i64 {
        return Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    fn setMsg(self: *App, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.msg_buf, fmt, args) catch self.msg_buf[0..0];
        self.msg_len = s.len;
    }

    fn msg(self: *App) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }

    fn git(self: *App, args: []const []const u8) ?RunOut {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        argv.appendSlice(self.gpa, &.{ "git", "-c", "core.quotepath=off" }) catch return null;
        argv.appendSlice(self.gpa, args) catch return null;
        return runCmd(self.gpa, self.io, argv.items);
    }

    fn rexRun(self: *App, sub: []const u8, args: []const []const u8) ?RunOut {
        const exe = self.rex orelse return null;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        argv.appendSlice(self.gpa, &.{ exe, sub }) catch return null;
        if (self.session) |s| argv.appendSlice(self.gpa, &.{ "-s", s }) catch return null;
        argv.appendSlice(self.gpa, args) catch return null;
        return runCmd(self.gpa, self.io, argv.items);
    }

    // ---- data

    fn collectDiff(self: *App) ![]u8 {
        var base: std.ArrayList([]const u8) = .empty;
        defer base.deinit(self.gpa);
        try base.appendSlice(self.gpa, self.revs);
        if (base.items.len == 0) {
            const head = self.git(&.{ "rev-parse", "--verify", "-q", "HEAD" });
            const has_head = if (head) |h| blk: {
                self.gpa.free(h.out);
                break :blk h.ok;
            } else false;
            try base.append(self.gpa, if (has_head) "HEAD" else "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
        }
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.gpa);
        try args.appendSlice(self.gpa, &.{ "diff", "--no-color", "--no-ext-diff", "-M" });
        try args.appendSlice(self.gpa, base.items);
        var out: std.ArrayList(u8) = .empty;
        if (self.git(args.items)) |r| {
            defer self.gpa.free(r.out);
            try out.appendSlice(self.gpa, r.out);
        }
        // Untracked files only make sense when comparing against the working tree.
        const b0 = base.items[0];
        if (base.items.len == 1 and mem.indexOf(u8, b0, "..") == null and !mem.startsWith(u8, b0, "--")) {
            if (self.git(&.{ "ls-files", "--others", "--exclude-standard", "-z" })) |r| {
                defer self.gpa.free(r.out);
                var it = mem.splitScalar(u8, r.out, 0);
                var count: usize = 0;
                while (it.next()) |p| {
                    if (p.len == 0) continue;
                    count += 1;
                    if (count > 300) break;
                    try self.syntheticNewFile(&out, p);
                }
            }
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Build a "new file" diff for an untracked path without spawning git.
    fn syntheticNewFile(self: *App, out: *std.ArrayList(u8), p: []const u8) !void {
        const g = self.gpa;
        const data = Io.Dir.cwd().readFileAlloc(self.io, p, g, .limited(512 * 1024)) catch |err| {
            if (err == error.StreamTooLong) try out.print(g, "diff --git a/{s} b/{s}\nnew file mode 100644\nBinary files /dev/null and b/{s} differ\n", .{ p, p, p });
            return;
        };
        defer g.free(data);
        try out.print(g, "diff --git a/{s} b/{s}\nnew file mode 100644\n", .{ p, p });
        if (mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null) {
            try out.print(g, "Binary files /dev/null and b/{s} differ\n", .{p});
            return;
        }
        if (data.len == 0) return;
        const body = if (data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;
        const nlines = mem.count(u8, body, "\n") + 1;
        try out.print(g, "--- /dev/null\n+++ b/{s}\n@@ -0,0 +1,{d} @@\n", .{ p, nlines });
        var it = mem.splitScalar(u8, body, '\n');
        while (it.next()) |ln| {
            try out.append(g, '+');
            try out.appendSlice(g, ln);
            try out.append(g, '\n');
        }
    }

    fn reload(self: *App, force: bool) !bool {
        const g = self.gpa;
        const raw = try self.collectDiff();
        if (!force and mem.eql(u8, raw, self.raw)) {
            g.free(raw);
            return false;
        }
        // remember positions by value, since the arena is about to go away
        var old_key: ?Anchor = null;
        if (self.diff.rows.items.len > 0) {
            const k = self.keyOf(&self.diff, self.diff.cursor);
            old_key = .{ .path = try g.dupe(u8, k.path), .k = k.k, .a = k.a, .b = k.b };
        }
        defer if (old_key) |k| g.free(k.path);
        var tree_path: ?[]u8 = null;
        if (self.treeCurrent()) |n| tree_path = try g.dupe(u8, self.nodes.items[n.node].path);
        defer if (tree_path) |p| g.free(p);

        g.free(self.raw);
        self.raw = raw;
        self.diff.rows.clearRetainingCapacity();
        self.vis.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        self.files = try parseDiff(a, self.raw);
        self.changed = .empty;
        for (self.files, 0..) |f, i| try self.changed.put(a, f.path, @intCast(i));
        try self.buildDiffRows();
        if (old_key) |k| {
            if (self.findRow(&self.diff, k)) |r| {
                self.diff.cursor = r;
            } else if (self.changed.get(k.path)) |fi| {
                self.diff.cursor = self.file_start.items[fi];
            }
            self.diff.clamp();
        }
        try self.buildTree();
        if (tree_path) |p| self.reveal(p);
        if (self.fv_open) {
            const cur = self.fv.cursor;
            try self.loadFile(self.fv_path);
            self.fv.cursor = cur;
            self.fv.clamp();
        }
        return true;
    }

    fn buildDiffRows(self: *App) !void {
        const g = self.gpa;
        self.diff.rows.clearRetainingCapacity();
        self.file_start.clearRetainingCapacity();
        var maxno: u32 = 0;
        for (self.files, 0..) |*f, fi| {
            try self.file_start.append(g, @intCast(self.diff.rows.items.len));
            try self.diff.rows.append(g, .{ .t = .file, .fi = @intCast(fi) });
            // comments for this file: whole-file ones and ones whose line isn't in the diff go under the header
            for (self.comments.items, 0..) |cm, ci| {
                if (!mem.eql(u8, cm.anchor.path, f.path)) continue;
                var found = false;
                if (cm.anchor.k != .file) {
                    for (0..f.lines.items.len) |li| {
                        if (lineAnchor(f, li).eql(cm.anchor)) {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) try self.diff.rows.append(g, .{ .t = .comment, .fi = @intCast(fi), .idx = @intCast(ci) });
            }
            for (f.lines.items, 0..) |l, li| {
                maxno = @max(maxno, @max(l.old, l.new));
                try self.diff.rows.append(g, .{ .t = .line, .fi = @intCast(fi), .idx = @intCast(li) });
                const k = lineAnchor(f, li);
                for (self.comments.items, 0..) |cm, ci| {
                    if (cm.anchor.eql(k)) try self.diff.rows.append(g, .{ .t = .comment, .fi = @intCast(fi), .idx = @intCast(ci) });
                }
            }
            try self.diff.rows.append(g, .{ .t = .gap, .fi = @intCast(fi) });
        }
        self.numw = @max(3, digits(maxno));
        self.diff.clamp();
    }

    fn rebuildViews(self: *App) !void {
        const k = if (self.diff.rows.items.len > 0) self.keyOf(&self.diff, self.diff.cursor) else null;
        const cur = self.diff.cursor;
        try self.buildDiffRows();
        self.diff.cursor = cur;
        if (k) |kk| if (self.findRow(&self.diff, kk)) |r| {
            self.diff.cursor = r;
        };
        self.diff.clamp();
        if (self.fv_open) {
            const fk = if (self.fv.rows.items.len > 0) self.keyOf(&self.fv, self.fv.cursor) else null;
            try self.buildFileRows();
            if (fk) |kk| if (self.findRow(&self.fv, kk)) |r| {
                self.fv.cursor = r;
            };
            self.fv.clamp();
        }
    }

    // ---- file viewer

    fn loadFile(self: *App, path: []const u8) !void {
        const g = self.gpa;
        if (path.ptr != self.fv_path.ptr) {
            const dup = try g.dupe(u8, path);
            g.free(self.fv_path);
            self.fv_path = dup;
        }
        _ = self.fv_arena.reset(.retain_capacity);
        const a = self.fv_arena.allocator();
        self.fv_note = null;
        self.fv_lines = &.{};
        const limit: usize = 2 * 1024 * 1024;
        const data: []u8 = Io.Dir.cwd().readFileAlloc(self.io, self.fv_path, a, .limited(limit)) catch |err| switch (err) {
            error.FileNotFound => blk: {
                self.fv_note = "deleted in the working tree";
                break :blk &.{};
            },
            error.StreamTooLong => blk: {
                self.fv_note = "too large to show (> 2 MB)";
                break :blk &.{};
            },
            else => blk: {
                self.fv_note = "could not read file";
                break :blk &.{};
            },
        };
        if (mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null) {
            self.fv_note = "binary file";
        } else if (data.len > 0) {
            const body = if (data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;
            var lines: std.ArrayList([]const u8) = .empty;
            var it = mem.splitScalar(u8, body, '\n');
            while (it.next()) |ln| try lines.append(a, try cleanText(a, ln));
            self.fv_lines = lines.items;
        }
        self.fv_fi = self.changed.get(self.fv_path);
        self.fv_added = try a.alloc(bool, self.fv_lines.len + 2);
        self.fv_del = try a.alloc(bool, self.fv_lines.len + 2);
        @memset(self.fv_added, false);
        @memset(self.fv_del, false);
        if (self.fv_fi) |fi| {
            var cur: u32 = 1;
            for (self.files[fi].lines.items) |l| {
                switch (l.kind) {
                    .hunk => cur = l.new,
                    .add, .ctx => {
                        if (l.kind == .add and l.new < self.fv_added.len) self.fv_added[l.new] = true;
                        cur = l.new + 1;
                    },
                    .del => if (cur < self.fv_del.len) {
                        self.fv_del[cur] = true;
                    },
                    .meta => {},
                }
            }
        }
        self.fv_style = langStyle(self.fv_path);
        self.fv_numw = @max(3, digits(self.fv_lines.len));
        try self.buildFileRows();
    }

    fn buildFileRows(self: *App) !void {
        const g = self.gpa;
        self.fv.rows.clearRetainingCapacity();
        for (self.comments.items, 0..) |cm, ci| {
            if (cm.anchor.k == .file and mem.eql(u8, cm.anchor.path, self.fv_path))
                try self.fv.rows.append(g, .{ .t = .comment, .idx = @intCast(ci) });
        }
        for (0..self.fv_lines.len) |i| {
            try self.fv.rows.append(g, .{ .t = .line, .idx = @intCast(i) });
            for (self.comments.items, 0..) |cm, ci| {
                if (cm.anchor.k == .new and cm.anchor.a == i + 1 and mem.eql(u8, cm.anchor.path, self.fv_path))
                    try self.fv.rows.append(g, .{ .t = .comment, .idx = @intCast(ci) });
            }
        }
        self.fv.clamp();
    }

    fn fvChanged(self: *App, n: usize) bool {
        return n < self.fv_added.len and (self.fv_added[n] or self.fv_del[n]);
    }

    fn openFile(self: *App, path: []const u8, line: ?u32) !void {
        const fresh = !self.fv_open or !mem.eql(u8, self.fv_path, path);
        if (fresh) {
            self.fv = .{ .kind = .file, .rows = self.fv.rows };
            try self.loadFile(path);
            self.fv_open = true;
            if (line == null and self.fv_fi != null) {
                for (0..self.fv.rows.items.len) |r| {
                    if (self.blockStart(&self.fv, r)) {
                        self.fv.cursor = r;
                        break;
                    }
                }
            }
        }
        if (line) |n| if (self.findRow(&self.fv, .{ .path = self.fv_path, .k = .new, .a = n })) |r| {
            self.fv.cursor = r;
        };
        self.reveal(path);
        self.mode = .files;
        self.focus = .viewer;
    }

    // ---- tree

    fn buildTree(self: *App) !void {
        const a = self.arena.allocator();
        const g = self.gpa;
        self.nodes = .empty;
        var paths: std.ArrayList([]const u8) = .empty;
        if (self.git(&.{ "ls-files", "-z", "--cached", "--others", "--exclude-standard" })) |r| {
            defer g.free(r.out);
            const copy = try a.dupe(u8, r.out);
            var it = mem.splitScalar(u8, copy, 0);
            while (it.next()) |p| if (p.len > 0) try paths.append(a, p);
        }
        for (self.files) |f| try paths.append(a, f.path);
        mem.sort([]const u8, paths.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return mem.lessThan(u8, x, y);
            }
        }.lt);
        // dedupe
        var uniq: std.ArrayList([]const u8) = .empty;
        for (paths.items) |p| {
            if (uniq.items.len > 0 and mem.eql(u8, uniq.items[uniq.items.len - 1], p)) continue;
            try uniq.append(a, p);
        }
        self.all_files = uniq.items;
        var dirs: std.StringHashMapUnmanaged(u32) = .empty;
        try self.nodes.append(a, .{ .name = "", .path = "", .is_dir = true });
        try dirs.put(a, "", 0);
        for (self.all_files) |p| {
            var parent: u32 = 0;
            var start: usize = 0;
            while (mem.indexOfScalarPos(u8, p, start, '/')) |slash| {
                const dpath = p[0..slash];
                const gop = try dirs.getOrPut(a, dpath);
                if (!gop.found_existing) {
                    const idx: u32 = @intCast(self.nodes.items.len);
                    try self.nodes.append(a, .{ .name = p[start..slash], .path = dpath, .is_dir = true });
                    try self.nodes.items[parent].kids.append(a, idx);
                    gop.value_ptr.* = idx;
                }
                parent = gop.value_ptr.*;
                start = slash + 1;
            }
            const idx: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(a, .{ .name = p[start..], .path = p, .is_dir = false });
            try self.nodes.items[parent].kids.append(a, idx);
        }
        const nodes = self.nodes.items;
        for (nodes) |*n| {
            mem.sort(u32, n.kids.items, nodes, struct {
                fn lt(ns: []Node, x: u32, y: u32) bool {
                    if (ns[x].is_dir != ns[y].is_dir) return ns[x].is_dir;
                    return std.ascii.lessThanIgnoreCase(ns[x].name, ns[y].name);
                }
            }.lt);
        }
        // changed counts per dir + default expansion
        for (self.files) |f| {
            var start: usize = 0;
            while (mem.indexOfScalarPos(u8, f.path, start, '/')) |slash| {
                const dpath = f.path[0..slash];
                if (dirs.get(dpath)) |di| nodes[di].changed += 1;
                if (!self.expanded.contains(dpath)) try self.expanded.put(g, try g.dupe(u8, dpath), {});
                start = slash + 1;
            }
        }
        self.vis_dirty = true;
    }

    fn visible(self: *App) []Vis {
        if (self.vis_dirty) {
            self.vis.clearRetainingCapacity();
            if (self.nodes.items.len > 0) self.walk(0, 0, 0);
            self.vis_dirty = false;
            if (self.t_cursor >= self.vis.items.len) self.t_cursor = self.vis.items.len -| 1;
        }
        return self.vis.items;
    }

    fn walk(self: *App, node: u32, depth: u16, mask: u64) void {
        const kids = self.nodes.items[node].kids.items;
        for (kids, 0..) |k, i| {
            const last = i + 1 == kids.len;
            self.vis.append(self.gpa, .{ .depth = depth, .node = k, .mask = mask, .last = last }) catch return;
            const n = self.nodes.items[k];
            const bit: u64 = if (last and depth < 64) @as(u64, 1) << @intCast(depth) else 0;
            if (n.is_dir and self.expanded.contains(n.path)) self.walk(k, depth + 1, mask | bit);
        }
    }

    fn treeCurrent(self: *App) ?Vis {
        const v = self.visible();
        if (v.len == 0) return null;
        return v[@min(self.t_cursor, v.len - 1)];
    }

    fn setExpanded(self: *App, path: []const u8, on: bool) void {
        if (on) {
            if (!self.expanded.contains(path)) {
                const d = self.gpa.dupe(u8, path) catch return;
                self.expanded.put(self.gpa, d, {}) catch return;
            }
        } else if (self.expanded.fetchRemove(path)) |kv| {
            self.gpa.free(kv.key);
        }
        self.vis_dirty = true;
    }

    fn reveal(self: *App, path: []const u8) void {
        var start: usize = 0;
        while (mem.indexOfScalarPos(u8, path, start, '/')) |slash| {
            self.setExpanded(path[0..slash], true);
            start = slash + 1;
        }
        self.vis_dirty = true;
        for (self.visible(), 0..) |v, i| {
            if (mem.eql(u8, self.nodes.items[v.node].path, path)) {
                self.t_cursor = i;
                return;
            }
        }
    }

    // ---- row semantics (shared by the diff and file views)

    fn keyOf(self: *App, v: *View, r: usize) Anchor {
        const row = v.rows.items[r];
        if (row.t == .comment) return self.comments.items[row.idx].anchor;
        if (v.kind == .file) return .{ .path = self.fv_path, .k = .new, .a = row.idx + 1 };
        const f = &self.files[row.fi];
        return switch (row.t) {
            .file => .{ .path = f.path, .k = .file },
            .gap => .{ .path = f.path, .k = .gap },
            else => lineAnchor(f, row.idx),
        };
    }

    fn findRow(self: *App, v: *View, k: Anchor) ?usize {
        for (v.rows.items, 0..) |row, i| {
            if (row.t == .comment) continue;
            if (self.keyOf(v, i).eql(k)) return i;
        }
        return null;
    }

    fn anchorable(_: *App, v: *View, r: usize) bool {
        const t = v.rows.items[r].t;
        return t == .line or (v.kind == .diff and t == .file);
    }

    fn lineno(self: *App, v: *View, r: usize) ?u32 {
        const row = v.rows.items[r];
        if (row.t != .line) return null;
        if (v.kind == .file) return row.idx + 1;
        const l = self.files[row.fi].lines.items[row.idx];
        if (l.new != 0) return l.new;
        if (l.old != 0) return l.old;
        return null;
    }

    fn pathOf(self: *App, v: *View, r: usize) []const u8 {
        if (v.kind == .file) return self.fv_path;
        return self.files[v.rows.items[r].fi].path;
    }

    fn locOf(self: *App, v: *View, r: usize, buf: []u8) []const u8 {
        const row = v.rows.items[r];
        const path = self.pathOf(v, r);
        if (v.kind == .diff and row.t == .file) return std.fmt.bufPrint(buf, "{s} (whole file)", .{path}) catch path;
        if (v.kind == .diff and row.t == .line) {
            const l = self.files[row.fi].lines.items[row.idx];
            if (l.kind == .del) return std.fmt.bufPrint(buf, "{s}:{d} (removed line)", .{ path, l.old }) catch path;
        }
        if (row.t == .line) if (self.lineno(v, r)) |n| return std.fmt.bufPrint(buf, "{s}:{d}", .{ path, n }) catch path;
        return path;
    }

    /// Diff-style code line for the review file ("+foo"), or null.
    fn codeOf(self: *App, v: *View, r: usize) ?struct { sign: u8, text: []const u8 } {
        const row = v.rows.items[r];
        if (row.t != .line) return null;
        if (v.kind == .file) return .{ .sign = ' ', .text = self.fv_lines[row.idx] };
        const l = self.files[row.fi].lines.items[row.idx];
        return switch (l.kind) {
            .add => .{ .sign = '+', .text = l.text },
            .del => .{ .sign = '-', .text = l.text },
            .ctx => .{ .sign = ' ', .text = l.text },
            else => null,
        };
    }

    fn textOf(self: *App, v: *View, r: usize) ?[]const u8 {
        const row = v.rows.items[r];
        if (row.t == .comment) return self.comments.items[row.idx].text;
        if (v.kind == .file) return self.fv_lines[row.idx];
        return switch (row.t) {
            .line => self.files[row.fi].lines.items[row.idx].text,
            .file => self.files[row.fi].path,
            else => null,
        };
    }

    fn blockStart(self: *App, v: *View, r: usize) bool {
        const row = v.rows.items[r];
        if (row.t != .line) return false;
        if (v.kind == .diff) return self.files[row.fi].lines.items[row.idx].kind == .hunk;
        const n = row.idx + 1;
        return self.fvChanged(n) and !self.fvChanged(n - 1);
    }

    fn commentAt(self: *App, v: *View, r: usize) ?usize {
        const row = v.rows.items[r];
        if (row.t == .comment) return row.idx;
        const k = self.keyOf(v, r);
        for (self.comments.items, 0..) |cm, ci| {
            if (!cm.sent and cm.anchor.eql(k)) return ci;
        }
        return null;
    }

    fn emphFor(self: *App, f: *FileDiff, li: u32) []const Span {
        if (f.emph.get(li)) |s| return s;
        const l = f.lines.items[li];
        if (l.pair == NONE) return &.{};
        const a = self.arena.allocator();
        const d = if (l.kind == .del) li else l.pair;
        const p = if (l.kind == .del) l.pair else li;
        const res = computeEmph(a, self.gpa, f.lines.items[d].text, f.lines.items[p].text) catch null;
        const empty: []Span = &.{};
        const rd = if (res) |r| r[0] else empty;
        const rp = if (res) |r| r[1] else empty;
        f.emph.put(a, d, rd) catch {};
        f.emph.put(a, p, rp) catch {};
        return if (l.kind == .del) rd else rp;
    }

    fn activeView(self: *App) ?*View {
        if (self.mode == .diff) return &self.diff;
        if (self.focus == .viewer and self.fv_open) return &self.fv;
        return null;
    }

    fn location(self: *App, buf: []u8) []const u8 {
        if (self.activeView()) |v| {
            if (v.rows.items.len > 0) return self.locOf(v, v.cursor, buf);
            if (v.kind == .file) return self.fv_path;
        }
        if (self.mode == .files) if (self.treeCurrent()) |t| return self.nodes.items[t.node].path;
        return "";
    }

    // ---- drawing

    fn draw(self: *App) void {
        self.drawFrame();
        self.scr.flush(if (self.agent_focus.load(.acquire)) self.agent_cursor else null);
    }

    fn drawFrame(self: *App) void {
        const sz = termSize();
        self.scr.resize(sz[0], sz[1]) catch return;
        self.scr.clear();
        const w = self.scr.w;
        const h = self.scr.h;
        if (h < 6 or w < 20) return;
        const top: usize = 2;
        const bh: usize = @max(1, h -| 3);
        self.page = bh;
        // the agent panel sits on the right at the agent's own width, like its pane would
        var dw = w;
        self.pan.w = 0;
        if (self.panel_open.load(.acquire)) {
            self.mirror_mu.lockUncancelable(self.io);
            const mc = self.mirror.cols;
            self.mirror_mu.unlock(self.io);
            const pw = @min(if (mc > 0) mc else w * 45 / 100, w -| 41);
            if (pw >= 20) dw = w - pw - 1;
        }
        self.drawHeader(dw);
        self.hrule(1, 0, dw, P.rule);
        if (self.mode == .diff) self.drawDiff(top, bh, dw) else self.drawFiles(top, bh, dw);
        if (dw < w) self.drawPanel(dw + 1, w - dw - 1, h - 1);
        self.drawStatus(h - 1, w);
    }

    fn drawPanel(self: *App, x0: usize, pw: usize, ph: usize) void {
        const s = &self.scr;
        const focused = self.agent_focus.load(.acquire);
        for (0..ph) |y| s.set(y, x0 - 1, '│', if (focused) self.agent.color else P.rule, P.def, 0);
        self.agent_cursor = null;
        self.mirror_mu.lockUncancelable(self.io);
        defer self.mirror_mu.unlock(self.io);
        const m = &self.mirror;
        if (m.rows == 0) {
            var tb: [64]u8 = undefined;
            _ = s.put(1, x0 + 2, std.fmt.bufPrint(&tb, "connecting to {s}…", .{self.agent.name}) catch "", P.faint, P.def, ITAL);
            self.pan = .{ .x = x0, .w = pw, .h = ph };
            return;
        }
        // show the bottom of the agent's screen, keeping its cursor in view
        var row0 = m.rows -| ph;
        if (m.cursor) |cu| row0 = @min(row0, cu[0]);
        self.pan = .{ .x = x0, .y = 0, .w = pw, .h = ph, .row0 = row0 };
        for (0..@min(ph, m.rows - row0)) |r| {
            const src = m.cells[(row0 + r) * m.cols ..][0..m.cols];
            for (0..@min(pw, m.cols)) |cx| {
                var cell = src[cx];
                // a wide char cut off at the edge
                if (cx + 1 == pw and cx + 1 < m.cols and src[cx + 1].ch == WIDE_CONT) cell.ch = ' ';
                s.cells[r * s.w + x0 + cx] = cell;
            }
        }
        if (m.cursor) |cu| if (cu[0] >= row0 and cu[0] - row0 < ph and cu[1] < pw) {
            self.agent_cursor = .{ cu[0] - row0, x0 + cu[1] };
        };
    }

    fn hrule(self: *App, y: usize, x: usize, n: usize, col: Col) void {
        for (0..n) |i| self.scr.set(y, x + i, '─', col, P.def, 0);
    }

    fn vrule(self: *App, x: usize, top: usize, n: usize) void {
        for (0..n) |i| self.scr.set(top + i, x, '│', P.rule, P.def, 0);
    }

    fn drawHeader(self: *App, w: usize) void {
        const s = &self.scr;
        var adds: u32 = 0;
        var dels: u32 = 0;
        for (self.files) |f| {
            adds += f.adds;
            dels += f.dels;
        }
        var b1: [32]u8 = undefined;
        var b2: [16]u8 = undefined;
        var b3: [16]u8 = undefined;
        const r1 = std.fmt.bufPrint(&b1, "{d} files", .{self.files.len}) catch "";
        const r2 = std.fmt.bufPrint(&b2, "+{d}", .{adds}) catch "";
        const r3 = std.fmt.bufPrint(&b3, "-{d}", .{dels}) catch "";
        const right_len = 12 + 3 + r1.len + 2 + r2.len + 1 + r3.len + 1;
        const rx = w -| right_len;

        var x = s.put(0, 1, "kibitz", P.accent, P.def, BOLD);
        x = s.put(0, x, " ── ", P.faint, P.def, 0);
        var base_buf: [256]u8 = undefined;
        var base: []const u8 = "HEAD+worktree";
        if (self.revs.len > 0) {
            var n: usize = 0;
            for (self.revs) |r| {
                if (n + r.len + 1 > base_buf.len) break;
                if (n > 0) {
                    base_buf[n] = ' ';
                    n += 1;
                }
                @memcpy(base_buf[n..][0..r.len], r);
                n += r.len;
            }
            base = base_buf[0..n];
        }
        const branch_room = rx -| (x + 2 + 3 + cpLen(base));
        const branch = if (cpLen(self.branch) <= branch_room) self.branch else tailCp(self.branch, branch_room -| 1);
        if (branch.len < self.branch.len and branch_room > 1) x = s.put(0, x, "…", P.faint, P.def, 0);
        x = s.putMax(0, x, branch, P.fg, P.def, BOLD, rx -| (x + 2));
        x = s.putMax(0, x, " ← ", P.faint, P.def, 0, rx -| (x + 2));
        _ = s.putMax(0, x, base, P.dim, P.def, 0, rx -| (x + 2));

        var tx = rx;
        if (self.mode == .diff) {
            tx = s.put(0, tx, "[diff]", P.accent, P.def, BOLD);
            tx = s.put(0, tx, " files", P.faint, P.def, 0);
        } else {
            tx = s.put(0, tx, "diff ", P.faint, P.def, 0);
            tx = s.put(0, tx, "[files]", P.accent, P.def, BOLD);
        }
        tx = s.put(0, tx + 3, r1, P.dim, P.def, 0);
        tx = s.put(0, tx + 2, r2, P.add_fg, P.def, BOLD);
        _ = s.put(0, tx + 1, r3, P.del_fg, P.def, BOLD);
    }

    fn drawDiff(self: *App, top: usize, bh: usize, w: usize) void {
        const s = &self.scr;
        const sw: usize = if (self.sidebar and w >= 100 and self.files.len > 0) @min(44, @max(28, w / 4)) else 0;
        if (sw > 0) {
            self.drawChanges(top, bh, sw);
            self.vrule(sw - 1, top, bh);
        }
        const x0 = if (sw > 0) sw + 1 else 0;
        if (self.files.len == 0) {
            _ = s.put(top + 1, x0 + 2, "nothing to review", P.bright, P.def, BOLD);
            _ = s.put(top + 2, x0 + 2, "r reload · f browse files · q quit", P.faint, P.def, 0);
            return;
        }
        const v = &self.diff;
        v.ensure(bh);
        const sel = v.selection();
        for (0..bh) |y| {
            const r = v.top + y;
            if (r >= v.rows.items.len) break;
            self.drawDiffRow(top + y, x0, w - x0, r, sel);
        }
    }

    fn drawChanges(self: *App, top: usize, bh: usize, sw: usize) void {
        const s = &self.scr;
        const v = &self.diff;
        const cur_fi: usize = if (v.rows.items.len > 0) v.rows.items[v.cursor].fi else 0;
        var x = s.put(top, 1, "changes", P.dim, P.def, BOLD);
        var nb: [16]u8 = undefined;
        x = s.put(top, x + 1, std.fmt.bufPrint(&nb, "{d}", .{self.files.len}) catch "", P.faint, P.def, 0);
        const rows = bh -| 1;
        if (rows == 0) return;
        const start: usize = @min(cur_fi -| (rows / 2), self.files.len -| rows);
        const cw = sw -| 1;
        for (0..rows) |i| {
            const fi = start + i;
            if (fi >= self.files.len) break;
            const f = self.files[fi];
            const y = top + 1 + i;
            const on = fi == cur_fi;
            const bg = if (on) P.cursor else P.def;
            s.fill(y, 0, cw, P.fg, bg);
            if (on) _ = s.put(y, 0, "▌", P.accent, bg, 0);
            s.set(y, 2, f.status, statusCol(f.status), bg, BOLD);
            var sb: [32]u8 = undefined;
            const stats = std.fmt.bufPrint(&sb, "+{d} -{d}", .{ f.adds, f.dels }) catch "";
            const room = cw -| (6 + stats.len);
            const parts = splitPath(f.path);
            var d = parts[0];
            var b = parts[1];
            if (cpLen(d) + cpLen(b) > room) {
                d = if (room > cpLen(b) + 2) tailCp(d, room - cpLen(b) - 1) else "";
                if (cpLen(b) > room) b = b[0..room];
            }
            var px: usize = 4;
            if (d.len < parts[0].len and d.len > 0) px = s.put(y, px, "…", P.faint, bg, 0);
            px = s.put(y, px, d, P.faint, bg, 0);
            _ = s.put(y, px, b, if (on) P.bright else P.fg, bg, if (on) BOLD else 0);
            var sx = cw -| (1 + stats.len);
            var ab: [16]u8 = undefined;
            sx = s.put(y, sx, std.fmt.bufPrint(&ab, "+{d}", .{f.adds}) catch "", P.add_fg, bg, 0);
            _ = s.put(y, sx + 1, std.fmt.bufPrint(&ab, "-{d}", .{f.dels}) catch "", P.del_fg, bg, 0);
        }
    }

    fn putCode(self: *App, y: usize, x: usize, width: usize, text: []const u8, style: Style, emph: []const Span, bg: Col, emph_bg: Col, hs: usize) void {
        if (width == 0) return;
        self.hl.clearRetainingCapacity();
        highlight(self.gpa, text, style, &self.hl) catch {};
        const spans = self.hl.items;
        var col: usize = 0;
        var i: usize = 0;
        var hi: usize = 0;
        while (i < text.len) {
            const d = decode(text[i..]);
            if (col >= hs) {
                const cx = col - hs;
                if (cx >= width) break;
                while (hi < spans.len and spans[hi].e <= i) hi += 1;
                var fg: Col = P.fg;
                var at: u8 = 0;
                if (hi < spans.len and spans[hi].s <= i) {
                    fg = hcol(spans[hi].k);
                    if (spans[hi].k == .com) at = ITAL;
                }
                var cbg = bg;
                for (emph) |e| {
                    if (e.s <= i and i < e.e) {
                        cbg = emph_bg;
                        break;
                    }
                }
                self.scr.set(y, x + cx, d.cp, fg, cbg, at);
            }
            col += 1;
            i += d.len;
        }
    }

    fn drawDiffRow(self: *App, y: usize, x0: usize, width: usize, r: usize, sel: ?[2]usize) void {
        const s = &self.scr;
        const v = &self.diff;
        const row = v.rows.items[r];
        const f = &self.files[row.fi];
        const is_cur = r == v.cursor;
        const in_sel = if (sel) |sl| sl[0] <= r and r <= sl[1] else false;
        const nw = self.numw;
        const gw = 2 * nw + 5;
        const mark: []const u8 = if (is_cur) "▌" else if (in_sel) "┃" else " ";
        const mark_col = if (in_sel and !is_cur) P.visual else P.accent;
        switch (row.t) {
            .file => {
                const bg = if (is_cur) P.cursor else P.def;
                s.fill(y, x0, width, P.fg, bg);
                _ = s.put(y, x0, mark, mark_col, bg, 0);
                s.set(y, x0 + 2, f.status, statusCol(f.status), bg, BOLD);
                const parts = splitPath(f.path);
                var x = s.put(y, x0 + 4, parts[0], P.dim, bg, 0);
                x = s.put(y, x, parts[1], P.bright, bg, BOLD);
                if (f.status == 'R') {
                    x = s.put(y, x, " ← ", P.faint, bg, 0);
                    x = s.put(y, x, f.old_path, P.dim, bg, 0);
                }
                var nb: [32]u8 = undefined;
                x = s.put(y, x + 2, std.fmt.bufPrint(&nb, "+{d}", .{f.adds}) catch "", P.add_fg, bg, 0);
                x = s.put(y, x + 1, std.fmt.bufPrint(&nb, "-{d}", .{f.dels}) catch "", P.del_fg, bg, 0);
                const pos = std.fmt.bufPrint(&nb, " {d}/{d}", .{ row.fi + 1, self.files.len }) catch "";
                const px = x0 + width -| (pos.len + 1);
                var i = x + 1;
                while (i + 1 < px) : (i += 1) s.set(y, i, '─', P.rule, bg, 0);
                _ = s.put(y, px, pos, P.faint, bg, 0);
            },
            .gap => _ = s.put(y, x0, mark, mark_col, P.def, 0),
            .comment => self.drawNote(y, x0, width, &self.comments.items[row.idx], mark, gw, is_cur),
            .line => {
                const l = f.lines.items[row.idx];
                switch (l.kind) {
                    .hunk => {
                        const bg = if (is_cur) P.cursor else P.def;
                        s.fill(y, x0, width, P.fg, bg);
                        _ = s.put(y, x0, mark, mark_col, bg, 0);
                        var hb: [64]u8 = undefined;
                        const hdr = std.fmt.bufPrint(&hb, "@@ -{d} +{d} @@", .{ l.old, l.new }) catch "";
                        const x = s.put(y, x0 + gw - 3, hdr, P.hunk, bg, 0);
                        _ = s.put(y, x + 1, l.text, P.dim, bg, ITAL);
                    },
                    .meta => {
                        _ = s.put(y, x0, mark, mark_col, P.def, 0);
                        _ = s.put(y, x0 + gw, l.text, P.faint, P.def, ITAL);
                    },
                    else => {
                        const bg: Col = switch (l.kind) {
                            .add => P.add_bg,
                            .del => P.del_bg,
                            else => if (is_cur) P.cursor else if (in_sel) P.sel else P.def,
                        };
                        const gbg = if (in_sel) P.sel else if (is_cur) P.cursor else bg;
                        const numfg: Col = if (is_cur) P.bright else switch (l.kind) {
                            .add => P.add_num,
                            .del => P.del_num,
                            else => P.faint,
                        };
                        s.fill(y, x0, width, P.fg, bg);
                        _ = s.put(y, x0, mark, mark_col, gbg, 0);
                        var nb: [64]u8 = undefined;
                        var nb2: [32]u8 = undefined;
                        const o = padNum(&nb2, l.old, nw);
                        const nn = padNum(nb[32..], l.new, nw);
                        var gx = s.put(y, x0 + 1, o, numfg, gbg, 0);
                        gx = s.put(y, gx, " ", numfg, gbg, 0);
                        gx = s.put(y, gx, nn, numfg, gbg, 0);
                        _ = s.put(y, gx, " ", numfg, gbg, 0);
                        const sign: []const u8 = switch (l.kind) {
                            .add => "+",
                            .del => "-",
                            else => " ",
                        };
                        _ = s.put(y, x0 + 2 * nw + 3, sign, if (l.kind == .add) P.add_fg else P.del_fg, bg, BOLD);
                        const cw = width -| gw;
                        const emph = self.emphFor(f, row.idx);
                        self.putCode(y, x0 + gw, cw, l.text, langStyle(f.path), emph, bg, if (l.kind == .add) P.add_emph else P.del_emph, v.hscroll);
                        if (cpLen(l.text) -| v.hscroll > cw) s.set(y, x0 + width - 1, '›', P.faint, bg, 0);
                    },
                }
            },
        }
    }

    fn drawNote(self: *App, y: usize, x0: usize, width: usize, cm: *const Comment, mark: []const u8, gw: usize, is_cur: bool) void {
        const s = &self.scr;
        const bg = if (is_cur) P.cursor else P.def;
        s.fill(y, x0, width, P.fg, bg);
        _ = s.put(y, x0, mark, P.accent, bg, 0);
        var x = s.put(y, x0 + gw -| 3, "╰─▶ ", P.note, bg, 0);
        x = s.put(y, x, cm.text, P.note, bg, 0);
        _ = s.put(y, x + 2, if (cm.sent) "[sent]" else "[unsent]", if (cm.sent) P.add_num else P.faint, bg, 0);
    }

    fn drawFiles(self: *App, top: usize, bh: usize, w: usize) void {
        var tw: usize = @min(46, @max(28, w * 3 / 10));
        if (w < 80) tw = if (self.focus == .tree or !self.fv_open) w else 0;
        if (tw > 0) self.drawTree(top, bh, if (tw < w) tw - 1 else tw);
        if (tw < w) {
            if (tw > 0) self.vrule(tw - 1, top, bh);
            const vx = if (tw > 0) tw + 1 else 0;
            if (self.fv_open) {
                self.drawFileView(top, bh, vx, w - vx);
            } else {
                _ = self.scr.put(top + 1, vx + 2, "pick a file — enter or l opens it (read-only)", P.faint, P.def, 0);
            }
        }
    }

    fn drawTree(self: *App, top: usize, bh: usize, tw: usize) void {
        const s = &self.scr;
        const rows = self.visible();
        const focused = self.focus == .tree;
        var hb: [64]u8 = undefined;
        const x = s.put(top, 1, "files", P.dim, P.def, BOLD);
        _ = s.put(top, x + 1, std.fmt.bufPrint(&hb, "{d} · {d} changed", .{ self.all_files.len, self.files.len }) catch "", P.faint, P.def, 0);
        const lh = bh -| 1;
        if (lh == 0) return;
        if (self.t_cursor < self.t_top) self.t_top = self.t_cursor;
        if (self.t_cursor >= self.t_top + lh) self.t_top = self.t_cursor + 1 - lh;
        for (0..lh) |i| {
            const ri = self.t_top + i;
            if (ri >= rows.len) break;
            const vr = rows[ri];
            const n = self.nodes.items[vr.node];
            const y = top + 1 + i;
            const on = ri == self.t_cursor;
            const bg = if (on) P.cursor else P.def;
            s.fill(y, 0, tw, P.fg, bg);
            if (on and focused) _ = s.put(y, 0, "▌", P.accent, bg, 0);
            // `tree`-style connectors
            var cx: usize = 2;
            for (0..vr.depth) |d| {
                const ancestor_last = d < 64 and (vr.mask >> @intCast(d)) & 1 == 1;
                cx = s.put(y, cx, if (ancestor_last) "   " else "│  ", P.rule, bg, 0);
            }
            cx = s.put(y, cx, if (vr.last) "└─ " else "├─ ", P.rule, bg, 0);
            if (n.is_dir) {
                const open = self.expanded.contains(n.path);
                var ex = s.putMax(y, cx, n.name, P.dir, bg, if (n.changed > 0) BOLD else 0, tw -| (cx + 5));
                ex = s.put(y, ex, "/", P.dir, bg, 0);
                if (!open) _ = s.put(y, ex, " …", P.faint, bg, 0);
                if (n.changed > 0 and !open) {
                    var cb: [16]u8 = undefined;
                    const cs = std.fmt.bufPrint(&cb, "●{d}", .{n.changed}) catch "";
                    _ = s.put(y, tw -| (1 + cpLen(cs)), cs, statusCol('M'), bg, 0);
                }
            } else {
                const fi = self.changed.get(n.path);
                const is_open = self.fv_open and mem.eql(u8, n.path, self.fv_path);
                var sb: [32]u8 = undefined;
                const stats = if (fi) |fx| std.fmt.bufPrint(&sb, "+{d} -{d}", .{ self.files[fx].adds, self.files[fx].dels }) catch "" else "";
                const fg = if (fi) |fx| statusCol(self.files[fx].status) else if (is_open) P.bright else P.fg;
                _ = s.putMax(y, cx, n.name, fg, bg, if (is_open) BOLD else 0, tw -| (cx + 2 + stats.len));
                if (fi) |fx| {
                    var ab: [16]u8 = undefined;
                    const sx = s.put(y, tw -| (1 + stats.len), std.fmt.bufPrint(&ab, "+{d}", .{self.files[fx].adds}) catch "", P.add_fg, bg, 0);
                    _ = s.put(y, sx + 1, std.fmt.bufPrint(&ab, "-{d}", .{self.files[fx].dels}) catch "", P.del_fg, bg, 0);
                }
            }
        }
    }

    fn drawFileView(self: *App, top0: usize, bh0: usize, x0: usize, width: usize) void {
        const s = &self.scr;
        const v = &self.fv;
        const focused = self.focus == .viewer;
        var x = x0 + 1;
        if (self.fv_fi) |fi| {
            const st = self.files[fi].status;
            s.set(top0, x, st, statusCol(st), P.def, BOLD);
            x += 2;
        }
        const parts = splitPath(self.fv_path);
        x = s.put(top0, x, parts[0], P.dim, P.def, 0);
        x = s.put(top0, x, parts[1], P.bright, P.def, BOLD);
        x = s.put(top0, x + 2, "[ro]", P.faint, P.def, 0);
        if (self.fv_note) |note| {
            x = s.put(top0, x + 1, note, P.faint, P.def, ITAL);
        }
        var pb: [48]u8 = undefined;
        const ln_cur = if (v.rows.items.len > 0) self.lineno(v, v.cursor) else null;
        const pos = if (ln_cur) |n| std.fmt.bufPrint(&pb, "{d}/{d}", .{ n, self.fv_lines.len }) catch "" else std.fmt.bufPrint(&pb, "-/{d}", .{self.fv_lines.len}) catch "";
        const px = x0 + width -| (pos.len + 1);
        var i = x + 1;
        while (i + 1 < px) : (i += 1) s.set(top0, i, '─', P.rule, P.def, 0);
        _ = s.put(top0, px, pos, P.faint, P.def, 0);
        const top = top0 + 1;
        const bh = bh0 -| 1;
        v.ensure(bh);
        const sel = v.selection();
        const nw = self.fv_numw;
        const gw = nw + 4;
        for (0..bh) |yi| {
            const r = v.top + yi;
            if (r >= v.rows.items.len) break;
            const row = v.rows.items[r];
            const is_cur = r == v.cursor and focused;
            const in_sel = if (sel) |sl| sl[0] <= r and r <= sl[1] else false;
            const mark: []const u8 = if (is_cur) "▌" else if (in_sel) "┃" else " ";
            const y = top + yi;
            if (row.t == .comment) {
                self.drawNote(y, x0, width, &self.comments.items[row.idx], mark, gw, is_cur);
                continue;
            }
            const ln = row.idx + 1;
            const bg = if (in_sel) P.sel else if (is_cur) P.cursor else P.def;
            s.fill(y, x0, width, P.fg, bg);
            _ = s.put(y, x0, mark, if (in_sel and !is_cur) P.visual else P.accent, bg, 0);
            const added = ln < self.fv_added.len and self.fv_added[ln];
            if (added) {
                s.set(y, x0 + 1, '▎', P.add_fg, bg, 0);
            } else if (ln < self.fv_del.len and self.fv_del[ln]) {
                s.set(y, x0 + 1, '▔', P.del_fg, bg, 0);
            }
            const numfg = if (is_cur) P.bright else if (added) P.add_num else P.faint;
            var nb: [32]u8 = undefined;
            _ = s.put(y, x0 + 2, padNum(&nb, ln, nw), numfg, bg, if (is_cur) BOLD else 0);
            const text = self.fv_lines[row.idx];
            self.putCode(y, x0 + gw, width -| gw, text, self.fv_style, &.{}, bg, bg, v.hscroll);
            if (cpLen(text) -| v.hscroll > width -| gw) s.set(y, x0 + width - 1, '›', P.faint, bg, 0);
        }
        if (v.rows.items.len == 0) _ = s.put(top + 1, x0 + 4, self.fv_note orelse "empty file", P.faint, P.def, ITAL);
    }

    fn scrollPos(self: *App, buf: []u8) []const u8 {
        var cur: usize = 0;
        var n: usize = 0;
        if (self.activeView()) |v| {
            cur = v.cursor;
            n = v.rows.items.len;
        } else if (self.mode == .files) {
            cur = self.t_cursor;
            n = self.vis.items.len;
        }
        if (n <= 1) return "All";
        if (cur == 0) return "Top";
        if (cur + 1 >= n) return "Bot";
        return std.fmt.bufPrint(buf, "{d}%", .{cur * 100 / (n - 1)}) catch "";
    }

    fn drawStatus(self: *App, y: usize, w: usize) void {
        const s = &self.scr;
        const visual = if (self.activeView()) |v| v.sel != null else false;
        const typing = self.agent_focus.load(.acquire);
        var nb: [16]u8 = undefined;
        const mode_col = if (typing) self.agent.color else if (visual) P.visual else if (self.mode == .diff) P.accent else P.func;
        const mode_name: []const u8 = if (typing) std.ascii.upperString(&nb, self.agent.key[0..@min(self.agent.key.len, nb.len)]) else if (visual) "VISUAL" else if (self.mode == .diff) "DIFF" else if (self.focus == .tree) "TREE" else "VIEW";
        _ = s.put(y, 0, "▌", mode_col, P.def, 0);
        var x = s.put(y, 1, mode_name, mode_col, P.def, BOLD) + 2;

        var unsent: usize = 0;
        for (self.comments.items) |cm| {
            if (!cm.sent) unsent += 1;
        }
        const diff_hints = [_][2][]const u8{ .{ "c", "comment" }, .{ "S", "send" }, .{ "t", self.agent.key }, .{ "f", "files" }, .{ "?", "help" } };
        const file_hints = [_][2][]const u8{ .{ "⏎", "open" }, .{ "h/l", "pane" }, .{ "c", "comment" }, .{ "t", self.agent.key }, .{ "f", "diff" }, .{ "?", "help" } };
        const agent_hints = [_][2][]const u8{ .{ "^space", "back to diff" }, .{ "^space esc", "close panel" } };
        const panel_hints = [_][2][]const u8{ .{ "esc", "close panel" }, .{ "^space", "type to agent" }, .{ "c", "comment" }, .{ "S", "send" }, .{ "?", "help" } };
        const hints: []const [2][]const u8 = if (typing) &agent_hints else if (self.panel_open.load(.acquire)) &panel_hints else if (self.mode == .diff) &diff_hints else &file_hints;
        var ub: [32]u8 = undefined;
        const ustr = if (unsent > 0) std.fmt.bufPrint(&ub, "● {d} unsent", .{unsent}) catch "" else "";
        var pb: [16]u8 = undefined;
        const pos = self.scrollPos(&pb);

        var lb: [512]u8 = undefined;
        const has_msg = self.msg_len > 0;
        const left = if (has_msg) self.msg() else self.location(&lb);
        const left_w = cpLen(left) + (if (has_msg) @as(usize, 3) else 0);

        // drop hints from the end until everything fits
        var nh = hints.len;
        var total: usize = 0;
        while (true) {
            total = pos.len + 2 + (if (unsent > 0) cpLen(ustr) + 3 else 0);
            for (hints[0..nh]) |hh| total += cpLen(hh[0]) + cpLen(hh[1]) + 3;
            if (x + left_w + 2 + total <= w or nh == 0) break;
            nh -= 1;
        }
        if (has_msg) x = s.put(y, x, ":: ", P.accent, P.def, BOLD);
        _ = s.putMax(y, x, left, if (has_msg) P.bright else P.fg, P.def, 0, w -| (x + 1));
        if (x + left_w + 2 + total > w) return;
        var rx = w - total;
        if (unsent > 0) rx = s.put(y, rx, ustr, P.note, P.def, BOLD) + 3;
        for (hints[0..nh]) |hh| {
            rx = s.put(y, rx, hh[0], P.bright, P.def, BOLD);
            const linked = hh[1].ptr == self.agent.key.ptr and self.target != null;
            rx = s.put(y, rx + 1, hh[1], if (linked) self.agent.color else P.faint, P.def, 0) + 2;
        }
        _ = s.put(y, w - pos.len - 1, pos, P.dim, P.def, 0);
    }

    // ---- input helpers

    /// Single-line text input on the status row, vim command-line style. Caller owns the result.
    fn prompt(self: *App, label: []const u8, color: Col, initial: []const u8) ?[]u8 {
        const g = self.gpa;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(g);
        buf.appendSlice(g, initial) catch return null;
        while (true) {
            self.drawFrame();
            const s = &self.scr;
            const y = s.h - 1;
            const w = s.w;
            s.fill(y, 0, w, P.fg, P.def);
            _ = s.put(y, 0, "▌", color, P.def, 0);
            var x = s.putMax(y, 1, label, color, P.def, BOLD, w / 2);
            if (!mem.eql(u8, label, "/")) x = s.put(y, x, " › ", P.faint, P.def, 0);
            const room = w -| (x + 2);
            const text = buf.items;
            const shown = if (cpLen(text) <= room) text else tailCp(text, room -| 1);
            var end = x;
            if (shown.len < text.len) end = s.put(y, end, "…", P.faint, P.def, 0);
            end = s.put(y, end, shown, P.bright, P.def, 0);
            if (text.len == 0) _ = s.put(y, x + 1, "enter to send · esc to cancel", P.faint, P.def, ITAL);
            s.flush(.{ y, @min(end, w - 1) });
            const k = self.input.next(250) orelse continue;
            switch (k) {
                KEY_ENTER, '\n' => {
                    const t = mem.trim(u8, buf.items, " ");
                    return g.dupe(u8, t) catch null;
                },
                KEY_ESC => return null,
                127, 8 => {
                    while (buf.items.len > 0) {
                        const b = buf.pop().?;
                        if (b & 0xC0 != 0x80) break;
                    }
                },
                21 => buf.clearRetainingCapacity(),
                23 => {
                    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') _ = buf.pop();
                    while (buf.items.len > 0 and buf.items[buf.items.len - 1] != ' ') _ = buf.pop();
                },
                else => if (k >= 32 and k < 0x110000 and k != 127) {
                    var eb: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(k), &eb) catch continue;
                    buf.appendSlice(g, eb[0..n]) catch {};
                },
            }
        }
    }

    fn showHelp(self: *App) void {
        self.drawFrame();
        const s = &self.scr;
        var nlines: usize = 0;
        for (help_sections) |sec| nlines += sec.keys.len + 2;
        nlines -= 1;
        const bw = @min(s.w -| 4, 60);
        const bh = @min(s.h -| 2, nlines + 4);
        const y0 = (s.h -| bh) / 2;
        const x0 = (s.w -| bw) / 2;
        for (0..bh) |i| {
            s.fill(y0 + i, x0, bw, P.fg, P.def);
            if (i == 0 or i == bh - 1) {
                for (1..bw - 1) |xx| s.set(y0 + i, x0 + xx, '─', P.rule, P.def, 0);
            }
            s.set(y0 + i, x0, if (i == 0) '╭' else if (i == bh - 1) '╰' else '│', P.rule, P.def, 0);
            s.set(y0 + i, x0 + bw - 1, if (i == 0) '╮' else if (i == bh - 1) '╯' else '│', P.rule, P.def, 0);
        }
        _ = s.put(y0, x0 + 3, " keys ", P.accent, P.def, BOLD);
        _ = s.put(y0 + bh - 1, x0 + bw -| 18, " any key closes ", P.faint, P.def, 0);
        var y = y0 + 2;
        const ymax = y0 + bh - 2;
        outer: for (help_sections) |sec| {
            if (y >= ymax) break;
            var tb: [32]u8 = undefined;
            const x = s.put(y, x0 + 3, "# ", P.accent, P.def, 0);
            _ = s.put(y, x, std.ascii.lowerString(&tb, sec.title), P.accent, P.def, BOLD);
            y += 1;
            for (sec.keys) |kv| {
                if (y >= ymax) break :outer;
                _ = s.put(y, x0 + 5, kv[0], P.bright, P.def, BOLD);
                _ = s.putMax(y, x0 + 20, kv[1], P.dim, P.def, 0, bw -| 22);
                y += 1;
            }
            y += 1;
        }
        s.flush(null);
        while (self.input.next(-1) == null) {}
    }

    // ---- actions

    fn addComment(self: *App, v: *View) !void {
        if (v.rows.items.len == 0) return;
        const g = self.gpa;
        const range = v.selection() orelse [2]usize{ v.cursor, v.cursor };
        v.sel = null;
        const path = self.pathOf(v, v.cursor);
        var rows: std.ArrayList(usize) = .empty;
        defer rows.deinit(g);
        var r = range[0];
        while (r <= range[1]) : (r += 1) {
            if (self.anchorable(v, r) and mem.eql(u8, self.pathOf(v, r), path)) try rows.append(g, r);
        }
        if (rows.items.len == 0) {
            self.setMsg("can't comment here", .{});
            return;
        }
        const existing = if (range[0] == range[1]) self.commentAt(v, v.cursor) else null;
        var lb: [600]u8 = undefined;
        var loc: []const u8 = self.locOf(v, rows.items[0], &lb);
        var lb2: [600]u8 = undefined;
        if (rows.items.len > 1) {
            var first: ?u32 = null;
            var last: ?u32 = null;
            for (rows.items) |rr| if (self.lineno(v, rr)) |n| {
                if (first == null) first = n;
                last = n;
            };
            loc = if (first) |fst| std.fmt.bufPrint(&lb2, "{s}:{d}-{d}", .{ path, fst, last.? }) catch path else path;
        }
        var pl: [700]u8 = undefined;
        const plabel = std.fmt.bufPrint(&pl, ":comment {s}", .{loc}) catch ":comment";
        const initial = if (existing) |e| self.comments.items[e].text else "";
        const text = self.prompt(plabel, P.note, initial) orelse return;
        if (text.len == 0) {
            g.free(text);
            return;
        }
        if (existing) |e| {
            g.free(self.comments.items[e].text);
            self.comments.items[e].text = text;
        } else {
            var code: std.ArrayList(u8) = .empty;
            var n_code: usize = 0;
            for (rows.items) |rr| if (self.codeOf(v, rr)) |cl| {
                if (n_code >= 40) break;
                try code.append(g, cl.sign);
                try code.appendSlice(g, cl.text);
                try code.append(g, '\n');
                n_code += 1;
            };
            const k = self.keyOf(v, rows.items[rows.items.len - 1]);
            try self.comments.append(g, .{
                .anchor = .{ .path = try g.dupe(u8, k.path), .k = k.k, .a = k.a, .b = k.b },
                .loc = try g.dupe(u8, loc),
                .code = try code.toOwnedSlice(g),
                .text = text,
            });
        }
        try self.rebuildViews();
        self.setMsg("comment saved · S sends unsent comments to {s}", .{self.agent.name});
    }

    fn deleteComment(self: *App, v: *View) !void {
        if (v.rows.items.len == 0) return;
        const ci = self.commentAt(v, v.cursor) orelse {
            self.setMsg("no unsent comment here", .{});
            return;
        };
        if (self.comments.items[ci].sent) {
            self.setMsg("no unsent comment here", .{});
            return;
        }
        const cm = self.comments.orderedRemove(ci);
        self.gpa.free(cm.anchor.path);
        self.gpa.free(cm.loc);
        self.gpa.free(cm.code);
        self.gpa.free(cm.text);
        try self.rebuildViews();
        self.setMsg("comment deleted", .{});
    }

    fn writeReview(self: *App, buf: []u8) ![]const u8 {
        const g = self.gpa;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(g);
        try out.appendSlice(g, "# Code review feedback (from kibitz)\n\nAddress each comment below. Line numbers refer to the current working tree.\n\n");
        var i: usize = 0;
        for (self.comments.items) |cm| {
            if (cm.sent) continue;
            i += 1;
            try out.print(g, "## {d}. `{s}`\n\n", .{ i, cm.loc });
            if (cm.code.len > 0) try out.print(g, "```diff\n{s}```\n\n", .{cm.code});
            try out.print(g, "**Comment:** {s}\n\n", .{cm.text});
        }
        Io.Dir.cwd().createDirPath(self.io, self.review_dir) catch {};
        const ts = Io.Timestamp.now(self.io, .real).toSeconds();
        const path = try std.fmt.bufPrint(buf, "{s}/review-{d}.md", .{ self.review_dir, ts });
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out.items });
        return path;
    }

    fn sendToAgent(self: *App, text: []const u8) bool {
        const target = self.target orelse return false;
        // single line: a newline would submit early
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        var it = mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |word| {
            if (line.items.len > 0) line.append(self.gpa, ' ') catch return false;
            line.appendSlice(self.gpa, word) catch return false;
        }
        const r1 = self.rexRun("send", &.{ "-b", target, line.items }) orelse return false;
        self.gpa.free(r1.out);
        if (!r1.ok) return false;
        self.io.sleep(Io.Duration.fromMilliseconds(self.agent.submit_ms), .awake) catch {};
        const r2 = self.rexRun("send-key", &.{ "-b", target, "enter" }) orelse return false;
        self.gpa.free(r2.out);
        return r2.ok;
    }

    fn sendAll(self: *App) void {
        var pending: usize = 0;
        for (self.comments.items) |cm| {
            if (!cm.sent) pending += 1;
        }
        if (pending == 0) {
            self.setMsg("nothing to send", .{});
            return;
        }
        var pb: [1024]u8 = undefined;
        const path = self.writeReview(&pb) catch {
            self.setMsg("could not write the review file", .{});
            return;
        };
        if (self.target == null) {
            self.markSent();
            self.setMsg("no agent pane linked — saved {s}", .{path});
            return;
        }
        var mb: [1400]u8 = undefined;
        const m = std.fmt.bufPrint(&mb, "I reviewed your changes in kibitz and left {d} comment(s) in {s} — read that file and address each comment.", .{ pending, path }) catch return;
        if (self.sendToAgent(m)) {
            self.markSent();
            self.setMsg("sent {d} comment(s) to {s}", .{ pending, self.agent.name });
            self.openPanel(true);
        } else {
            self.setMsg("send failed — comments saved to {s}", .{path});
        }
        self.rebuildViews() catch {};
    }

    fn markSent(self: *App) void {
        for (self.comments.items) |*cm| cm.sent = true;
    }

    fn openPanel(self: *App, on: bool) void {
        if (on == self.panel_open.load(.acquire)) return;
        if (!on) self.leaveAgent();
        self.panel_open.store(on, .release);
        // clicks select the panel or the diff while it's open
        writeAll(1, if (on) "\x1b[?1000h\x1b[?1006h" else "\x1b[?1000l\x1b[?1006l");
    }

    /// Start typing into the agent. `prefill` goes into its input unsent.
    fn enterAgent(self: *App, prefill: ?[]const u8) void {
        if (self.target == null) {
            self.setMsg("no agent pane linked (launch with `! kibitz` from your agent)", .{});
            return;
        }
        self.openPanel(true);
        self.agent_focus.store(true, .release);
        self.msg_len = 0;
        const modes = self.agentModes();
        self.applyModes(modes);
        if (modes.focus) self.agentWrite("\x1b[I");
        if (prefill) |text| self.agentWrite(text);
    }

    fn agentModes(self: *App) Modes {
        self.mirror_mu.lockUncancelable(self.io);
        defer self.mirror_mu.unlock(self.io);
        return self.mirror.modes;
    }

    fn leaveAgent(self: *App) void {
        if (!self.agent_focus.load(.acquire)) return;
        self.agent_focus.store(false, .release);
        self.applyModes(.{});
        if (self.agentModes().focus) self.agentWrite("\x1b[O");
        self.scr.force = true;
    }

    /// Mirror the agent's keyboard/paste/mouse modes onto our own terminal.
    fn applyModes(self: *App, want: Modes) void {
        if (std.meta.eql(want, self.applied)) return;
        var buf: [160]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[=0;1u\x1b[>4;0m\x1b[?2004l\x1b[?1l\x1b[?1002l\x1b[?1003l{s}{s}{s}{s}{s}", .{
            if (want.paste) "\x1b[?2004h" else "",
            if (want.app_cursor) "\x1b[?1h" else "",
            if (want.mouse >= 2) "\x1b[?1002h" else "",
            if (want.mouse == 3) "\x1b[?1003h" else "",
            "",
        }) catch return;
        writeAll(1, seq);
        if (want.kitty > 0) {
            var kb: [16]u8 = undefined;
            writeAll(1, std.fmt.bufPrint(&kb, "\x1b[={d};1u", .{want.kitty}) catch "");
        }
        if (want.other_keys > 0) {
            var kb: [16]u8 = undefined;
            writeAll(1, std.fmt.bufPrint(&kb, "\x1b[>4;{d}m", .{want.other_keys}) catch "");
        }
        self.applied = want;
    }

    /// Type raw bytes into the agent's terminal.
    fn agentWrite(self: *App, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const t = self.target orelse return;
        const rex = self.rex orelse return;
        var js: std.ArrayList(u8) = .empty;
        defer js.deinit(self.gpa);
        js.appendSlice(self.gpa, "{\"data\":\"") catch return;
        jsonEscape(self.gpa, &js, bytes) catch return;
        js.appendSlice(self.gpa, "\"}") catch return;
        if (rexJson(self.gpa, self.io, rex, self.session, &.{ "block", "call", "-b", t, "write", js.items })) |out| self.gpa.free(out);
        self.mirror_due.store(true, .release);
    }

    /// While typing into the agent, stdin goes to it untouched, except ctrl+]
    /// and clicks outside the panel (back to kibitz) and our own focus reports.
    fn agentInput(self: *App) void {
        const in = &self.input;
        if (in.len == 0) {
            if (!Input.waitData(30)) return;
            in.readMore();
        }
        var fwd: std.ArrayList(u8) = .empty;
        defer fwd.deinit(self.gpa);
        const b = in.buf[0..in.len];
        var i: usize = 0;
        var leave = false;
        while (i < b.len and !leave) {
            const ch = b[i];
            if (ch == 0 or ch == 0x1d) { // ctrl+space / ctrl+] in legacy encoding
                i += 1;
                leave = true;
            } else if (ch == 0x1b and i + 1 < b.len and b[i + 1] == '[') {
                var j = i + 2;
                while (j < b.len and !(b[j] >= 0x40 and b[j] <= 0x7e)) j += 1;
                if (j >= b.len) {
                    fwd.appendSlice(self.gpa, b[i..]) catch {};
                    i = b.len;
                    break;
                }
                const params = b[i + 2 .. j];
                const final = b[j];
                const seq = b[i .. j + 1];
                i = j + 1;
                if ((final == 'I' or final == 'O') and params.len == 0) continue;
                if (isSwitchKey(params, final)) {
                    leave = true;
                } else if (params.len > 0 and params[0] == '<' and (final == 'M' or final == 'm')) {
                    const ps = params[1..];
                    const ev: Mouse = .{ .b = csiNum(ps, 0, 0), .x = csiNum(ps, 1, 1) -| 1, .y = csiNum(ps, 2, 1) -| 1, .press = final == 'M' };
                    if (self.inPanel(ev)) {
                        self.mouseToAgent(ev, &fwd);
                    } else if (ev.press and ev.b & 0x63 == 0) leave = true;
                } else fwd.appendSlice(self.gpa, seq) catch {};
            } else if (ch >= 0xC0) {
                const need: usize = if (ch >= 0xF0) 4 else if (ch >= 0xE0) 3 else 2;
                if (i + need > b.len) break; // rest of the character hasn't arrived yet
                fwd.appendSlice(self.gpa, b[i .. i + need]) catch {};
                i += need;
            } else {
                fwd.append(self.gpa, ch) catch {};
                i += 1;
            }
        }
        in.consume(i);
        self.agentWrite(fwd.items);
        if (leave) self.leaveAgent();
    }

    fn inPanel(self: *App, ev: Mouse) bool {
        const p = self.pan;
        return p.w > 0 and ev.x >= p.x and ev.x < p.x + p.w and ev.y >= p.y and ev.y < p.y + p.h;
    }

    /// Re-aim a mouse report at the agent's own screen coordinates.
    fn mouseToAgent(self: *App, ev: Mouse, out: *std.ArrayList(u8)) void {
        if (self.agentModes().mouse == 0) return;
        const p = self.pan;
        out.print(self.gpa, "\x1b[<{d};{d};{d}{c}", .{ ev.b, ev.x - p.x + 1, ev.y - p.y + p.row0 + 1, @as(u8, if (ev.press) 'M' else 'm') }) catch {};
    }

    /// Mouse while kibitz has the keys: click the panel to type into the agent,
    /// scroll the diff or the agent under the pointer.
    fn onMouse(self: *App) !void {
        const ev = self.input.mouse;
        const wheel = ev.b & 64 != 0;
        if (self.inPanel(ev)) {
            if (wheel) {
                var fwd: std.ArrayList(u8) = .empty;
                defer fwd.deinit(self.gpa);
                self.mouseToAgent(ev, &fwd);
                self.agentWrite(fwd.items);
            } else if (ev.press and ev.b & 3 == 0) self.enterAgent(null);
            return;
        }
        if (!wheel) return;
        const k: u32 = if (ev.b & 1 == 0) KEY_UP else KEY_DOWN;
        if (self.mode == .files and self.focus == .tree) try self.handleTree(k, 3) else if (self.activeView()) |v| try self.handleList(v, k, 3);
    }

    fn talk(self: *App) void {
        var lb: [600]u8 = undefined;
        const loc = self.location(&lb);
        if (loc.len == 0) return self.enterAgent(null);
        var pb: [700]u8 = undefined;
        const pre = std.fmt.bufPrint(&pb, "[looking at {s}] ", .{loc}) catch return self.enterAgent(null);
        self.enterAgent(pre);
    }

    /// Keep `mirror` in step with the agent's pane: fast while you're typing
    /// into it, slower while you're only watching.
    fn mirrorLoop(self: *App) void {
        var frame: usize = 0;
        var cols: usize = 0;
        var rows: usize = 0;
        while (!self.quit.load(.acquire)) {
            if (self.panel_open.load(.acquire)) {
                var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                defer arena.deinit();
                if (frame % 8 == 0 or cols == 0) if (self.agentSize(arena.allocator())) |sz| {
                    cols = sz[0];
                    rows = sz[1];
                };
                frame += 1;
                if (cols > 0) self.refreshMirror(arena.allocator(), cols, rows);
            }
            var waited: u64 = 0;
            const period: u64 = if (self.agent_focus.load(.acquire)) 25 else if (self.panel_open.load(.acquire)) 200 else 300;
            while (waited < period and !self.mirror_due.swap(false, .acq_rel)) : (waited += 5) {
                self.io.sleep(Io.Duration.fromMilliseconds(5), .awake) catch {};
            }
        }
    }

    fn agentSize(self: *App, arena: Allocator) ?[2]usize {
        const out = rexJson(arena, self.io, self.rex.?, self.session, &.{ "block", "call", "-b", self.target.?, "size" }) orelse return null;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch return null;
        const c2 = jsonGet(v, "columns") orelse return null;
        const r2 = jsonGet(v, "rows") orelse return null;
        if (c2 != .integer or r2 != .integer or c2.integer <= 0 or r2.integer <= 0) return null;
        return .{ @intCast(@min(c2.integer, 1000)), @intCast(@min(r2.integer, 500)) };
    }

    fn refreshMirror(self: *App, arena: Allocator, cols: usize, rows: usize) void {
        const rex = self.rex.?;
        const t = self.target.?;
        const chunk = 98304;
        const head_out = rexJson(arena, self.io, rex, self.session, &.{ "block", "call", "-b", t, "format", "{\"format\":\"vt\",\"extra_cursor\":true,\"extra_modes\":true,\"extra_kitty_keyboard\":true,\"extra_keyboard\":true,\"max_bytes\":98304}" }) orelse return;
        const hv = std.json.parseFromSliceLeaky(std.json.Value, arena, head_out, .{}) catch return;
        const head = jsonStr(hv, "content") orelse return;
        const total: usize = if (jsonGet(hv, "total")) |x| (if (x == .integer and x.integer > 0) @intCast(x.integer) else head.len) else head.len;
        var body = head;
        var cut = false;
        if (total > head.len) {
            // long scrollback: read just the end, where the screen is
            const id = jsonGet(hv, "id") orelse return;
            if (id != .integer) return;
            const off = total -| chunk;
            const args = std.fmt.allocPrint(arena, "{{\"id\":{d},\"offset\":{d},\"max_bytes\":{d}}}", .{ id.integer, off, chunk }) catch return;
            const tail_out = rexJson(arena, self.io, rex, self.session, &.{ "block", "call", "-b", t, "blob_read", args }) orelse return;
            const tv = std.json.parseFromSliceLeaky(std.json.Value, arena, tail_out, .{}) catch return;
            body = jsonStr(tv, "data") orelse return;
            cut = true;
        }
        var m: Mirror = .{};
        parseLeadModes(head, &m.modes);
        parseScreen(self.gpa, body, cut, cols, rows, &m) catch return;
        self.mirror_mu.lockUncancelable(self.io);
        const old = self.mirror.cells;
        self.mirror = m;
        self.mirror_mu.unlock(self.io);
        self.gpa.free(old);
    }

    fn setZoom(self: *App, on: bool) void {
        const b = self.own_block orelse return;
        if (on == self.zoomed) return;
        if (self.rexRun("zoom", &.{ b, if (on) "--on" else "--off" })) |r| self.gpa.free(r.out);
        self.zoomed = on;
    }

    fn openEditor(self: *App) void {
        var path: ?[]const u8 = null;
        var line: u32 = 1;
        if (self.mode == .diff and self.diff.rows.items.len > 0) {
            path = self.pathOf(&self.diff, self.diff.cursor);
            line = self.lineno(&self.diff, self.diff.cursor) orelse 1;
        } else if (self.fv_open) {
            path = self.fv_path;
            line = if (self.fv.rows.items.len > 0) self.lineno(&self.fv, self.fv.cursor) orelse 1 else 1;
        }
        const p = path orelse return;
        const editor_c = c.getenv("VISUAL") orelse c.getenv("EDITOR");
        const editor: []const u8 = if (editor_c) |e| mem.span(e) else "vim";
        const cmd = std.fmt.allocPrint(self.gpa, "{s} +{d} '{s}'", .{ editor, line, p }) catch return;
        defer self.gpa.free(cmd);
        leaveRaw();
        if (std.process.spawn(self.io, .{ .argv = &.{ "/bin/sh", "-c", cmd } })) |child| {
            var ch = child;
            _ = ch.wait(self.io) catch {};
        } else |_| {}
        enterRaw();
        self.scr.force = true;
        _ = self.reload(true) catch {};
    }

    fn toggleMode(self: *App) !void {
        if (self.mode == .diff) {
            if (self.diff.rows.items.len > 0) {
                const p = self.pathOf(&self.diff, self.diff.cursor);
                const n = self.lineno(&self.diff, self.diff.cursor);
                const row = self.diff.rows.items[self.diff.cursor];
                const new_n: ?u32 = if (row.t == .line and self.files[row.fi].lines.items[row.idx].kind != .del) n else null;
                if (Io.Dir.cwd().access(self.io, p, .{})) |_| {
                    try self.openFile(p, new_n);
                    return;
                } else |_| {}
            }
            self.mode = .files;
            self.focus = if (self.fv_open) .viewer else .tree;
        } else {
            self.mode = .diff;
            if (self.fv_open) if (self.changed.get(self.fv_path)) |fi| {
                const n = if (self.fv.rows.items.len > 0) self.lineno(&self.fv, self.fv.cursor) else null;
                const r = if (n) |nn| self.findRow(&self.diff, .{ .path = self.fv_path, .k = .new, .a = nn }) else null;
                self.diff.cursor = r orelse self.file_start.items[fi];
            };
        }
    }

    fn jumpFile(self: *App, d: i32) void {
        const v = &self.diff;
        if (v.rows.items.len == 0) return;
        const fi = v.rows.items[v.cursor].fi;
        const nf = self.files.len;
        if (d < 0 and v.cursor != self.file_start.items[fi]) {
            v.cursor = self.file_start.items[fi];
        } else {
            const next = if (d > 0) (fi + 1) % nf else (fi + nf - 1) % nf;
            v.cursor = self.file_start.items[next];
        }
        v.top = v.cursor -| 1;
    }

    fn jumpChanged(self: *App, d: i32) !void {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.gpa);
        for (self.files) |f| {
            Io.Dir.cwd().access(self.io, f.path, .{}) catch continue;
            try paths.append(self.gpa, f.path);
        }
        if (paths.items.len == 0) return;
        var cur: ?[]const u8 = if (self.fv_open) self.fv_path else null;
        if (self.focus == .tree) if (self.treeCurrent()) |t| {
            cur = self.nodes.items[t.node].path;
        };
        const n = paths.items.len;
        var idx: usize = if (d > 0) 0 else n - 1;
        if (cur) |cp| for (paths.items, 0..) |p, i| if (mem.eql(u8, p, cp)) {
            idx = if (d > 0) (i + 1) % n else (i + n - 1) % n;
            break;
        };
        const target = paths.items[idx];
        if (self.focus == .tree) self.reveal(target) else try self.openFile(target, null);
    }

    fn jumpBlock(self: *App, v: *View, d: i32) void {
        var r: isize = @as(isize, @intCast(v.cursor)) + d;
        while (r >= 0 and r < v.rows.items.len) : (r += d) {
            if (self.blockStart(v, @intCast(r))) {
                v.cursor = @intCast(r);
                return;
            }
        }
    }

    fn matches(self: *App, s: []const u8) bool {
        const q = self.search.items;
        var fold = true;
        for (q) |b| {
            if (std.ascii.isUpper(b)) fold = false;
        }
        if (fold) return containsIgnoreCase(s, q);
        return mem.indexOf(u8, s, q) != null;
    }

    fn doSearch(self: *App, d: i32) void {
        if (self.search.items.len == 0) return;
        if (self.mode == .files and self.focus == .tree) {
            const all = self.all_files;
            if (all.len == 0) return;
            var start: usize = all.len - 1;
            if (self.treeCurrent()) |t| for (all, 0..) |p, i| if (mem.eql(u8, p, self.nodes.items[t.node].path)) {
                start = i;
                break;
            };
            for (1..all.len + 1) |step| {
                const i = if (d > 0) (start + step) % all.len else (start + all.len * 2 - step) % all.len;
                if (self.matches(all[i])) {
                    self.reveal(all[i]);
                    self.setMsg("/{s}", .{self.search.items});
                    return;
                }
            }
            self.setMsg("not found: {s}", .{self.search.items});
            return;
        }
        const v = self.activeView() orelse return;
        const n = v.rows.items.len;
        if (n == 0) return;
        for (1..n + 1) |step| {
            const r = if (d > 0) (v.cursor + step) % n else (v.cursor + n * 2 - step) % n;
            if (self.textOf(v, r)) |s| if (self.matches(s)) {
                v.cursor = r;
                self.setMsg("/{s}", .{self.search.items});
                return;
            };
        }
        self.setMsg("not found: {s}", .{self.search.items});
    }

    fn confirmQuit(self: *App) bool {
        var unsent: usize = 0;
        for (self.comments.items) |cm| {
            if (!cm.sent) unsent += 1;
        }
        if (unsent == 0) return true;
        self.drawFrame();
        const s = &self.scr;
        const y = s.h - 1;
        s.fill(y, 0, s.w, P.fg, P.def);
        var ub: [32]u8 = undefined;
        _ = s.put(y, 0, "▌", P.note, P.def, 0);
        var x = s.put(y, 1, std.fmt.bufPrint(&ub, "{d} unsent", .{unsent}) catch "", P.note, P.def, BOLD) + 3;
        var sb: [48]u8 = undefined;
        const send = std.fmt.bufPrint(&sb, "send to {s} & quit", .{self.agent.key}) catch "send & quit";
        const opts = [_][2][]const u8{ .{ "s", send }, .{ "d", "discard & quit" }, .{ "any", "cancel" } };
        for (opts) |o| {
            x = s.put(y, x, o[0], P.bright, P.def, BOLD);
            x = s.put(y, x + 1, o[1], P.faint, P.def, 0) + 3;
        }
        s.flush(null);
        while (true) {
            const k = self.input.next(-1) orelse continue;
            if (k == 's') {
                self.sendAll();
                return true;
            }
            return k == 'd';
        }
    }

    // ---- main loop

    fn run(self: *App) !void {
        while (true) {
            self.draw();
            if (self.agent_focus.load(.acquire)) {
                self.agentInput();
                // the agent may change keyboard modes mid-session (e.g. a prompt)
                if (self.agent_focus.load(.acquire)) self.applyModes(self.agentModes());
                self.maybeReload();
                continue;
            }
            const k = self.input.next(if (self.panel_open.load(.acquire)) 40 else 250) orelse {
                self.maybeReload();
                continue;
            };
            if (k == 0) continue;
            self.msg_len = 0;
            if (k >= '0' and k <= '9' and (self.count > 0 or k != '0')) {
                self.count = self.count * 10 + (k - '0');
                continue;
            }
            const count: usize = if (self.count > 0) self.count else 1;
            self.count = 0;
            if (self.pending_g) {
                self.pending_g = false;
                if (k == 'g') {
                    if (self.mode == .files and self.focus == .tree) {
                        self.t_cursor = 0;
                    } else if (self.activeView()) |v| v.cursor = 0;
                }
                continue;
            }
            if (try self.handle(k, count)) return;
        }
    }

    fn maybeReload(self: *App) void {
        const t = self.now();
        if (t - self.last_check > 2000) {
            self.last_check = t;
            if (self.reload(false) catch false) self.setMsg("diff changed — reloaded", .{});
        }
    }

    fn handle(self: *App, k: u32, count: usize) !bool {
        const files = self.mode == .files;
        const diffm = self.mode == .diff;
        switch (k) {
            'q', 'Q', 3 => return self.confirmQuit(),
            '?' => self.showHelp(),
            'f' => try self.toggleMode(),
            't' => self.talk(),
            'i', KEY_CSPACE => self.enterAgent(null),
            'S' => self.sendAll(),
            'e' => self.openEditor(),
            'C' => if (self.target != null) self.openPanel(!self.panel_open.load(.acquire)) else self.setMsg("no agent pane linked (launch with `! kibitz` from your agent)", .{}),
            KEY_FOCUS => self.scr.force = true,
            KEY_MOUSE => try self.onMouse(),
            'z' => self.setZoom(!self.zoomed),
            'r' => if (try self.reload(true)) self.setMsg("reloaded", .{}) else self.setMsg("no changes", .{}),
            'g' => self.pending_g = true,
            '/' => {
                const q = self.prompt("/", P.accent, "") orelse return false;
                defer self.gpa.free(q);
                if (q.len > 0) {
                    self.search.clearRetainingCapacity();
                    try self.search.appendSlice(self.gpa, q);
                    self.doSearch(1);
                }
            },
            'n' => self.doSearch(1),
            'N' => self.doSearch(-1),
            else => {
                if (files and self.focus == .tree) {
                    try self.handleTree(k, count);
                } else if (files and (k == 'h' or k == KEY_TAB or k == KEY_LEFT or k == KEY_BTAB)) {
                    self.focus = .tree;
                } else if (files and (k == 'J' or k == ']')) {
                    try self.jumpChanged(1);
                } else if (files and (k == 'K' or k == '[')) {
                    try self.jumpChanged(-1);
                } else if (diffm and (k == 'J' or k == KEY_TAB)) {
                    for (0..count) |_| self.jumpFile(1);
                } else if (diffm and (k == 'K' or k == KEY_BTAB)) {
                    for (0..count) |_| self.jumpFile(-1);
                } else if (diffm and k == 's') {
                    self.sidebar = !self.sidebar;
                } else if (diffm and (k == KEY_ENTER or k == '\n')) {
                    try self.toggleMode();
                } else if (self.activeView()) |v| {
                    try self.handleList(v, k, count);
                }
            },
        }
        return false;
    }

    fn moveBy(v: *View, n: usize, delta: isize) void {
        if (n == 0) return;
        const cur: isize = @intCast(v.cursor);
        const nxt = std.math.clamp(cur + delta, 0, @as(isize, @intCast(n - 1)));
        v.cursor = @intCast(nxt);
    }

    fn handleList(self: *App, v: *View, k: u32, count: usize) !void {
        const n = v.rows.items.len;
        const cnt: isize = @intCast(count);
        const page: isize = @intCast(self.page);
        const half: isize = @max(1, @divTrunc(page, 2));
        switch (k) {
            'j', KEY_DOWN => moveBy(v, n, cnt),
            'k', KEY_UP => moveBy(v, n, -cnt),
            4, 21, 6, 2, ' ', KEY_PGDN, KEY_PGUP => {
                const delta: isize = switch (k) {
                    4 => half,
                    21 => -half,
                    2, KEY_PGUP => -page,
                    else => page,
                };
                moveBy(v, n, delta);
                const t: isize = @as(isize, @intCast(v.top)) + delta;
                v.top = @intCast(@max(0, t));
            },
            'G', KEY_END => v.cursor = n -| 1,
            KEY_HOME => v.cursor = 0,
            '}' => self.jumpBlock(v, 1),
            '{' => self.jumpBlock(v, -1),
            'L', KEY_RIGHT => v.hscroll += 8 * count,
            'H', KEY_LEFT => v.hscroll -|= 8 * count,
            'v' => v.sel = if (v.sel != null) null else v.cursor,
            KEY_ESC => if (v.sel != null) {
                v.sel = null;
            } else self.openPanel(false),
            'c' => try self.addComment(v),
            'x' => try self.deleteComment(v),
            else => {},
        }
    }

    fn handleTree(self: *App, k: u32, count: usize) !void {
        const rows = self.visible();
        const n = rows.len;
        const page = self.page;
        switch (k) {
            'j', KEY_DOWN => self.t_cursor = @min(n -| 1, self.t_cursor + count),
            'k', KEY_UP => self.t_cursor -|= count,
            4 => self.t_cursor = @min(n -| 1, self.t_cursor + page / 2),
            21 => self.t_cursor -|= page / 2,
            6, KEY_PGDN => self.t_cursor = @min(n -| 1, self.t_cursor + page),
            2, KEY_PGUP => self.t_cursor -|= page,
            'G', KEY_END => self.t_cursor = n -| 1,
            'J', ']' => try self.jumpChanged(1),
            'K', '[' => try self.jumpChanged(-1),
            KEY_TAB => if (self.fv_open) {
                self.focus = .viewer;
            },
            KEY_ESC => self.openPanel(false),
            'l', KEY_ENTER, '\n', KEY_RIGHT, ' ' => {
                if (n == 0) return;
                const node = self.nodes.items[rows[self.t_cursor].node];
                if (!node.is_dir) {
                    try self.openFile(node.path, null);
                } else if (k == 'l' and self.expanded.contains(node.path)) {
                    self.t_cursor = @min(n - 1, self.t_cursor + 1);
                } else {
                    self.setExpanded(node.path, !self.expanded.contains(node.path));
                }
            },
            'h', KEY_LEFT => {
                if (n == 0) return;
                const node = self.nodes.items[rows[self.t_cursor].node];
                if (node.is_dir and self.expanded.contains(node.path)) {
                    self.setExpanded(node.path, false);
                } else if (mem.lastIndexOfScalar(u8, node.path, '/')) |slash| {
                    const parent = node.path[0..slash];
                    for (rows, 0..) |vr, i| if (mem.eql(u8, self.nodes.items[vr.node].path, parent)) {
                        self.t_cursor = i;
                        break;
                    };
                }
            },
            else => {},
        }
    }
};

// ───────────────────────────────────────────── entry

fn usage() void {
    printOut(
        \\usage: kibitz [git diff args...] [--pane] [--no-zoom] [--target BLOCK] [--agent NAME]
        \\
        \\  A vim-style git diff reviewer. From Claude Code, Codex, Pi or Antigravity
        \\  run `! kibitz` (or `! kibitz main`) to open it in a Rex pane next to
        \\  the agent. The agent is detected; --agent claude|codex|pi|agy overrides.
        \\
    , .{});
}

/// Run a rex subcommand scoped to `session`, ignoring the result.
fn rexCmd(gpa: Allocator, io: Io, rex: []const u8, session: []const u8, args: []const []const u8) void {
    if (rexJson(gpa, io, rex, session, args)) |out| gpa.free(out);
}

/// Run a rex subcommand scoped to `session` and return its stdout on success.
fn rexJson(gpa: Allocator, io: Io, rex: []const u8, session: ?[]const u8, args: []const []const u8) ?[]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    // `-s` goes after the full command name: `rex block ls -s S`, `rex zoom -s S`
    const words: usize = for ([_][]const u8{ "block", "window", "session" }) |grp| {
        if (mem.eql(u8, args[0], grp)) break 2;
    } else 1;
    argv.append(gpa, rex) catch return null;
    argv.appendSlice(gpa, args[0..words]) catch return null;
    if (session) |s| argv.appendSlice(gpa, &.{ "-s", s }) catch return null;
    argv.appendSlice(gpa, args[words..]) catch return null;
    const r = runCmd(gpa, io, argv.items) orelse return null;
    if (!r.ok) {
        gpa.free(r.out);
        return null;
    }
    return r.out;
}

fn jsonGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(key) else null;
}

fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = jsonGet(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

fn jsonArr(v: std.json.Value, key: []const u8) []const std.json.Value {
    const x = jsonGet(v, key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

/// The pane the agent runs in. Strings live in the arena.
const AgentPane = struct { session: []const u8, block: []const u8, agent: *const Agent };

/// kibitz's ancestor pids, nearest first.
fn ancestors(gpa: Allocator, io: Io, buf: []c.pid_t) []c.pid_t {
    var n: usize = 0;
    var pid: c.pid_t = c.getppid();
    while (n < buf.len and pid > 1) {
        buf[n] = pid;
        n += 1;
        var pb: [16]u8 = undefined;
        const ps = std.fmt.bufPrint(&pb, "{d}", .{pid}) catch break;
        const r = runCmd(gpa, io, &.{ "ps", "-o", "ppid=", "-p", ps }) orelse break;
        defer gpa.free(r.out);
        pid = std.fmt.parseInt(c.pid_t, mem.trim(u8, r.out, " \n"), 10) catch break;
    }
    return buf[0..n];
}

/// Which agent a pane's foreground process is, from Rex's `process` method.
fn agentOfProcess(gpa: Allocator, io: Io, fg: std.json.Value) ?*const Agent {
    for ([_][]const u8{ "argv0", "invoked_path", "path", "name" }) |key| {
        if (jsonStr(fg, key)) |p| if (agentOfCommand(p)) |a| return a;
    }
    // node/bun scripts (pi) only show up in the full command line
    const pid = jsonGet(fg, "pid") orelse return null;
    if (pid != .integer) return null;
    var pb: [24]u8 = undefined;
    const ps = std.fmt.bufPrint(&pb, "{d}", .{pid.integer}) catch return null;
    const r = runCmd(gpa, io, &.{ "ps", "-o", "command=", "-p", ps }) orelse return null;
    defer gpa.free(r.out);
    return agentOfCommand(mem.trim(u8, r.out, " \n"));
}

/// Find the agent pane `! kibitz` was typed into. REX_BLOCK can't be trusted:
/// Codex runs `!` commands in a long-lived daemon that keeps the environment
/// of whichever pane started it. So look at every terminal pane's foreground
/// process and prefer, in order: an agent that is our own ancestor, then the
/// focused pane of the active window, then one working in this repo.
fn findAgentPane(arena: Allocator, io: Io, rex: []const u8, root: []const u8, want: ?*const Agent) ?AgentPane {
    var pid_buf: [32]c.pid_t = undefined;
    const anc = ancestors(arena, io, &pid_buf);
    const sessions_out = rexJson(arena, io, rex, null, &.{ "ls", "--json" }) orelse return null;
    const sessions = std.json.parseFromSliceLeaky(std.json.Value, arena, sessions_out, .{}) catch return null;
    var best: ?AgentPane = null;
    var best_score: i32 = -1;
    for (jsonArr(sessions, "sessions")) |sv| {
        const sid = jsonStr(sv, "session_id") orelse continue;
        var focused: []const u8 = "";
        if (rexJson(arena, io, rex, sid, &.{ "window", "ls", "--json" })) |out| {
            const wl = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch null;
            if (wl) |w| {
                const active = jsonStr(w, "active_window_id") orelse "";
                for (jsonArr(w, "windows")) |win| {
                    if (mem.eql(u8, jsonStr(win, "window_id") orelse "", active)) focused = jsonStr(win, "focused_block_id") orelse "";
                }
            }
        }
        const bl_out = rexJson(arena, io, rex, sid, &.{ "block", "ls", "--json" }) orelse continue;
        const bl = std.json.parseFromSliceLeaky(std.json.Value, arena, bl_out, .{}) catch continue;
        for (jsonArr(bl, "blocks")) |bv| {
            const bid = jsonStr(bv, "block_id") orelse continue;
            if (mem.indexOf(u8, jsonStr(bv, "flavor") orelse "", "terminal") == null) continue;
            const pout = rexJson(arena, io, rex, sid, &.{ "block", "call", "-b", bid, "process" }) orelse continue;
            const pv = std.json.parseFromSliceLeaky(std.json.Value, arena, pout, .{}) catch continue;
            const fg = jsonGet(pv, "foreground") orelse continue;
            const agent = agentOfProcess(arena, io, fg) orelse continue;
            if (want) |w| if (w != agent) continue;
            var score: i32 = 0;
            if (jsonGet(fg, "pid")) |p| if (p == .integer) {
                for (anc) |a| if (a == p.integer) {
                    score += 100;
                };
            };
            if (mem.eql(u8, bid, focused)) score += 10;
            if (jsonStr(fg, "cwd")) |cwd| if (mem.startsWith(u8, root, cwd)) {
                score += 1;
            };
            if (score > best_score) {
                best_score = score;
                best = .{ .session = sid, .block = bid, .agent = agent };
            }
        }
    }
    return best;
}

/// ID of a block in `session` with exactly this label. Lives in the arena.
fn findBlock(arena: Allocator, io: Io, rex: []const u8, session: []const u8, label: []const u8) ?[]const u8 {
    const out = rexJson(arena, io, rex, session, &.{ "block", "ls", "--json" }) orelse return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch return null;
    for (jsonArr(v, "blocks")) |b| {
        if (mem.eql(u8, jsonStr(b, "label") orelse "", label)) return jsonStr(b, "block_id");
    }
    return null;
}

fn launchPane(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, rex_opt: ?[]const u8, revs: []const []const u8, no_zoom: bool, root: []const u8, agent_arg: ?[]const u8) !u8 {
    const rex = rex_opt orelse {
        printOut("kibitz needs a terminal. Run it in a terminal, or inside Rex so it can open a pane next to your agent.\n", .{});
        return 1;
    };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const want: ?*const Agent = if (agent_arg) |a| agentByKey(a) else null;
    const pane: AgentPane = findAgentPane(arena, io, rex, root, want) orelse blk: {
        // no agent found: fall back to whatever pane we were started from
        const block = env.get("REX_BLOCK") orelse "";
        const session = env.get("REX_SESSION") orelse "";
        if (block.len == 0 or session.len == 0) {
            printOut("kibitz: could not find your agent's pane. Run it from Claude Code, Codex, Pi or Antigravity inside Rex.\n", .{});
            return 1;
        }
        break :blk .{ .session = session, .block = block, .agent = want orelse &generic_agent };
    };
    // label the pane by its revisions so `! kibitz` finds the same review again
    var label: std.ArrayList(u8) = .empty;
    try label.appendSlice(arena, "kibitz");
    for (revs) |r| {
        try label.append(arena, ' ');
        try label.appendSlice(arena, r);
    }
    if (findBlock(arena, io, rex, pane.session, label.items)) |existing| {
        if (!no_zoom) rexCmd(arena, io, rex, pane.session, &.{ "zoom", existing, "--on" });
        rexCmd(arena, io, rex, pane.session, &.{ "focus", existing });
        printOut("back in kibitz.\n", .{});
        return 0;
    }
    const exe = try std.process.executablePathAlloc(io, arena);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "split", "--json", "-b", pane.block, "--split=right", "--ratio", "55", "-c", root, "--label", label.items, "--", exe, "--target", pane.block, "--session", pane.session });
    if (pane.agent != &generic_agent) try argv.appendSlice(arena, &.{ "--agent", pane.agent.key });
    try argv.appendSlice(arena, revs);
    if (no_zoom) try argv.append(arena, "--no-zoom");
    const out = rexJson(arena, io, rex, pane.session, argv.items) orelse {
        printOut("kibitz: could not open a pane\n", .{});
        return 1;
    };
    if (!no_zoom) {
        // the new block is the first ID under "block_ids", however deep it sits
        if (mem.indexOf(u8, out, "\"block_ids\"")) |i| {
            if (mem.indexOfScalarPos(u8, out, i + 11, '"')) |q1| if (mem.indexOfScalarPos(u8, out, q1 + 1, '"')) |q2| {
                rexCmd(arena, io, rex, pane.session, &.{ "zoom", out[q1 + 1 .. q2], "--on" });
            };
        }
    }
    printOut("kibitz opened next to {s}. Comments you send will arrive here.\n", .{pane.agent.name});
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var revs: std.ArrayList([]const u8) = .empty;
    var target: ?[]const u8 = null;
    var pane = false;
    var no_zoom = false;
    var agent_arg: ?[]const u8 = null;
    var session_arg: ?[]const u8 = null;
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        if (mem.eql(u8, arg, "--target")) {
            target = it.next();
        } else if (mem.eql(u8, arg, "--session")) {
            session_arg = it.next();
        } else if (mem.eql(u8, arg, "--agent")) {
            agent_arg = it.next();
            if (agent_arg == null or agentByKey(agent_arg.?) == null) {
                printErr("kibitz: --agent takes one of claude, codex, pi, agy\n", .{});
                return 2;
            }
        } else if (mem.eql(u8, arg, "--pane")) {
            pane = true;
        } else if (mem.eql(u8, arg, "--no-zoom")) {
            no_zoom = true;
        } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            usage();
            return 0;
        } else {
            try revs.append(gpa, arg);
        }
    }

    const top = runCmd(gpa, io, &.{ "git", "rev-parse", "--show-toplevel" });
    if (top == null or !top.?.ok) {
        printErr("kibitz: not inside a git repository. cd into one first (e.g. `! cd ~/code/app && kibitz`).\n", .{});
        return 1;
    }
    const root = mem.trimEnd(u8, top.?.out, "\n");
    const root_z = try gpa.dupeSentinel(u8, root, 0);
    if (c.chdir(root_z) != 0) return 1; // diff paths are repo-relative

    const rex = findInPath(gpa, io, env, "rex");
    if (pane or c.isatty(1) == 0) return launchPane(gpa, io, env, rex, revs.items, no_zoom, root, agent_arg);
    if (c.isatty(0) == 0) {
        printErr("kibitz: stdin is not a terminal\n", .{});
        return 1;
    }

    var app = App{
        .gpa = gpa,
        .io = io,
        .revs = revs.items,
        .target = target,
        .agent = if (agent_arg) |a| agentByKey(a).? else &generic_agent,
        .session = session_arg orelse env.get("REX_SESSION"),
        .own_block = env.get("REX_BLOCK"),
        .rex = rex,
        .zoomed = target != null and !no_zoom,
        .scr = .{ .gpa = gpa, .truecolor = blk: {
            const ct = env.get("COLORTERM") orelse "";
            break :blk mem.indexOf(u8, ct, "truecolor") != null or mem.indexOf(u8, ct, "24bit") != null;
        } },
        .arena = .init(gpa),
        .fv_arena = .init(gpa),
    };
    if (runCmd(gpa, io, &.{ "git", "rev-parse", "--absolute-git-dir" })) |r| {
        app.review_dir = try std.fmt.allocPrint(gpa, "{s}/kibitz", .{mem.trimEnd(u8, r.out, "\n")});
        gpa.free(r.out);
    }
    if (runCmd(gpa, io, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" })) |r| {
        app.branch = if (r.ok) mem.trimEnd(u8, r.out, "\n") else "(no commits)";
    }
    _ = try app.reload(true);

    enterRaw();
    defer leaveRaw();
    const th = if (app.target != null and app.rex != null) std.Thread.spawn(.{}, App.mirrorLoop, .{&app}) catch null else null;
    defer if (th) |t| {
        app.quit.store(true, .release);
        t.join();
    };
    try app.run();
    return 0;
}

// ───────────────────────────────────────────── tests

const testing = std.testing;

const sample_diff =
    \\diff --git a/src/app.py b/src/app.py
    \\index 1111111..2222222 100644
    \\--- a/src/app.py
    \\+++ b/src/app.py
    \\@@ -1,3 +1,4 @@ def main():
    \\ import os
    \\-x = compute(alpha, beta)
    \\+x = compute(alpha, gamma)
    \\+y = 2
    \\ print(x)
    \\diff --git a/new.ts b/new.ts
    \\new file mode 100644
    \\--- /dev/null
    \\+++ b/new.ts
    \\@@ -0,0 +1 @@
    \\+export const a = 1;
    \\diff --git a/old.md b/docs/new.md
    \\similarity index 100%
    \\rename from old.md
    \\rename to docs/new.md
    \\diff --git a/logo.png b/logo.png
    \\Binary files a/logo.png and b/logo.png differ
    \\
;

test "parseDiff: statuses, counts, line numbers and pairing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const files = try parseDiff(arena.allocator(), sample_diff);
    try testing.expectEqual(@as(usize, 4), files.len);

    const app = files[0];
    try testing.expectEqualStrings("src/app.py", app.path);
    try testing.expectEqual(@as(u8, 'M'), app.status);
    try testing.expectEqual(@as(u32, 2), app.adds);
    try testing.expectEqual(@as(u32, 1), app.dels);
    const L = app.lines.items;
    try testing.expectEqual(Kind.hunk, L[0].kind);
    try testing.expectEqualStrings("def main():", L[0].text);
    try testing.expectEqual(Kind.del, L[2].kind);
    try testing.expectEqual(@as(u32, 2), L[2].old);
    try testing.expectEqual(Kind.add, L[3].kind);
    try testing.expectEqual(@as(u32, 2), L[3].new);
    try testing.expectEqual(@as(u32, 3), L[4].new);
    try testing.expectEqual(@as(u32, 3), L[2].pair); // -beta pairs with +gamma
    try testing.expectEqual(@as(u32, 2), L[3].pair);
    try testing.expectEqual(NONE, L[4].pair);

    try testing.expectEqual(@as(u8, 'A'), files[1].status);
    try testing.expectEqualStrings("new.ts", files[1].path);
    try testing.expectEqual(@as(u8, 'R'), files[2].status);
    try testing.expectEqualStrings("old.md", files[2].old_path);
    try testing.expectEqualStrings("docs/new.md", files[2].path);
    try testing.expectEqual(Kind.meta, files[3].lines.items[0].kind);
}

test "computeEmph marks only the changed word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = "x = compute(alpha, beta)";
    const b = "x = compute(alpha, gamma)";
    const res = (try computeEmph(arena.allocator(), testing.allocator, a, b)).?;
    try testing.expectEqual(@as(usize, 1), res[0].len);
    try testing.expectEqualStrings("beta", a[res[0][0].s..res[0][0].e]);
    try testing.expectEqualStrings("gamma", b[res[1][0].s..res[1][0].e]);
    // unrelated lines are not worth highlighting
    try testing.expect((try computeEmph(arena.allocator(), testing.allocator, "abc def", "totally different words here")) == null);
}

test "highlight finds keywords, strings, comments and functions" {
    var spans: std.ArrayList(HSpan) = .empty;
    defer spans.deinit(testing.allocator);
    const line = "def greet(): return \"hi\"  # done";
    try highlight(testing.allocator, line, .hash, &spans);
    var seen: [7]bool = @splat(false);
    for (spans.items) |sp| seen[@backingInt(sp.k)] = true;
    try testing.expect(seen[@backingInt(HKind.kw)]);
    try testing.expect(seen[@backingInt(HKind.func)]);
    try testing.expect(seen[@backingInt(HKind.str)]);
    try testing.expect(seen[@backingInt(HKind.com)]);
    const last = spans.items[spans.items.len - 1];
    try testing.expectEqualStrings("# done", line[last.s..last.e]);
    try testing.expectEqual(Style.none, langStyle("README.md"));
    try testing.expectEqual(Style.hash, langStyle("a/b/Makefile"));
    try testing.expectEqual(Style.slash, langStyle("main.zig"));
}

test "cleanText expands tabs and neutralises control bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("    x", try cleanText(a, "\tx"));
    try testing.expectEqualStrings("ab  c", try cleanText(a, "ab\tc"));
    try testing.expectEqualStrings("a?b", try cleanText(a, "a\x1bb"));
    try testing.expectEqualStrings("ok", try cleanText(a, "ok\r"));
}

test "utf-8 helpers" {
    try testing.expectEqual(@as(u21, 'é'), decode("é").cp);
    try testing.expectEqual(@as(u21, 0xFFFD), decode("\xff").cp);
    try testing.expectEqual(@as(u21, 0xFFFD), decode("\xe2\x82").cp); // truncated sequence
    try testing.expectEqual(@as(usize, 3), cpLen("a─b"));
    try testing.expectEqualStrings("─b", tailCp("a─b", 2));
    try testing.expectEqual(@as(u8, 16), to256(0x000000));
    try testing.expectEqual(@as(u8, 196), to256(0xff0000));
}

test "fuzz: parsers survive arbitrary input" {
    // Diffs, file names and file contents all come from the repo under review,
    // so none of these may crash on hostile bytes. Run in a safety-checked build.
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    const pieces = [_][]const u8{ "diff --git a/x b/y\n", "@@ -1,2 +3,4 @@ f\n", "@@\n", "+", "-", " ", "\\ No newline\n", "rename from \n", "+++ b/\n", "\t", "\n", "\xff\xfe", "é", "─", "\"", "'", "/*", "//", "#", "0x1f" };
    var buf: [2048]u8 = undefined;
    for (0..3000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var n: usize = 0;
        while (n < buf.len - 64) {
            if (rand.boolean()) {
                const p = pieces[rand.uintLessThan(usize, pieces.len)];
                @memcpy(buf[n..][0..p.len], p);
                n += p.len;
            } else {
                const k = rand.uintLessThan(usize, 24);
                rand.bytes(buf[n..][0..k]);
                n += k;
            }
            if (rand.uintLessThan(u8, 40) == 0) break;
        }
        const input = buf[0..n];
        const files = try parseDiff(a, input);
        for (files) |*f| {
            for (f.lines.items, 0..) |l, li| {
                if (l.pair != NONE) _ = try computeEmph(a, testing.allocator, f.lines.items[li].text, f.lines.items[l.pair].text);
            }
        }
        var spans: std.ArrayList(HSpan) = .empty;
        inline for (.{ Style.hash, Style.slash, Style.dash }) |st| try highlight(a, input, st, &spans);
        for (spans.items) |sp| try testing.expect(sp.s <= sp.e and sp.e <= input.len);
        _ = try cleanText(a, input);
        var i: usize = 0;
        while (i < input.len) i += decode(input[i..]).len;
        _ = tailCp(input, rand.uintLessThan(usize, 50));
        _ = langStyle(input);
    }
}

test "agents are recognised from ps command lines" {
    try testing.expectEqualStrings("claude", agentOfCommand("claude --resume").?.key);
    try testing.expectEqualStrings("codex", agentOfCommand("/opt/homebrew/bin/codex").?.key);
    try testing.expectEqualStrings("pi", agentOfCommand("node /usr/local/lib/node_modules/.bin/pi").?.key);
    try testing.expectEqualStrings("agy", agentOfCommand("/Users/me/.local/bin/agy").?.key);
    try testing.expect(agentOfCommand("/bin/zsh -c kibitz") == null);
    try testing.expect(agentOfCommand("node server.js") == null);
    try testing.expectEqualStrings("agy", agentByKey("antigravity").?.key);
    try testing.expectEqualStrings("agy", agentByKey("Antigravity").?.key);
}

test "agent screen is rebuilt from a vt capture" {
    const cap = "\x1b[?25l\x1b[?2004h\r\nold scrollback\r\n\x1b[0m\x1b[1m\x1b[38;2;1;2;3mhi\x1b[0m\x1b[2Cx\r\n\x1b[31m你\x1b[0mz\r\n> \x1b[>4;2m\x1b[3;3H\x1b[=5;1u";
    var m: Mirror = .{};
    parseLeadModes(cap, &m.modes);
    try parseScreen(testing.allocator, cap, false, 8, 3, &m);
    defer testing.allocator.free(m.cells);
    try testing.expect(m.modes.paste and !m.modes.cursor);
    try testing.expectEqual(@as(u8, 5), m.modes.kitty);
    try testing.expectEqual(@as(u8, 2), m.modes.other_keys);
    try testing.expectEqual(@as(u32, 'h'), m.cells[0].ch);
    try testing.expectEqual(@as(Col, 0x010203), m.cells[0].fg);
    try testing.expect(m.cells[0].at & BOLD != 0);
    try testing.expectEqual(@as(u32, 'x'), m.cells[4].ch);
    try testing.expectEqual(@as(u32, 0x4F60), m.cells[8].ch);
    try testing.expectEqual(PAL | 1, m.cells[8].fg);
    try testing.expectEqual(WIDE_CONT, m.cells[9].ch);
    try testing.expectEqual(@as(u32, 'z'), m.cells[10].ch);
    try testing.expectEqual(@as(u32, '>'), m.cells[16].ch);
    try testing.expect(m.cursor == null); // hidden by ?25l
}

test "the panel switch key is recognised in every keyboard encoding" {
    try testing.expect(isSwitchKey("32;5", 'u'));
    try testing.expect(isSwitchKey("27;5;32", '~'));
    try testing.expect(isSwitchKey("93;5", 'u'));
    try testing.expect(!isSwitchKey("32;1", 'u'));
    try testing.expect(!isSwitchKey("32;2", 'u'));
    try testing.expect(!isSwitchKey("97;5", 'u'));
}
