const std = @import("std");

pub const BenchOptions = struct {
    name: []const u8 = "bench",
    module: *std.Build.Module,
    root_source_file: std.Build.LazyPath,
    target: ?std.Build.ResolvedTarget = null,
    /// Benchmarks in Debug are noise; the default matches the Go ecosystem's
    /// expectation that benchmarks run optimized.
    optimize: std.builtin.OptimizeMode = .ReleaseFast,
};

/// Build the benchmark executable for a suite: a generated main that calls
/// `benchmarkMain` in the suite root. The suite root is the file that
/// declares the suite; it imports `testingx` like any other module.
/// Use this for `bench-bin`-style steps: install for perf, disassembly.
pub fn addBenchExe(b: *std.Build, options: BenchOptions) *std.Build.Step.Compile {
    const target = options.target orelse b.graph.host;

    const suite_module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = options.optimize,
    });
    suite_module.addImport("testingx", options.module);

    const write_files = b.addWriteFiles();
    const main_source = write_files.add("bench-main.zig", @embedFile("src/bench_main.zig"));

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = main_source,
            .target = target,
            .optimize = options.optimize,
        }),
    });
    exe.root_module.addImport("testingx", options.module);
    exe.root_module.addImport("bench_root", suite_module);
    return exe;
}

/// Create the run step for a benchmark suite: `zig build bench`.
/// Pass flags to the binary after `--`, e.g. `zig build bench -- --benchtime=10x`.
pub fn addBench(b: *std.Build, options: BenchOptions) *std.Build.Step.Run {
    return b.addRunArtifact(addBenchExe(b, options));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("testingx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // Self-host: benchmark the library with itself, ReleaseFast.
    const run_bench = addBench(b, .{
        .module = mod,
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
    });
    if (b.args) |args| run_bench.addArgs(args);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    const check = b.step("check", "Compile tests and the benchmark executable without running");
    check.dependOn(&tests.step);
    check.dependOn(&addBenchExe(b, .{
        .module = mod,
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
    }).step);
}
