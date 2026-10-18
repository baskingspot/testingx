//! testingx: a test runner that replaces the built-in one, and benchmarks
//! that sit beside your tests.
//!
//! This file is the library root. The bench side lives in `bench.zig`;
//! the runner side (a `--test-runner` replacement) is still to come.

pub const bench = @import("bench.zig");
pub const benchfmt = @import("benchfmt.zig");

pub const B = bench.B;
pub const Error = bench.Error;
pub const Options = bench.Options;
pub const Result = bench.Result;
pub const Spec = bench.Spec;
pub const benchmark = bench.benchmark;
pub const benchMain = bench.benchMain;

pub const filter = @import("filter.zig");
pub const Timer = @import("timer.zig").Timer;

test {
    // The build test step compiles this root; reference every module so its
    // tests are analyzed and run.
    _ = bench;
    _ = benchfmt;
    _ = filter;
    _ = @import("timer.zig");
}
