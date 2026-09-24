//! §render 火与潮：解析火焰形 + 噪声扰动，潮线亚像素抗锯齿，水面下的倒影。
//! 其余区域永不绘制——备用屏开箱即黑，黑暗免费。

const std = @import("std");
const term = @import("term.zig");
const noise = @import("noise.zig");
const consts = @import("consts.zig");

const Rgb = term.Rgb;
const MARGIN_OF_SAFETY: u16 = 2; // 火焰底座距最高潮位的行数——海永远够不着火（DESIGN §4「拒绝威胁」）
const BASELINE_PCT: u16 = 68; // 潮线基线在窗口高度的 68% 处
const FLAME_CELLS: u16 = 6; // 火焰高（终端行）
const RAMP = " .:-=+*#%@";

const WATER_TOP = Rgb{ .r = 9, .g = 15, .b = 42 }; // 近黑的蓝：夜海
const WATER_DEEP = Rgb{ .r = 2, .g = 3, .b = 10 };
const FIRE_BLUE = Rgb{ .r = 70, .g = 90, .b = 255 };
const FIRE_ORANGE = Rgb{ .r = 255, .g = 140, .b = 30 };
const FIRE_CORE = Rgb{ .r = 255, .g = 225, .b = 170 };
const FIRE_GLOW = Rgb{ .r = 255, .g = 150, .b = 50 };

pub const Scene = struct {
    w: u16 = 80,
    h: u16 = 24,
    baseline: u16 = 0, // 潮线基线行
    spring_amp: u16 = 2, // 大潮振幅（行）
    amp: f32 = 1, // 今晚的振幅
    fire_base: u16 = 0, // 火焰底座行
    fire_cx: u16 = 0, // 火焰中轴列
    aa_row: u16 = 0, // 上次绘制的潮线行
    aa_high: bool = false, // 潮线在该行上半还是下半
    drawn: bool = false,
    seed: u64, // 火性：由今天的日期 hash
    nonce: u64, // 当场闪烁：每簇火自己活
    warm: i16, // 色温
    gain: f32, // 旺弱

    pub fn resize(s: *Scene, w: u16, h: u16, cf: f32) void {
        s.w = w;
        s.h = h;
        s.baseline = h * BASELINE_PCT / 100;
        s.spring_amp = @max(2, @min(6, h / 10));
        const neap: u16 = @max(1, s.spring_amp / 3);
        s.amp = @as(f32, @floatFromInt(neap)) + @as(f32, @floatFromInt(s.spring_amp - neap)) * cf;
        // 火焰底座固定在最高潮位线之上 MARGIN_OF_SAFETY 行
        s.fire_base = @max(FLAME_CELLS, s.baseline -| s.spring_amp -| MARGIN_OF_SAFETY);
        s.fire_cx = w / 2;
        s.drawn = false;
    }
};

// ── 颜色算术 ──

fn clamp01(x: f32) f32 {
    return @max(0, @min(1, x));
}

fn lerpCh(a: u8, b: u8, t: f32) u8 {
    return @intFromFloat(@as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * t);
}

fn mixRgb(a: Rgb, b: Rgb, t: f32) Rgb {
    return .{ .r = lerpCh(a.r, b.r, t), .g = lerpCh(a.g, b.g, t), .b = lerpCh(a.b, b.b, t) };
}

fn scaleCh(v: u8, k: f32) u8 {
    return @intFromFloat(@min(255, @as(f32, @floatFromInt(v)) * k));
}

fn scaleRgb(a: Rgb, k: f32) Rgb {
    return .{ .r = scaleCh(a.r, k), .g = scaleCh(a.g, k), .b = scaleCh(a.b, k) };
}

fn addRgb(a: Rgb, b: Rgb) Rgb {
    return .{
        .r = @intCast(@min(255, @as(u16, a.r) + b.r)),
        .g = @intCast(@min(255, @as(u16, a.g) + b.g)),
        .b = @intCast(@min(255, @as(u16, a.b) + b.b)),
    };
}

fn depthColor(d: u16) Rgb {
    return mixRgb(WATER_TOP, WATER_DEEP, @min(1, @as(f32, @floatFromInt(d)) / 10));
}

fn rampChar(i: f32) []const u8 {
    const idx: usize = @intFromFloat(clamp01(i) * @as(f32, RAMP.len - 1));
    return RAMP[idx..][0..1];
}

// ── 火焰 ──

const Pix = struct { col: Rgb, i: f32 };

// 火焰的一个半像素：py 0 顶 → 11 底，px 相对中轴
fn flamePixel(s: *const Scene, py: u16, pxi: i32, t: f64) ?Pix {
    const FH: f32 = @floatFromInt(FLAME_CELLS * 2);
    const flick = noise.fbm1(@floatCast(t * 1.9), s.nonce);
    const h_eff = FH * (0.78 + 0.30 * flick);
    const yb = (FH - 1 - @as(f32, @floatFromInt(py))) / h_eff; // 0 底 → 1 尖
    if (yb < 0 or yb > 1) return null;
    const wob = 1.3 * yb * yb * (noise.fbm1(@floatCast(t * 2.3 + yb * 2.0), s.seed) - 0.5) * 2;
    const hw = 2.0 * std.math.pow(f32, 1 - yb, 0.65) + 0.30; // 泪滴
    const rad = @abs(@as(f32, @floatFromInt(pxi)) - wob) / hw;
    if (rad > 1) return null;
    const tex = noise.fbm1(@floatCast(@as(f64, @floatFromInt(pxi)) * 0.9 + @as(f64, @floatFromInt(py)) * 0.6 - t * 3.7), s.nonce +% 7);
    const inten = clamp01((1 - rad * rad) * (0.45 + 0.55 * tex)) * s.gain;
    var col = mixRgb(FIRE_ORANGE, FIRE_CORE, clamp01(inten * 1.15 - 0.10));
    if (yb < 0.15) col = mixRgb(col, FIRE_BLUE, (0.15 - yb) / 0.15 * 0.85); // 底部蓝
    col = scaleRgb(col, 0.25 + 0.75 * inten);
    const warm = s.warm;
    return .{ .col = .{
        .r = @intCast(@min(255, @max(0, @as(i16, col.r) + warm))),
        .g = col.g,
        .b = @intCast(@min(255, @max(0, @as(i16, col.b) - warm))),
    }, .i = inten };
}

