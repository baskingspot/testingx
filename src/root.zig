//! testingx: a test runner that replaces the built-in one, and benchmarks
//! that sit beside your tests.
//!
//! This file is the library root. The bench side lives in `bench.zig`.
//! `runner.zig` is the `--test-runner` replacement and compiles as its own
//! module.

const std = @import("std");
const testing = std.testing;

pub const bench = @import("bench.zig");
pub const benchfmt = @import("benchfmt.zig");

pub const B = bench.B;
pub const Error = bench.Error;
pub const Options = bench.Options;
pub const Result = bench.Result;
pub const Spec = bench.Spec;
pub const Function = bench.Function;
pub const benchmark = bench.benchmark;
pub const benchMain = bench.benchMain;

pub const filter = @import("filter.zig");
pub const Timer = @import("timer.zig").Timer;

pub const artifacts = @import("artifacts.zig");
pub const artifactDir = artifacts.artifactDir;
pub const writeArtifact = artifacts.writeArtifact;
pub const txtar = @import("txtar.zig");

pub const fixtures = @import("fixtures.zig").fixtures;
pub const b64 = @import("fixtures.zig").b64;
pub const hex = @import("fixtures.zig").hex;
pub const Fixture = @import("fixtures.zig").Fixture;

/// Adapt `std.testing.fuzz` to a byte-slice target.
///
/// Fills a `max_len` stack buffer with bytes from the fuzzer's `Smith` and
/// calls `testOne` with the filled slice. `max_len` is comptime because it
/// sizes that buffer. Under testingx's runner the adapter replays
/// `options.corpus` and one empty input. Under the built-in runner in fuzz
/// mode it mutates.
pub fn fuzzBytes(
    context: anytype,
    comptime max_len: usize,
    comptime testOne: fn (@TypeOf(context), []const u8) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    const Wrapper = struct {
        fn run(ctx: @TypeOf(context), smith: *testing.Smith) anyerror!void {
            var buffer: [max_len]u8 = undefined;
            const len = smith.slice(&buffer);
            return testOne(ctx, buffer[0..len]);
        }
    };
    return testing.fuzz(context, Wrapper.run, options);
}

test {
    // The build test step compiles this root; reference every module so its
    // tests are analyzed and run.
    _ = bench;
    _ = benchfmt;
    _ = filter;
    _ = @import("perfcounter.zig");
    _ = @import("symbols.zig");
    _ = @import("artifacts.zig");
    _ = @import("txtar.zig");
    _ = @import("fixtures.zig");
    _ = @import("timer.zig");
}
