//! The testingx self-host benchmark suite.

const std = @import("std");

const testingx = @import("testingx");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(@import("filter.zig"));
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
