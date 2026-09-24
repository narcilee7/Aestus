//! §noise 噪声：手卷 1D value noise——hash 整数格点，smoothstep 插值，两个八度。
//! 谱子里每一个随机数的来历都可见。

fn hash1(i: i64, seed: u64) f32 {
    var x: u64 = @as(u64, @bitCast(i)) +% seed +% 0x9E3779B97F4A7C15;
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    x ^= x >> 31;
    return @as(f32, @floatFromInt(x >> 40)) / 16777216.0;
}

fn vnoise(x: f32, seed: u64) f32 {
    const i: i64 = @intFromFloat(@floor(x));
    const f = x - @as(f32, @floatFromInt(i));
    const u = f * f * (3 - 2 * f);
    const a = hash1(i, seed);
    return a + (hash1(i + 1, seed) - a) * u;
}

pub fn fbm1(x: f32, seed: u64) f32 {
    return 0.62 * vnoise(x, seed) + 0.38 * vnoise(x * 2.13 + 37.7, seed ^ 0xD1B54A32D192ED03);
}
