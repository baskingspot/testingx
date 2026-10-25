const std = @import("std");

pub const BenchOptions = struct {
    name: []const u8 = "bench",
    module: *std.Build.Module,
    root_source_file: std.Build.LazyPath,
    /// Extra imports for the suite root and the files it reaches. Bench files
    /// that `@import` the consuming package's module need it here: the suite
    /// module is created for them, not shared with the rest of the build.
    imports: []const std.Build.Module.Import = &.{},
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
        .imports = options.imports,
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

    // Self-host: the library's own tests run through our own runner.
    const tests = b.addTest(.{
        .root_module = mod,
        .test_runner = .{ .path = b.path("src/runner.zig"), .mode = .simple },
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true; // always run tests
    run_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    if (b.args) |args| run_tests.addArgs(args);

    const test_step = b.step("test", "Run unit tests and runner checks");
    test_step.dependOn(&run_tests.step);

    // The runner's own tests run under the default runner.
    const runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runner.zig"),
            .target = target,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(runner_tests).step);

    // Fixtures run through our runner; the checks pin exact output and exit codes.
    const fixtures = b.addTest(.{
        .name = "fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures.zig"),
            .target = target,
        }),
        .test_runner = .{ .path = b.path("src/runner.zig"), .mode = .simple },
    });
    addFixtureChecks(b, test_step, fixtures);

    const timeout_fixture = b.addTest(.{
        .name = "timeout-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/timeout.zig"),
            .target = target,
        }),
        .test_runner = .{ .path = b.path("src/runner.zig"), .mode = .simple },
    });
    const timeout_check = addRunnerCheck(b, test_step, timeout_fixture, 1);
    timeout_check.addArg("--timeout=1ms");
    timeout_check.expectStdErrMatch(
        "testingx: timeout after 1ms, stuck in test \"timeout demonstration\"",
    );

    const flaky_fixture = b.addTest(.{
        .name = "flaky-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/flaky.zig"),
            .target = target,
        }),
        .test_runner = .{ .path = b.path("src/runner.zig"), .mode = .simple },
    });
    const flaky_check = addRunnerCheck(b, test_step, flaky_fixture, 0);
    flaky_check.addArg("--rerun-fails=2");
    flaky_check.expectStdErrMatch("--- FAIL: flaky demonstration (");
    flaky_check.expectStdErrMatch("1 flaky");
    flaky_check.expectStdErrMatch("testingx: flaky: flaky demonstration");
    flaky_check.expectStdErrMatch("ALL TESTS PASSED");

    // Retries do not rescue a test that fails every attempt.
    const rerun_still_fails = addRunnerCheck(b, test_step, fixtures, 1);
    rerun_still_fails.addArg("--rerun-fails=2");
    rerun_still_fails.addArg("--filter=intentional failure");
    rerun_still_fails.expectStdErrMatch("0 passed, 1 failed, 0 skipped (of 1 total)");
    rerun_still_fails.expectStdErrMatch("TESTS FAILED");

    const panic_fixture = b.addTest(.{
        .name = "panic-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/panic.zig"),
            .target = target,
        }),
        .test_runner = .{ .path = b.path("src/runner.zig"), .mode = .simple },
    });
    const panic_check = b.addRunArtifact(panic_fixture);
    panic_check.has_side_effects = true;
    panic_check.removeEnvironmentVariable("TESTINGX_EXPECT_SEED");
    panic_check.expectExitCode(1);
    panic_check.expectStdOutEqual("");
    panic_check.expectStdErrMatch("PANIC in test \"panic demonstration\": intentional panic");
    panic_check.expectStdErrMatch("tests/panic.zig");
    test_step.dependOn(&panic_check.step);

    // Self-host: benchmark the library with itself, ReleaseFast.
    const run_bench = addBench(b, .{
        .module = mod,
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
    });
    if (b.args) |args| run_bench.addArgs(args);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // A stable path for one bench binary: what `--disasm` and `perf record`
    // point at. `zig build bench` runs from the cache, which moves.
    const bench_bin = b.addInstallArtifact(addBenchExe(b, .{
        .module = mod,
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
    }), .{});
    const bench_bin_step = b.step(
        "bench-bin",
        "Install zig-out/bin/bench for disassembly and perf",
    );
    bench_bin_step.dependOn(&bench_bin.step);

    const check = b.step("check", "Compile tests and the benchmark executable without running");
    check.dependOn(&tests.step);
    check.dependOn(&addBenchExe(b, .{
        .module = mod,
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
    }).step);
}

