//! §moon 月亮：朔望月 29.530588853 天，参考新月 2000-01-06 18:14 UTC。
//! 引潮力的简谐近似：新月满月大潮，弦月小潮。模型是诗，不是验潮站。

const std = @import("std");
const c = std.c;

const SYNODIC: f64 = 29.530588853;
const NEW_MOON_JD: f64 = 2451550.26;
const MOON_GLYPHS = [8][]const u8{ "●", "◖", "◐", "◒", "○", "◓", "◑", "◗" };

const CTm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime(timep: *const c_long) ?*CTm;

pub const Sky = struct {
    date: [10]u8, // 本地日期，"2026-09-24"
    glyph: []const u8, // 今晚的月相（八档）
    spring: bool, // 大潮？
    cf: f32, // 引潮系数 |cos(2π·月相)|
    seed: u64, // 同天共火性：由日期字符串 hash
};

pub fn computeSky() Sky {
    var rt: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &rt);
    const jd = 2440587.5 + @as(f64, @floatFromInt(rt.sec)) / 86400.0;
    const phase = @mod(jd - NEW_MOON_JD, SYNODIC) / SYNODIC;
    const gi: usize = @intFromFloat(@round(phase * 8.0));
    var date: [10]u8 = "0000-00-00".*;
    if (localtime(&rt.sec)) |tm| {
        _ = std.fmt.bufPrint(&date, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            @as(u16, @intCast(tm.year + 1900)),
            @as(u8, @intCast(tm.mon + 1)),
            @as(u8, @intCast(tm.mday)),
        }) catch {};
    }
    const cf: f32 = @floatCast(@abs(@cos(2 * std.math.pi * phase)));
    return .{
        .date = date,
        .glyph = MOON_GLYPHS[gi % 8],
        .spring = cf >= 0.5,
        .cf = cf,
        .seed = fnv(&date),
    };
}

fn fnv(s: []const u8) u64 {
    var h: u64 = 1469598103934665603;
    for (s) |b| h = (h ^ b) *% 1099511628211;
    return h;
}
