// AESTUS —— 装进终端的冥想。
// 谱子分六段，每段一个文件：
//   consts.zig 作品常数 · term.zig 终端 · moon.zig 月亮
//   noise.zig 噪声 · render.zig 火与潮 · log.zig 日记
// 本文件是 §main 涨落：主循环与两个入口（aestus · aestus log）。

const std = @import("std");
const c = std.c;
const consts = @import("consts.zig");
const term = @import("term.zig");
const moon = @import("moon.zig");
const render = @import("render.zig");
const log = @import("log.zig");

const NS_PER_S: u64 = 1_000_000_000;

fn monoNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * NS_PER_S + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    var ts = c.timespec{ .sec = @intCast(ns / NS_PER_S), .nsec = @intCast(ns % NS_PER_S) };
    _ = c.nanosleep(&ts, null);
}

fn makeNonce() u64 {
    var rt: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &rt);
    return @as(u64, @bitCast(rt.sec)) *% 0x9E3779B97F4A7C15 ^ @as(u64, @intCast(rt.nsec)) ^ (@as(u64, @intCast(c.getpid())) << 32);
}

fn run() u8 {
    var t = term.Term.enter() catch {
        term.ttyWrite(term.STDERR, "aestus 需要一面终端。\n");
        return 1;
    };
    defer t.leave(); // 任何路径下终端都不被遗弃
    term.installSignals();
    term.mode = term.detectMode();
    const sky = moon.computeSky();
    var scene = render.Scene{
        .seed = sky.seed,
        .nonce = makeNonce(),
        .warm = @as(i16, @intCast(sky.seed % 41)) - 20,
        .gain = 0.88 + 0.12 * @as(f32, @floatFromInt((sky.seed >> 8) % 100)) / 100.0,
    };
    const ws = term.winSize();
    scene.resize(ws.col, ws.row, sky.cf);
    const t0 = monoNs();
    const session_ns = consts.SESSION_SECONDS * NS_PER_S;
    const frame_ns = NS_PER_S / consts.FPS;
    var completed = false;
    while (true) {
        const now = monoNs();
        const el = now - t0;
        if (el >= session_ns) {
            completed = true;
            break;
        }
        if (term.sig_quit.load(.monotonic)) break;
        var ib: [16]u8 = undefined;
        const nread = c.read(term.STDIN, &ib, ib.len);
        if (nread > 0) {
            for (ib[0..@intCast(nread)]) |b| {
                if (b == 'q' or b == 3) return finish(&scene, t0, &sky, false);
            }
        }
        const ws2 = term.winSize();
        if (ws2.col != scene.w or ws2.row != scene.h) {
            scene.resize(ws2.col, ws2.row, sky.cf);
            term.out("\x1b[2J"); // resize 是作品的一部分：全屏重绘
        }
        render.frame(&scene, @as(f64, @floatFromInt(el)) / 1e9);
        const spent = monoNs() - now;
        if (spent < frame_ns) sleepNs(frame_ns - spent);
    }
    return finish(&scene, t0, &sky, completed);
}

fn finish(scene: *render.Scene, t0: u64, sky: *const moon.Sky, completed: bool) u8 {
    const elapsed_sec = (monoNs() - t0) / NS_PER_S;
    log.writeLog(sky, elapsed_sec, completed);
    if (completed) {
        sleepNs(2 * NS_PER_S); // 画面静默一拍
        term.out("\x1b[2J");
        term.attrReset();
        term.cur(scene.h / 2, scene.w / 2 -| 3);
        term.out("\x1b[2m");
        term.out(consts.END_LINE); // 一行字浮现
        term.out("\x1b[0m");
        term.flushOut();
        sleepNs(3500 * 1_000_000); // 然后你回到 shell
    }
    return 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var it = init.args.iterate();
    _ = it.next();
    if (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "log")) return log.cmdLog();
        term.ttyWrite(term.STDERR, "用法：aestus · aestus log\n");
        return 1;
    }
    return run();
}