fn addFixtureChecks(
    b: *std.Build,
    test_step: *std.Build.Step,
    fixtures: *std.Build.Step.Compile,
) void {
    // Expected failures must not hide new failures in the runner.
    const suite = addRunnerCheck(b, test_step, fixtures, 1);
    suite.addArg("--seed=0x1234");
    suite.setEnvironmentVariable("TESTINGX_EXPECT_SEED", "0x1234");
    suite.expectStdErrMatch("8 passed, 2 failed, 1 skipped, 1 leaked, 1 error logs (of 11 total)");
    suite.expectStdErrMatch("(seed: 0x1234)\nTESTS FAILED\n");
    // Quiet is the default without a terminal: passing tests print nothing,
    // so the first line after the run header is the first failure.
    suite.expectStdErrMatch("testingx: Running 11 tests...\n--- FAIL: intentional failure (");
    suite.expectStdErrMatch("--- FAIL: memory leak detection (");
    suite.expectStdErrMatch("--- FAIL: emits error log but succeeds (");

    const filtered = addRunnerCheck(b, test_step, fixtures, 0);
    filtered.addArg("--filter=fuzz");
    filtered.expectStdErrMatch("3 passed, 0 failed, 0 skipped (of 3 total)");

    const fail_fast = addRunnerCheck(b, test_step, fixtures, 1);
    fail_fast.addArg("--fail-fast");
    fail_fast.expectStdErrMatch("2 passed, 1 failed, 1 skipped (of 11 total)");

    const dots = addRunnerCheck(b, test_step, fixtures, 0);
    dots.addArg("--filter=basic arithmetic");
    dots.addArg("--format=dots");
    dots.expectStdErrMatch("\n.\n");

    const plain = addRunnerCheck(b, test_step, fixtures, 0);
    plain.addArg("--filter=basic arithmetic");
    plain.addArg("--format=verbose");
    plain.addArg("--plain");
    plain.expectStdErrMatch("--- PASS: basic arithmetic passes (");

    // Quiet without a TTY prints no line for a passing test at all.
    const quiet = addRunnerCheck(b, test_step, fixtures, 0);
    quiet.addArg("--filter=basic arithmetic");
    quiet.expectStdErrMatch(
        "testingx: Running 1 test...\ntestingx: 1 passed, 0 failed, 0 skipped (of 1 total)",
    );

    const testname = addRunnerCheck(b, test_step, fixtures, 1);
    testname.addArg("--format=testname");
    testname.addArg("--filter=basic arithmetic,skip demonstration,intentional failure");
    testname.expectStdErrMatch("✔ basic arithmetic passes (");
    testname.expectStdErrMatch("∅ skip demonstration (");
    testname.expectStdErrMatch("✖ intentional failure (");

    const verbose = addRunnerCheck(b, test_step, fixtures, 0);
    verbose.addArg("--format=verbose");
    verbose.addArg("--filter=basic arithmetic");
    verbose.expectStdErrMatch(
        "=== RUN basic arithmetic passes\n--- PASS: basic arithmetic passes (",
    );

    const counted = addRunnerCheck(b, test_step, fixtures, 0);
    counted.addArg("--count=2");
    counted.addArg("--filter=basic arithmetic");
    counted.expectStdErrMatch("2 passed, 0 failed, 0 skipped (of 2 total)");

    // The same shuffle seed must always produce the same order.
    const shuffle_a = addRunnerCheck(b, test_step, fixtures, 0);
    shuffle_a.addArg("--format=testname");
    shuffle_a.addArg("--filter=fuzz");
    shuffle_a.addArg("--shuffle=8");
    shuffle_a.expectStdErrMatch(
        "testingx: Running 3 tests...\n✔ fuzz without a corpus runs an empty smoke test (",
    );

    const shuffle_b = addRunnerCheck(b, test_step, fixtures, 0);
    shuffle_b.addArg("--format=testname");
    shuffle_b.addArg("--filter=fuzz");
    shuffle_b.addArg("--shuffle=8");
    shuffle_b.expectStdErrMatch(
        "testingx: Running 3 tests...\n✔ fuzz without a corpus runs an empty smoke test (",
    );

    const shuffle_off = addRunnerCheck(b, test_step, fixtures, 0);
    shuffle_off.addArg("--format=testname");
    shuffle_off.addArg("--filter=fuzz");
    shuffle_off.addArg("--shuffle=off");
    shuffle_off.expectStdErrMatch("testingx: Running 3 tests...\n✔ fuzz: simple corpus (");

    // The slowest section is a summary section, printed after the status line.
    const slowest = addRunnerCheck(b, test_step, fixtures, 0);
    slowest.addArg("--filter=basic arithmetic,testing.io and environ are initialized");
    slowest.addArg("--slowest=2");
    slowest.expectStdErrMatch("testingx: slowest 2 tests:");
    slowest.expectStdErrMatch("ms  testing.io and environ are initialized\n");
    slowest.expectStdErrMatch("ms  basic arithmetic passes\n");

    // Anchored: the glob grammar, shared with the benchmark filter. Filters
    // match the fully-qualified name.
    const anchored = addRunnerCheck(b, test_step, fixtures, 0);
    anchored.addArg("--filter=^fixtures.test.skip demonstration$");
    anchored.expectStdErrMatch("0 passed, 0 failed, 1 skipped (of 1 total)");

    // A filter that matches nothing fails the run instead of passing silently.
    const empty = addRunnerCheck(b, test_step, fixtures, 1);
    empty.addArg("--filter=no matching test");
    empty.expectStdErrMatch("no tests matched filter");

    // --allow-empty-filter turns that into a passing zero summary, so a build
    // can forward one filter to every test binary.
    const empty_allowed = addRunnerCheck(b, test_step, fixtures, 0);
    empty_allowed.addArg("--filter=no matching test");
    empty_allowed.addArg("--allow-empty-filter");
    empty_allowed.expectStdErrMatch(
        "testingx: 0 passed, 0 failed, 0 skipped (of 0 total) in ",
    );
    empty_allowed.expectStdErrMatch("ALL TESTS PASSED\n");

    // A shared CI workflow can set the same policy through the environment.
    const env_empty_allowed = addRunnerCheck(b, test_step, fixtures, 0);
    env_empty_allowed.setEnvironmentVariable("TESTINGX_ALLOW_EMPTY_FILTER", "1");
    env_empty_allowed.addArg("--filter=no matching test");
    env_empty_allowed.expectStdErrMatch("ALL TESTS PASSED\n");

    // A shared CI workflow can set the format through the environment.
    const env_format = addRunnerCheck(b, test_step, fixtures, 0);
    env_format.setEnvironmentVariable("TESTINGX_FORMAT", "testname");
    env_format.addArg("--filter=basic arithmetic");
    env_format.expectStdErrMatch("✔ basic arithmetic passes");

    // A command-line flag wins over the environment.
    const env_overridden = addRunnerCheck(b, test_step, fixtures, 0);
    env_overridden.setEnvironmentVariable("TESTINGX_FILTER", "no matching test");
    env_overridden.addArg("--filter=basic arithmetic");
    env_overridden.expectStdErrMatch("1 passed, 0 failed, 0 skipped (of 1 total)");
}

fn addRunnerCheck(
    b: *std.Build,
    parent: *std.Build.Step,
    tests: *std.Build.Step.Compile,
    exit_code: u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(tests);
    run.has_side_effects = true;
    // Ambient runner settings must not change what these checks assert.
    for ([_][]const u8{
        "TESTINGX_EXPECT_SEED",
        "TESTINGX_FORMAT",
        "TESTINGX_FILTER",
        "TESTINGX_TIMEOUT",
        "TESTINGX_FAIL_FAST",
        "TESTINGX_ALLOW_EMPTY_FILTER",
        "NO_COLOR",
    }) |key| run.removeEnvironmentVariable(key);
    run.expectExitCode(exit_code);
    run.expectStdOutEqual("");
    parent.dependOn(&run.step);
    return run;
}
