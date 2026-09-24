//! §term 终端：备用屏、raw mode、色彩分级、输出缓冲。
//! 退出路径统一走 Term.leave——任何路径下终端都不被遗弃，包括 panic。

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const c = std.c;

pub const STDIN: c.fd_t = 0;
pub const STDOUT: c.fd_t = 1;
pub const STDERR: c.fd_t = 2;

pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const Mode = enum { truecolor, ansi256, mono };
pub var mode: Mode = .mono;

// ── 输出缓冲：一帧的所有字节攒齐，一次 write 交给终端 ──

var obuf: [6 << 20]u8 = undefined;
var olen: usize = 0;
var cur_fg: ?Rgb = null;
var cur_bg: ?Rgb = null;

pub fn out(s: []const u8) void {
    if (olen + s.len > obuf.len) flushOut();
    @memcpy(obuf[olen..][0..s.len], s);
    olen += s.len;
}

pub fn outFmt(comptime fmt: []const u8, args: anytype) void {
    var b: [64]u8 = undefined;
    out(std.fmt.bufPrint(&b, fmt, args) catch return);
}

pub fn flushOut() void {
    ttyWrite(STDOUT, obuf[0..olen]);
    olen = 0;
}

pub fn ttyWrite(fd: c.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

pub fn cur(r: u16, col: u16) void {
    outFmt("\x1b[{d};{d}H", .{ r + 1, col + 1 });
}

pub fn repeat(ch: []const u8, n: u16) void {
    var i: u16 = 0;
    while (i < n) : (i += 1) out(ch);
}

// ── 属性缓存：颜色没变就不重复发转义序列 ──

fn rgbEq(a: ?Rgb, b: ?Rgb) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b;
}

pub fn attrReset() void {
    if (cur_fg != null or cur_bg != null) {
        out("\x1b[0m");
        cur_fg = null;
        cur_bg = null;
    }
}

fn applyAttrs(fg: ?Rgb, bg: ?Rgb) void {
    if (mode == .mono) {
        attrReset();
        return;
    }
    if ((!rgbEq(cur_fg, fg) and fg == null) or (!rgbEq(cur_bg, bg) and bg == null)) {
        out("\x1b[0m");
        cur_fg = null;
        cur_bg = null;
    }
    if (fg) |col| {
        if (!rgbEq(cur_fg, col)) {
            switch (mode) {
                .truecolor => outFmt("\x1b[38;2;{d};{d};{d}m", .{ col.r, col.g, col.b }),
                .ansi256 => outFmt("\x1b[38;5;{d}m", .{to256(col)}),
                .mono => {},
            }
            cur_fg = col;
        }
    }
    if (bg) |col| {
        if (!rgbEq(cur_bg, col)) {
            switch (mode) {
                .truecolor => outFmt("\x1b[48;2;{d};{d};{d}m", .{ col.r, col.g, col.b }),
                .ansi256 => outFmt("\x1b[48;5;{d}m", .{to256(col)}),
                .mono => {},
            }
            cur_bg = col;
        }
    }
}

pub fn cell(fg: ?Rgb, bg: ?Rgb, ch: []const u8) void {
    applyAttrs(fg, bg);
    out(ch);
}

fn to256(col: Rgb) u8 {
    const r: u16 = @as(u16, col.r) * 5 / 255;
    const g: u16 = @as(u16, col.g) * 5 / 255;
    const b: u16 = @as(u16, col.b) * 5 / 255;
    return @intCast(16 + 36 * r + 6 * g + b);
}

// ── 色彩分级：启动时探测一次，不设用户选项，作品自己适应世界 ──

fn env(name: [*:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.span(p);
}

pub fn detectMode() Mode {
    if (env("COLORTERM")) |v| {
        if (std.mem.eql(u8, v, "truecolor") or std.mem.eql(u8, v, "24bit")) return .truecolor;
    }
    if (env("TERM")) |v| {
        if (std.mem.indexOf(u8, v, "256color") != null) return .ansi256;
    }
    return .mono;
}

// ── 进入与离开 ──

pub const Term = struct {
    orig: posix.termios,

    pub fn enter() !Term {
        const orig = try posix.tcgetattr(STDIN);
        var raw = orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false; // 关键：Ctrl-C 变成一个字节，退出由作品自己签名
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(STDIN, .NOW, raw);
        ttyWrite(STDOUT, "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J\x1b[H");
        return .{ .orig = orig };
    }

    pub fn leave(t: *const Term) void {
        posix.tcsetattr(STDIN, .NOW, t.orig) catch {};
        ttyWrite(STDOUT, "\x1b[0m\x1b[?25h\x1b[?7h\x1b[?1049l");
    }
};

pub fn winSize() posix.winsize {
    var ws = posix.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => _ = c.ioctl(STDIN, 0x40087468, @intFromPtr(&ws)),
        else => _ = std.os.linux.ioctl(STDIN, 0x5413, @intFromPtr(&ws)),
    }
    if (ws.row == 0) ws.row = 24;
    if (ws.col == 0) ws.col = 80;
    return ws;
}

// ── 信号：kill -TERM 与挂断都被如实记下，而不是被粗暴掐死 ──

pub var sig_quit = std.atomic.Value(bool).init(false);

fn onSig(_: posix.SIG) callconv(.c) void {
    sig_quit.store(true, .monotonic);
}

pub fn installSignals() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = onSig },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
}
