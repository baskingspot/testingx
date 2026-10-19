//! The testingx self-host benchmark suite.

const testingx = @import("testingx");

const filter_bench = @import("filter.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(filter_bench);
    try b.add("Timer/now-pair", benchmarkTimerNowPair);
}

fn benchmarkTimerNowPair(b: *testingx.B) !void {
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const a: testingx.Timer = .start(b.io);
        sink +|= a.read();
    }
}
