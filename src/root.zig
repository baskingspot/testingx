//! testingx: a test runner that replaces the built-in one, and benchmarks
//! that sit beside your tests.
//!
//! This file is the library root. The bench side lives in `bench.zig`.
//! `runner.zig` is the `--test-runner` replacement and compiles as its own
//! module.

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

pub const fixtures = @import("fixtures.zig").fixtures;
pub const b64 = @import("fixtures.zig").b64;
pub const hex = @import("fixtures.zig").hex;
pub const Fixture = @import("fixtures.zig").Fixture;

test {
    // The build test step compiles this root; reference every module so its
    // tests are analyzed and run.
    _ = bench;
    _ = benchfmt;
    _ = filter;
    _ = @import("perfcounter.zig");
    _ = @import("symbols.zig");
    _ = @import("fixtures.zig");
    _ = @import("timer.zig");
}
