//! §log 日记：每场结束，日志多一行——日期 · 时长 · 月相 · 潮。
//! 软件是蒲团，日志才是你坐出来的东西。

const std = @import("std");
const c = std.c;
const term = @import("term.zig");
const moon = @import("moon.zig");
const consts = @import("consts.zig");

fn env(name: [*:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.span(p);
}

fn logPath(buf: []u8) ?[:0]u8 {
    if (env("XDG_STATE_HOME")) |x| {
        if (x.len > 0) return std.fmt.bufPrintZ(buf, "{s}/aestus/log", .{x}) catch null;
    }
    if (env("HOME")) |h| {
        if (h.len > 0) return std.fmt.bufPrintZ(buf, "{s}/.aestus/log", .{h}) catch null;
    }
    return null;
}

pub fn writeLog(sky: *const moon.Sky, elapsed_sec: u64, completed: bool) void {
    var pbuf: [1024]u8 = undefined;
    const path = logPath(&pbuf) orelse return;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        var dbuf: [1024]u8 = undefined;
        if (i < dbuf.len) {
            @memcpy(dbuf[0..i], path[0..i]);
            dbuf[i] = 0;
            _ = c.mkdir(@ptrCast(dbuf[0..i]), 0o777);
        }
    }
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c_uint, 0o666));
    if (fd < 0) return;
    defer _ = c.close(fd);
    const rising = completed or elapsed_sec < consts.SESSION_SECONDS / 2;
    var line: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "{s} · {d:0>2}min · {s} · {s}·{s}·{s}\n", .{
        sky.date,
        (elapsed_sec + 30) / 60,
        sky.glyph,
        if (sky.spring) "大潮" else "小潮",
        if (rising) "涨" else "落",
        if (completed) "止" else "走",
    }) catch return;
    term.ttyWrite(fd, s);
}

pub fn cmdLog() u8 {
    var pbuf: [1024]u8 = undefined;
    const path = logPath(&pbuf) orelse return 0;
    const fd = c.open(path.ptr, .{}, @as(c_uint, 0));
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        term.ttyWrite(term.STDOUT, buf[0..@intCast(n)]);
    }
    return 0;
}