fn flameCell(pu: ?Pix, pl: ?Pix) void {
    if (term.mode == .mono) {
        const i = @max(if (pu) |p| p.i else 0, if (pl) |p| p.i else 0);
        term.attrReset();
        term.out(rampChar(i));
        return;
    }
    if (pu != null and pl != null) {
        term.cell(pu.?.col, pl.?.col, "▀"); // half-block：上下两半各一色，纵向分辨率 ×2
    } else if (pu) |p| {
        term.cell(p.col, null, "▀");
    } else if (pl) |p| {
        term.cell(p.col, null, "▄");
    } else {
        term.cell(null, null, " ");
    }
}

fn drawFlame(s: *Scene, t: f64) void {
    const top = s.fire_base + 1 - FLAME_CELLS;
    const c0 = s.fire_cx -| 3;
    const c1 = @min(s.w, s.fire_cx + 4);
    var r: u16 = top;
    while (r <= s.fire_base) : (r += 1) {
        term.cur(r, c0);
        var col = c0;
        while (col < c1) : (col += 1) {
            const px: i32 = @as(i32, col) - @as(i32, s.fire_cx);
            flameCell(
                flamePixel(s, (r - top) * 2, px, t),
                flamePixel(s, (r - top) * 2 + 1, px, t),
            );
        }
    }
}

// ── 潮 ──

fn eraseRow(s: *Scene, r: u16) void {
    term.cur(r, 0);
    term.attrReset();
    term.repeat(" ", s.w);
}

fn drawWater(s: *Scene, aa: u16, high: bool) void {
    if (s.drawn and aa != s.aa_row) {
        if (term.mode == .mono) {
            eraseRow(s, s.aa_row); // mono 的水体是黑暗：旧潮线必须亲手擦去
        } else if (aa > s.aa_row) {
            var r = s.aa_row; // 退潮：把旧海水还给黑暗
            while (r < aa) : (r += 1) eraseRow(s, r);
        }
    }
    term.cur(aa, 0);
    if (term.mode == .mono) {
        term.attrReset();
        term.repeat("~", s.w);
    } else if (high) {
        term.cell(null, depthColor(0), ""); // 潮线没入该行下半，整行皆为水面
        term.repeat(" ", s.w);
    } else {
        term.cell(WATER_TOP, null, ""); // ▄ 的下半格是水面：亚像素抗锯齿
        term.repeat("▄", s.w);
    }
    if (term.mode != .mono) {
        var r = aa + 1;
        while (r < s.h) : (r += 1) {
            term.cur(r, 0);
            term.cell(null, depthColor(r - aa), "");
            term.repeat(" ", s.w);
        }
    }
    s.aa_row = aa;
    s.aa_high = high;
    s.drawn = true;
}

// ── 倒影：火焰正下方水面 cone 内，同一噪声函数的另一个八度，亮度压到三成 ──

fn drawReflection(s: *Scene, t: f64, aa: u16) void {
    const r0 = aa + 1;
    if (r0 >= s.h) return;
    const r1 = @min(s.h, r0 + 8);
    const c0 = s.fire_cx -| 6;
    const c1 = @min(s.w, s.fire_cx + 7);
    var r = r0;
    while (r < r1) : (r += 1) {
        term.cur(r, c0);
        const d: f32 = @floatFromInt(r - r0);
        var col = c0;
        while (col < c1) : (col += 1) {
            const dx: f32 = @floatFromInt(@as(i32, col) - @as(i32, s.fire_cx));
            const cone = 1.0 + 0.5 * d;
            var glow = clamp01(1.0 - @abs(dx) / (cone + 0.5)) / (1.0 + 0.45 * d);
            glow *= 0.30 * (0.35 + 0.65 * noise.fbm1(@floatCast(dx * 0.8 + d * 1.3 + t * 1.5), s.nonce +% 13)) * s.gain;
            if (term.mode == .mono) {
                term.attrReset();
                term.out(rampChar(glow * 2.2));
            } else {
                term.cell(null, addRgb(depthColor(r - aa), scaleRgb(FIRE_GLOW, glow)), " ");
            }
        }
    }
}

pub fn frame(s: *Scene, t: f64) void {
    // h(t) = A·sin(πt/T)：0 → 十分钟涨到 +A → 二十分钟归零。结束处即开始处。
    const hh = s.amp * @as(f32, @floatCast(@sin(std.math.pi * t / @as(f64, @floatFromInt(consts.SESSION_SECONDS)))));
    const wt = @as(f32, @floatFromInt(s.baseline)) - hh;
    const aa: u16 = @intFromFloat(@max(0, @floor(wt)));
    const high = (wt - @as(f32, @floatFromInt(aa))) >= 0.5;
    if (!s.drawn or aa != s.aa_row or high != s.aa_high) drawWater(s, aa, high);
    drawFlame(s, t);
    drawReflection(s, t, aa);
    term.flushOut();
}
