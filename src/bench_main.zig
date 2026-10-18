//! Generated into each consumer's bench executable by `addBench` in
//! build.zig. The suite root is injected as the `bench_root` import and
//! must expose `pub fn benchmarkMain(b: *testingx.B) !void`.

const std = @import("std");
const testingx = @import("testingx");
const root = @import("bench_root");

pub fn main(init: std.process.Init) !u8 {
    return testingx.benchMain(root, init);
}
