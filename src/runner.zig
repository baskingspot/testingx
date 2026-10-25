//! testingx: a test runner that replaces the built-in one.
//!
//! Plain text on stderr. The default is quiet without a terminal and dots on
//! one. It replaces the TUI progress display of the built-in runner.
//!
//! Wire it in build.zig:
//!
//!     const testingx = b.dependency("testingx", .{});
//!     const tests = b.addTest(.{
//!         .root_module = my_module,
//!         .test_runner = .{ .path = testingx.path("src/runner.zig"), .mode = .simple },
//!     });
//!     const run_tests = b.addRunArtifact(tests);
//!     run_tests.has_side_effects = true; // always run tests
//!
//! Flags, passed after `zig build test --`:
//!   --seed=N            random seed, printed in the summary for reproduction
//!   --filter=P          only tests whose name matches P; a filter that matches nothing fails
//!   --skip=P            drop tests whose name matches P after --filter selects
//!   --list              print the selected names, one per line, to stdout and exit 0
//!   --allow-empty-filter  a filter that matches nothing prints a zero summary and exits 0
//!   --format=NAME       quiet, dots, testname, or verbose (default: dots on a terminal)
//!   --timeout=D         stop after D like 500ms or 10m (default 10m, off or 0 disables)
//!   --count=N           run the whole suite N times (default 1)
//!   --rerun-fails=N     rerun failed tests up to N attempts (N at least 2); retry passes are flaky
//!   --shuffle=on|off|N  shuffle order: on uses the run seed, N is a fixed seed (default off)
//!   --slowest=N         after the summary, list the N slowest tests
//!   --plain             no colors
//!   --fail-fast         stop at the first failure
//!
//! Environment, for CI policy that a shared workflow sets without editing the
//! repository: TESTINGX_FORMAT, TESTINGX_FILTER, TESTINGX_SKIP,
//! TESTINGX_TIMEOUT, TESTINGX_FAIL_FAST, TESTINGX_ALLOW_EMPTY_FILTER, and
//! NO_COLOR. Command-line flags win over all of them.
//!
//! Filters use the benchmark grammar: plain text contains, ^ anchors start,
//! $ anchors end, * matches any bytes, and commas separate alternatives.
//! Reruns happen inside each --count iteration.

const std = @import("std");
const testing = std.testing;
const debug = std.debug;
const process = std.process;
const Io = std.Io;
const ascii = std.ascii;
const mem = std.mem;
const time = std.time;
const print = debug.print;
const Allocator = mem.Allocator;
const builtin = @import("builtin");

var current_test: ?[]const u8 = null;
var log_err_count: usize = 0;
var run_done: std.atomic.Value(u32) = .init(0);
threadlocal var panicking: bool = false;

/// Error logs fail tests, as they do with the built-in runner.
pub const std_options: std.Options = .{
    .logFn = log,
};

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

pub const panic = debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        // Exit if the stack trace code itself panics.
        if (panicking) {
            process.exit(1);
        }
        panicking = true;

        if (current_test) |ct| {
            print("PANIC in test \"{s}\": {s}\n", .{ ct, msg });
        } else {
            print("PANIC: {s}\n", .{msg});
        }

        debug.dumpCurrentStackTrace(.{
            .first_address = first_trace_addr orelse @returnAddress(),
            .allow_unsafe_unwind = true,
        });
        process.exit(1);
    }
}.panicFn);

const Format = enum { quiet, dots, testname, verbose };

const Shuffle = union(enum) {
    off,
    on,
    seed: u32,
};

const Flags = struct {
    format: ?Format = null,
    plain: bool = false,
    fail_fast: bool = false,
    filter: ?[]const u8 = null,
    skip: ?[]const u8 = null,
    list: bool = false,
    allow_empty_filter: bool = false,
    /// Nanoseconds. Null disables the watchdog.
    timeout_ns: ?u64 = 10 * time.ns_per_min,
    timeout_text: []const u8 = "10m",
    count: usize = 1,
    /// Total attempts allowed for a failed test. 1 means no reruns.
    rerun_fails: usize = 1,
    shuffle: Shuffle = .off,
    slowest: usize = 0,
};

const Parsed = struct {
    flags: Flags = .{},
    seed: ?u32 = null,
};

const EnvOptions = struct {
    format: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    skip: ?[]const u8 = null,
    timeout: ?[]const u8 = null,
    fail_fast: ?[]const u8 = null,
    allow_empty_filter: ?[]const u8 = null,
    no_color: bool = false,
};

/// Build the argument list from the environment and the command line. The
/// variables come first, so a command-line flag wins. Each value becomes one
/// `--flag=value` argument, so a filter with spaces needs no quoting.
fn collectArgs(
    arena: Allocator,
    argv: []const []const u8,
    env: EnvOptions,
) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(arena, argv[0]);
    if (env.format) |value| {
        try args.append(arena, try std.fmt.allocPrint(arena, "--format={s}", .{value}));
    }
    if (env.filter) |value| {
        try args.append(arena, try std.fmt.allocPrint(arena, "--filter={s}", .{value}));
    }
    if (env.skip) |value| {
        try args.append(arena, try std.fmt.allocPrint(arena, "--skip={s}", .{value}));
    }
    if (env.timeout) |value| {
        try args.append(arena, try std.fmt.allocPrint(arena, "--timeout={s}", .{value}));
    }
    if (envBool(env.fail_fast)) |on| {
        if (on) try args.append(arena, "--fail-fast");
    }
    if (envBool(env.allow_empty_filter)) |on| {
        if (on) try args.append(arena, "--allow-empty-filter");
    }
    if (env.no_color) try args.append(arena, "--plain");
    try args.appendSlice(arena, argv[1..]);
    return args.items;
}

/// `1`/`true` and `0`/`false`, case-insensitive. Anything else is unset.
fn envBool(value: ?[]const u8) ?bool {
    const text = value orelse return null;
    if (ascii.eqlIgnoreCase(text, "1") or ascii.eqlIgnoreCase(text, "true")) return true;
    if (ascii.eqlIgnoreCase(text, "0") or ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

/// A missing variable is null. Any other failure to read it is fatal, since
/// the runner cannot tell policy from noise.
fn envGet(
    arena: Allocator,
    environ: std.process.Environ,
    key: []const u8,
) ?[]const u8 {
    return environ.getAlloc(arena, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => @panic("testingx: cannot read the environment"),
    };
}

fn parse(argv: []const []const u8) !Parsed {
    var out: Parsed = .{};
    var i: usize = 1; // skip argv[0]
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (mem.eql(u8, arg, "--plain")) {
            out.flags.plain = true;
        } else if (mem.eql(u8, arg, "--fail-fast")) {
            out.flags.fail_fast = true;
        } else if (mem.eql(u8, arg, "--allow-empty-filter")) {
            out.flags.allow_empty_filter = true;
        } else if (try flagValue(argv, &i, arg, "--filter")) |value| {
            out.flags.filter = value;
        } else if (try flagValue(argv, &i, arg, "--skip")) |value| {
            out.flags.skip = value;
        } else if (mem.eql(u8, arg, "--list")) {
            out.flags.list = true;
        } else if (try flagValue(argv, &i, arg, "--format")) |value| {
            out.flags.format = try parseFormat(value);
        } else if (try flagValue(argv, &i, arg, "--timeout")) |value| {
            out.flags.timeout_ns = try parseTimeout(value);
            out.flags.timeout_text = value;
        } else if (try flagValue(argv, &i, arg, "--count")) |value| {
            out.flags.count = try parseCount(value);
        } else if (try flagValue(argv, &i, arg, "--rerun-fails")) |value| {
            out.flags.rerun_fails = try parseRerunFails(value);
        } else if (try flagValue(argv, &i, arg, "--shuffle")) |value| {
            out.flags.shuffle = try parseShuffle(value);
        } else if (try flagValue(argv, &i, arg, "--slowest")) |value| {
            out.flags.slowest = std.fmt.parseUnsigned(usize, value, 0) catch
                return error.InvalidSlowest;
        } else if (mem.startsWith(u8, arg, "--seed=")) {
            out.seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                return error.InvalidSeed;
        } else return error.UnknownRunnerOption;
    }
    return out;
}

fn flagValue(
    argv: []const []const u8,
    i: *usize,
    arg: []const u8,
    comptime flag: []const u8,
) !?[]const u8 {
    if (mem.eql(u8, arg, flag)) {
        i.* += 1;
        if (i.* >= argv.len) return error.MissingFlagValue;
        return argv[i.*];
    }
    if (mem.startsWith(u8, arg, flag ++ "=")) return arg[flag.len + 1 ..];
    return null;
}

fn parseFormat(value: []const u8) !Format {
    if (mem.eql(u8, value, "quiet")) return .quiet;
    if (mem.eql(u8, value, "dots")) return .dots;
    if (mem.eql(u8, value, "testname")) return .testname;
    if (mem.eql(u8, value, "verbose")) return .verbose;
    return error.InvalidFormat;
}

fn parseCount(value: []const u8) !usize {
    const count = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidCount;
    if (count == 0) return error.InvalidCount;
    return count;
}

fn parseRerunFails(value: []const u8) !usize {
    const attempts = std.fmt.parseUnsigned(usize, value, 10) catch
        return error.InvalidRerunFails;
    if (attempts < 2) return error.InvalidRerunFails;
    return attempts;
}

fn parseShuffle(value: []const u8) !Shuffle {
    if (mem.eql(u8, value, "on")) return .on;
    if (mem.eql(u8, value, "off")) return .off;
    return .{ .seed = std.fmt.parseUnsigned(u32, value, 0) catch
        return error.InvalidShuffle };
}

fn parseTimeout(value: []const u8) !?u64 {
    if (mem.eql(u8, value, "off")) return null;
    const ns = parseDurationNs(value) catch return error.InvalidTimeout;
    return if (ns == 0) null else ns;
}
//
// The benchmark side parses durations in src/bench.zig (parseDurationNs).
// The runner cannot import that file: a test_runner source compiles as its own
// module, and a file cannot be part of two modules. Keep the grammars in sync.
// This copy accepts the same units plus compound durations such as 1m30s.

fn parseDurationNs(s: []const u8) error{InvalidDuration}!u64 {
    if (s.len == 0) return error.InvalidDuration;
    if (mem.eql(u8, s, "0")) return 0;

    var total: f64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const number_start = i;
        while (i < s.len and (ascii.isDigit(s[i]) or s[i] == '.')) : (i += 1) {}
        if (i == number_start) return error.InvalidDuration;
        const number_text = s[number_start..i];
        if (mem.count(u8, number_text, ".") > 1) return error.InvalidDuration;
        const value = std.fmt.parseFloat(f64, number_text) catch return error.InvalidDuration;
        if (!(value >= 0) or value == std.math.inf(f64)) return error.InvalidDuration;

        const unit_start = i;
        while (i < s.len and !ascii.isDigit(s[i]) and s[i] != '.') : (i += 1) {}
        if (i == unit_start) return error.InvalidDuration;
        const scale = durationUnitScale(s[unit_start..i]) orelse return error.InvalidDuration;

        total += value * scale;
        if (total > @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
            return error.InvalidDuration;
        }
    }
    return @intFromFloat(total);
}

fn durationUnitScale(unit: []const u8) ?f64 {
    if (mem.eql(u8, unit, "ns")) return 1;
    if (mem.eql(u8, unit, "us") or mem.eql(u8, unit, "µs")) {
        return @floatFromInt(time.ns_per_us);
    }
    if (mem.eql(u8, unit, "ms")) return @floatFromInt(time.ns_per_ms);
    if (mem.eql(u8, unit, "s")) return @floatFromInt(time.ns_per_s);
    if (mem.eql(u8, unit, "m")) return @floatFromInt(time.ns_per_min);
    if (mem.eql(u8, unit, "h")) return @floatFromInt(time.ns_per_hour);
    return null;
}
// Fisher-Yates with a deterministic PRNG, so the same seed always produces the
// same order. std.Random is part of the standard library, not a repo module,
// so the runner is still self-contained.

fn shuffleIndices(indices: []usize, seed: u32) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    var i = indices.len;
    while (i > 1) {
        i -= 1;
        const j = random.uintLessThan(usize, i + 1);
        mem.swap(usize, &indices[i], &indices[j]);
    }
}

/// Watch the run and kill it if it outlasts the timeout. Main wakes this thread
/// and joins it before returning, so no thread state outlives the process.
fn watchdog(
    timeout_ns: u64,
    timeout_text: []const u8,
    fallback_name: []const u8,
) void {
    // `Init.io` is a local in the startup wrapper and is deinitialized after
    // main returns. This thread is joined before then, but the global instance
    // is still the right one to block on: it has process lifetime, and main
    // wakes the futex through the same instance.
    const io_instance = Io.Threaded.global_single_threaded;
    const io = io_instance.io();
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{
        .raw = .fromNanoseconds(@intCast(timeout_ns)),
        .clock = .awake,
    });

    // The futex wakes on the done flag, the deadline, or spuriously; the
    // timeout is not reported as an error, so both conditions are rechecked.
    while (true) {
        const wait = io.futexWaitTimeout(u32, &run_done.raw, 0, .{ .deadline = deadline });
        wait catch |err| switch (err) {
            error.Canceled => return,
        };
        if (run_done.load(.acquire) == 1) return;
        const now: Io.Clock.Timestamp = .now(io, .awake);
        if (now.compare(.gte, deadline)) break;
    }

    // current_test is set while a test runs. Before the first test it is null,
    // and the run is stuck in that first test's startup, so name it.
    const name = current_test orelse fallback_name;
    print(
        "testingx: timeout after {s}, stuck in test \"{s}\"\n",
        .{ timeout_text, name },
    );
    process.exit(1);
}

pub fn main(init: process.Init) u8 {
    @disableInstrumentation();
    if (builtin.fuzz) {
        @compileError(
            "testingx: fuzz mode needs the default test runner. Disable testingx for --fuzz.",
        );
    }
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch |err|
        process.fatal("testingx: cannot read arguments: {t}", .{err});
    const environ = init.minimal.environ;
    const args = collectArgs(arena, argv, .{
        .format = envGet(arena, environ, "TESTINGX_FORMAT"),
        .filter = envGet(arena, environ, "TESTINGX_FILTER"),
        .skip = envGet(arena, environ, "TESTINGX_SKIP"),
        .timeout = envGet(arena, environ, "TESTINGX_TIMEOUT"),
        .fail_fast = envGet(arena, environ, "TESTINGX_FAIL_FAST"),
        .allow_empty_filter = envGet(arena, environ, "TESTINGX_ALLOW_EMPTY_FILTER"),
        .no_color = if (envGet(arena, environ, "NO_COLOR")) |value| value.len != 0 else false,
    }) catch |err|
        process.fatal("testingx: cannot build the argument list: {t}", .{err});
    const parsed = parse(args) catch |err|
        process.fatal("testingx: cannot parse flags: {t}", .{err});
    if (parsed.seed) |seed| {
        testing.random_seed = seed;
    }
    switch (parsed.flags.shuffle) {
        // Shuffling with no seed would otherwise always use 0. Pick a seed and
        // print it in the summary so the order can be reproduced with --seed.
        .on => if (parsed.seed == null) {
            var seed_bytes: [4]u8 = undefined;
            io.random(&seed_bytes);
            testing.random_seed = mem.readInt(u32, &seed_bytes, .little);
        },
        else => {},
    }

    if (builtin.test_functions.len == 0) {
        print("no tests found\n", .{});
        return 1;
    }

    const have_tty = Io.File.stderr().isTty(io) catch unreachable;
    const plain = parsed.flags.plain or !have_tty;
    const format = parsed.flags.format orelse if (have_tty) Format.dots else Format.quiet;

    // Collect the selected tests once. A filter that matches nothing is a
    // mistake, not a passing run.
    var selected: std.ArrayList(usize) = .empty;
    defer selected.deinit(arena);
    var skipped_by_flag: usize = 0;
    for (builtin.test_functions, 0..) |t, test_idx| {
        if (parsed.flags.filter) |filter| {
            if (!matchesAny(filter, t.name)) continue;
        }
        // Skip is a deliberate exclusion, so it runs after the filter and
        // never turns a filter mismatch into a filter failure.
        if (parsed.flags.skip) |skip| {
            if (matchesAny(skip, t.name)) {
                skipped_by_flag += 1;
                continue;
            }
        }
        selected.append(arena, test_idx) catch |err|
            process.fatal("testingx: cannot collect tests: {t}", .{err});
    }

    // The list is the selection, before anything runs. Names are the fully
    // qualified ones the filters match, so output can feed --filter back.
    if (parsed.flags.list) {
        var buffer: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(io, &buffer);
        for (selected.items) |test_idx| {
            stdout.interface.print("{s}\n", .{builtin.test_functions[test_idx].name}) catch |err|
                process.fatal("testingx: cannot write the test list: {t}", .{err});
        }
        stdout.interface.flush() catch |err|
            process.fatal("testingx: cannot write the test list: {t}", .{err});
        return 0;
    }

    if (selected.items.len == 0) {
        // Skip removed everything the filter selected: an explicit exclusion,
        // so the empty run passes. A filter that matches nothing stays strict.
        if (skipped_by_flag > 0) {
            const skipped_start: Io.Clock.Timestamp = .now(io, .awake);
            printSummary(.{}, 0, skipped_start.untilNow(io).raw);
            print("ALL TESTS PASSED\n", .{});
            return 0;
        }
        // A multi-binary build forwards one set of flags to every binary, so a
        // binary with no matching test must be able to pass. The default stays
        // strict: a typo in a single-binary run still fails.
        if (!parsed.flags.allow_empty_filter) {
            print("no tests matched filter \"{s}\"\n", .{parsed.flags.filter.?});
            return 1;
        }
        const empty_start: Io.Clock.Timestamp = .now(io, .awake);
        printSummary(.{}, 0, empty_start.untilNow(io).raw);
        print("ALL TESTS PASSED\n", .{});
        return 0;
    }

    const shuffle_seed: ?u32 = switch (parsed.flags.shuffle) {
        .off => null,
        .on => testing.random_seed,
        .seed => |seed| seed,
    };
    if (shuffle_seed) |seed| shuffleIndices(selected.items, seed);

    const total = selected.items.len * parsed.flags.count;

    // Per-test maximum elapsed time, indexed by builtin test index. Used only
    // when --slowest is set, but cheap to maintain.
    const slowest_ns = arena.alloc(u64, builtin.test_functions.len) catch |err|
        process.fatal("testingx: cannot allocate slowest list: {t}", .{err});
    @memset(slowest_ns, 0);
    const ran = arena.alloc(bool, builtin.test_functions.len) catch |err|
        process.fatal("testingx: cannot allocate slowest list: {t}", .{err});
    @memset(ran, false);

    var watchdog_thread: ?std.Thread = null;
    if (parsed.flags.timeout_ns) |timeout_ns| {
        // A single-threaded build cannot spawn the watchdog. There is no
        // timeout in that configuration, but the tests still run.
        if (comptime !builtin.single_threaded) {
            const first_name = friendlyName(builtin.test_functions[selected.items[0]].name);
            const spawn_args = .{ timeout_ns, parsed.flags.timeout_text, first_name };
            watchdog_thread = std.Thread.spawn(.{}, watchdog, spawn_args) catch null;
        }
    }

    const start: Io.Clock.Timestamp = .now(io, .awake);

    print("testingx: Running {d} test{s}...\n", .{ total, if (total != 1) "s" else "" });
    if (format == .dots) print("\n", .{});

    var counts: Counts = .{};
    var flaky_tests: std.ArrayList(usize) = .empty;
    defer flaky_tests.deinit(arena);
    const flaky_seen = arena.alloc(bool, builtin.test_functions.len) catch |err|
        process.fatal("testingx: cannot allocate flaky list: {t}", .{err});
    @memset(flaky_seen, false);

    var should_stop = false;
    for (0..parsed.flags.count) |_| {
        if (should_stop) break;
        for (selected.items) |test_idx| {
            const test_fn = builtin.test_functions[test_idx];
            const name = friendlyName(test_fn.name);

            const attempts = runAttempts(.{
                .io = io,
                .arena = arena,
                .minimal = init.minimal,
                .format = format,
                .plain = plain,
                .rerun_fails = parsed.flags.rerun_fails,
            }, test_fn, name);

            ran[test_idx] = true;
            if (attempts.result.elapsed.nanoseconds > slowest_ns[test_idx]) {
                slowest_ns[test_idx] = @intCast(attempts.result.elapsed.nanoseconds);
            }

            if (attempts.flaky) {
                counts.flaky += 1;
                if (!flaky_seen[test_idx]) {
                    flaky_seen[test_idx] = true;
                    flaky_tests.append(arena, test_idx) catch |err|
                        process.fatal("testingx: cannot record a flaky test: {t}", .{err});
                }
            } else switch (attempts.result.outcome) {
                .pass => counts.pass += 1,
                .skip => counts.skip += 1,
                .fail => counts.fail += 1,
            }
            if (attempts.result.leaked) counts.leak += 1;
            counts.log_errs += attempts.result.log_errs;

            if (attempts.result.outcome == .fail and parsed.flags.fail_fast) {
                should_stop = true;
                break;
            }
        }
        if (format == .dots) print("\n", .{});
    }

    // Tests are done. Waking and joining the watchdog here means its thread
    // state is released before the process exits: leak checkers see a clean
    // process, and nothing runs after main's arena dies.
    if (watchdog_thread) |thread| {
        run_done.store(1, .release);
        Io.Threaded.global_single_threaded.io().futexWake(u32, &run_done.raw, 1);
        thread.join();
    }

    const elapsed = start.untilNow(io).raw;

    printSummary(counts, total, elapsed);
    if (counts.flaky > 0) {
        print("testingx: flaky: ", .{});
        for (flaky_tests.items, 0..) |test_idx, idx| {
            if (idx != 0) print(", ", .{});
            print("{s}", .{friendlyName(builtin.test_functions[test_idx].name)});
        }
        print("\n", .{});
    }

    if (counts.fail == 0 and counts.leak == 0 and counts.log_errs == 0) {
        print("ALL TESTS PASSED\n", .{});
    } else {
        print("TESTS FAILED\n", .{});
    }

    if (parsed.flags.slowest > 0) {
        printSlowest(arena, selected.items, slowest_ns, ran, parsed.flags.slowest);
    }

    return if (counts.fail != 0 or counts.leak != 0 or counts.log_errs != 0) 1 else 0;
}

fn printSummary(counts: Counts, total: usize, elapsed: Io.Duration) void {
    print("testingx: {d} passed, {d} failed, {d} skipped", .{
        counts.pass, counts.fail, counts.skip,
    });
    if (counts.flaky > 0) print(", {d} flaky", .{counts.flaky});
    if (counts.leak > 0) print(", {d} leaked", .{counts.leak});
    if (counts.log_errs > 0) print(", {d} error logs", .{counts.log_errs});
    print(" (of {d} total) in {d}ms (seed: 0x{x})\n", .{
        total, elapsed.toMilliseconds(), testing.random_seed,
    });
}

const Counts = struct {
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    flaky: usize = 0,
    leak: usize = 0,
    log_errs: usize = 0,
};

const Outcome = enum { pass, skip, fail };

const RunResult = struct {
    outcome: Outcome,
    err_name: ?[]const u8 = null,
    trace: ?[]const u8 = null,
    log_errs: usize = 0,
    leaked: bool = false,
    elapsed: Io.Duration,
};

const Attempts = struct {
    result: RunResult,
    flaky: bool,
};

const RunOptions = struct {
    io: Io,
    arena: Allocator,
    minimal: process.Init.Minimal,
    format: Format,
    plain: bool,
    rerun_fails: usize,
};

fn runAttempts(options: RunOptions, test_fn: std.builtin.TestFn, name: []const u8) Attempts {
    var had_failure = false;
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        if (options.format == .verbose) print("=== RUN {s}\n", .{name});
        const result = runOne(options, test_fn);
        printResult(options.format, options.plain, name, result);

        const failed = failureLike(result);
        if (failed) had_failure = true;
        if (!failed or attempt >= options.rerun_fails) {
            return .{
                .result = result,
                .flaky = had_failure and !failed and result.outcome == .pass,
            };
        }
    }
}

fn runOne(options: RunOptions, test_fn: std.builtin.TestFn) RunResult {
    current_test = friendlyName(test_fn.name);
    testing.allocator_instance = .{};
    // Keep test I/O allocations separate from the runner's I/O allocations.
    testing.environ = options.minimal.environ;
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(options.minimal.args),
        .environ = options.minimal.environ,
    });
    testing.log_level = .warn;
    log_err_count = 0;

    const test_start: Io.Clock.Timestamp = .now(options.io, .awake);
    // Do not include errors from earlier tests in this test's trace.
    if (@errorReturnTrace()) |trace| trace.index = 0;
    const result = test_fn.func();

    current_test = null;
    // Capture test diagnostics before teardown emits allocator diagnostics.
    const test_log_errs = log_err_count;
    const error_trace = @errorReturnTrace();
    testing.io_instance.deinit();
    const leaked = testing.allocator_instance.deinit() == .leak;
    const elapsed = test_start.untilNow(options.io).raw;

    if (test_log_errs != 0) {
        return .{
            .outcome = .fail,
            .log_errs = test_log_errs,
            .leaked = leaked,
            .elapsed = elapsed,
        };
    }
    if (result) |_| {
        return .{ .outcome = .pass, .leaked = leaked, .elapsed = elapsed };
    } else |err| switch (err) {
        error.SkipZigTest => return .{
            .outcome = .skip,
            .leaked = leaked,
            .elapsed = elapsed,
        },
        else => return .{
            .outcome = .fail,
            .err_name = @errorName(err),
            .trace = if (error_trace) |tr| captureTrace(options.arena, tr) else null,
            .leaked = leaked,
            .elapsed = elapsed,
        },
    }
}

fn failureLike(result: RunResult) bool {
    return result.outcome == .fail or result.log_errs != 0 or result.leaked;
}

fn captureTrace(arena: Allocator, trace: *const std.builtin.StackTrace) ?[]const u8 {
    var buffer: Io.Writer.Allocating = .init(arena);
    const terminal: Io.Terminal = .{ .writer = &buffer.writer, .mode = .no_color };
    debug.writeErrorReturnTrace(trace, terminal) catch return null;
    return buffer.written();
}

const Status = enum { pass, fail, skip, leak };

fn dot(status: Status, plain: bool) void {
    const ch: u8 = switch (status) {
        .pass => '.',
        .fail => 'F',
        .skip => 'S',
        .leak => 'L',
    };
    if (plain) {
        print("{c}", .{ch});
    } else {
        const color = switch (status) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            .leak => "\x1b[31m",
        };
        print("{s}{c}\x1b[0m", .{ color, ch });
    }
}

fn printResult(format: Format, plain: bool, name: []const u8, result: RunResult) void {
    switch (format) {
        .quiet => if (failureLike(result)) printFailureBlock(name, result),
        .dots => printDotResult(name, result, plain),
        .testname => printTestnameResult(name, result, plain),
        .verbose => printVerboseResult(name, result),
    }
}

fn printDotResult(name: []const u8, result: RunResult, plain: bool) void {
    if (failureLike(result)) {
        const status: Status = if (result.outcome == .fail) .fail else .leak;
        dot(status, plain);
        print("\n", .{});
        printFailureBlock(name, result);
    } else {
        dot(switch (result.outcome) {
            .pass => .pass,
            .skip => .skip,
            .fail => .fail,
        }, plain);
    }
}

fn printTestnameResult(name: []const u8, result: RunResult, plain: bool) void {
    const failed = failureLike(result);
    const status: Status = if (failed) .fail else switch (result.outcome) {
        .pass => .pass,
        .skip => .skip,
        .fail => .fail,
    };
    const icon = switch (status) {
        .pass => "✔",
        .skip => "∅",
        .fail => "✖",
        .leak => unreachable,
    };
    const ms = elapsedMs(result.elapsed);
    if (plain) {
        print("{s} {s} ({d:.2}ms)\n", .{ icon, name, ms });
    } else {
        const color = switch (status) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            .leak => "\x1b[31m",
        };
        print("{s}{s} {s} ({d:.2}ms)\x1b[0m\n", .{ color, icon, name, ms });
    }
    if (failed) printFailureBody(result);
}

fn printVerboseResult(name: []const u8, result: RunResult) void {
    const failed = failureLike(result);
    const label = if (failed) "FAIL" else switch (result.outcome) {
        .pass => "PASS",
        .skip => "SKIP",
        .fail => "FAIL",
    };
    print("--- {s}: {s} ({d:.2}ms)\n", .{ label, name, elapsedMs(result.elapsed) });
    if (failed) printFailureBody(result);
}

fn printFailureBlock(name: []const u8, result: RunResult) void {
    print("--- FAIL: {s} ({d:.2}ms)\n", .{ name, elapsedMs(result.elapsed) });
    printFailureBody(result);
}

fn printFailureBody(result: RunResult) void {
    if (result.err_name) |err_name| print("    error.{s}\n", .{err_name});
    if (result.trace) |trace| printIndented(trace);
    if (result.log_errs > 0) {
        print("    {d} error log{s} emitted during test\n", .{
            result.log_errs, if (result.log_errs != 1) "s" else "",
        });
    }
    if (result.leaked) print("    memory leak detected\n", .{});
}

fn printIndented(text: []const u8) void {
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        print("    {s}\n", .{line});
    }
}

fn elapsedMs(elapsed: Io.Duration) f64 {
    return @as(f64, @floatFromInt(elapsed.nanoseconds)) / time.ns_per_ms;
}

const Slowest = struct {
    test_idx: usize,
    ns: u64,
};

fn printSlowest(
    arena: Allocator,
    selected: []const usize,
    slowest_ns: []const u64,
    ran: []const bool,
    limit: usize,
) void {
    var entries: std.ArrayList(Slowest) = .empty;
    defer entries.deinit(arena);
    for (selected) |test_idx| {
        if (!ran[test_idx]) continue;
        entries.append(arena, .{ .test_idx = test_idx, .ns = slowest_ns[test_idx] }) catch return;
    }
    mem.sort(Slowest, entries.items, {}, struct {
        fn lessThan(_: void, a: Slowest, b: Slowest) bool {
            if (a.ns != b.ns) return a.ns > b.ns;
            return a.test_idx < b.test_idx;
        }
    }.lessThan);

    const count = @min(limit, entries.items.len);
    if (count == 0) return;
    print("testingx: slowest {d} test{s}:\n", .{ count, if (count != 1) "s" else "" });
    for (entries.items[0..count]) |entry| {
        const ms = @as(f64, @floatFromInt(entry.ns)) / time.ns_per_ms;
        print("{d:.2}ms  {s}\n", .{
            ms, friendlyName(builtin.test_functions[entry.test_idx].name),
        });
    }
}
//
// The same grammar as src/filter.zig (the benchmark filter): plain text
// contains, ^ anchors start, $ anchors end, * any bytes, commas separate
// alternatives. The runner cannot import that file: a test_runner source
// compiles as its own module, and a file cannot be part of two modules.
// The fixture checks in build.zig pin both sides to the same behavior.

pub fn matches(pattern: []const u8, name: []const u8) bool {
    var glob = pattern;
    const anchor_start = mem.startsWith(u8, glob, "^");
    if (anchor_start) glob = glob[1..];

    const anchor_end = mem.endsWith(u8, glob, "$");
    if (anchor_end) glob = glob[0 .. glob.len - 1];

    if (!mem.containsAtLeast(u8, glob, 1, "*")) {
        if (anchor_start and anchor_end) return mem.eql(u8, name, glob);
        if (anchor_start) return mem.startsWith(u8, name, glob);
        if (anchor_end) return mem.endsWith(u8, name, glob);
        return mem.containsAtLeast(u8, name, 1, glob);
    }

    if (anchor_start and anchor_end) return globMatch(glob, name);
    if (anchor_start) {
        var end: usize = 0;
        while (end <= name.len) : (end += 1) {
            if (globMatch(glob, name[0..end])) return true;
        }
        return false;
    }
    if (anchor_end) {
        var start: usize = 0;
        while (start <= name.len) : (start += 1) {
            if (globMatch(glob, name[start..])) return true;
        }
        return false;
    }

    var start: usize = 0;
    while (start <= name.len) : (start += 1) {
        var end = start;
        while (end <= name.len) : (end += 1) {
            if (globMatch(glob, name[start..end])) return true;
        }
    }
    return false;
}

pub fn matchesAny(patterns: []const u8, name: []const u8) bool {
    var it = mem.splitScalar(u8, patterns, ',');
    while (it.next()) |pattern| {
        const trimmed = mem.trim(u8, pattern, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (matches(trimmed, name)) return true;
    }
    return false;
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_index: ?usize = null;
    var retry_text_index: usize = 0;

    while (text_index < text.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            retry_text_index = text_index;
            pattern_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == text[text_index]) {
            pattern_index += 1;
            text_index += 1;
        } else if (star_index) |star| {
            pattern_index = star + 1;
            retry_text_index += 1;
            text_index = retry_text_index;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

/// Extract a human-friendly test name from the fully-qualified builtin name.
/// Named tests:   "myapp.parser.test.parseJson" -> "parseJson"
///                "myapp.parser.test.test_42"   -> "test_42"
/// Unnamed tests: "myapp.parser.test_0"         -> "myapp.parser.test_0" (keep full)
fn friendlyName(name: []const u8) []const u8 {
    // First, look for the ".test." separator used by named tests.
    // A named test "test_42" produces "module.test.test_42" which has ".test."
    // before the test name. An unnamed test produces "module.test_0" which
    // has ".test_" but NO ".test.". The segment is "test_0", not "test".
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |segment| {
        if (mem.eql(u8, segment, "test")) {
            const rest = it.rest();
            return if (rest.len > 0) rest else name;
        }
    }

    // No ".test." segment found, so this is an unnamed test (test_0, test_1, ...).
    // Keep the full qualified name since there's no meaningful short name.
    return name;
}
//
// testing.fuzz calls the root module's fuzz function.
// The main function rejects fuzz mode because it needs the server protocol.

// testing.fuzz requires this parameter order.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (@TypeOf(context), *testing.Smith) anyerror!void, // ziglint-ignore: Z023
    options: testing.FuzzInputOptions,
) anyerror!void {
    @disableInstrumentation();

    // Match the standard runner: preserve corpus bytes and add an empty smoke test.
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

test "friendlyName strips module path for named tests" {
    try testing.expectEqualStrings("parseJson", friendlyName("myapp.parser.test.parseJson"));
}

test "friendlyName keeps unnamed tests as full name" {
    try testing.expectEqualStrings("myapp.parser.test_0", friendlyName("myapp.parser.test_0"));
}

test "friendlyName handles deeply nested names" {
    try testing.expectEqualStrings("my_test", friendlyName("a.b.c.d.test.my_test"));
}

test "friendlyName handles test at root" {
    try testing.expectEqualStrings("simple", friendlyName("test.simple"));
}

test "friendlyName returns full name when no .test. segment" {
    try testing.expectEqualStrings("some.function", friendlyName("some.function"));
}

test "friendlyName handles edge case: test_foo in nested module" {
    // A test literally named "test_foo" in module "module" gets the
    // builtin name "module.test.test_foo". The .test. separator is present.
    try testing.expectEqualStrings("test_foo", friendlyName("module.test.test_foo"));
}

test "friendlyName strips named test that looks like test_N" {
    // A named test keeps the ".test." separator even if its name resembles an
    // unnamed test.
    try testing.expectEqualStrings("test_42", friendlyName("module.test.test_42"));
}

test "flags parse equals and separated forms" {
    const parsed = try parse(&[_][]const u8{
        "test",                 "--format=testname", "--fail-fast",   "--filter=basic arithmetic",
        "--allow-empty-filter", "--seed=0x1234",     "--count=2",     "--rerun-fails=3",
        "--shuffle=off",        "--slowest=4",       "--timeout=30s",
    });
    try testing.expectEqual(Format.testname, parsed.flags.format.?);
    try testing.expect(parsed.flags.fail_fast);
    try testing.expect(parsed.flags.allow_empty_filter);
    try testing.expectEqualStrings("basic arithmetic", parsed.flags.filter.?);
    try testing.expectEqual(@as(?u32, 0x1234), parsed.seed);
    try testing.expectEqual(@as(usize, 2), parsed.flags.count);
    try testing.expectEqual(@as(usize, 3), parsed.flags.rerun_fails);
    try testing.expectEqual(@as(usize, 4), parsed.flags.slowest);
    try testing.expectEqual(@as(?u64, 30 * time.ns_per_s), parsed.flags.timeout_ns);

    const separated = try parse(&[_][]const u8{
        "test",      "--format", "quiet",     "--filter", "fuzz",      "--count", "3",
        "--shuffle", "on",       "--slowest", "2",        "--timeout", "500ms",
    });
    try testing.expectEqual(Format.quiet, separated.flags.format.?);
    try testing.expectEqualStrings("fuzz", separated.flags.filter.?);
    try testing.expectEqual(@as(usize, 3), separated.flags.count);
    try testing.expectEqual(Shuffle.on, separated.flags.shuffle);
    try testing.expectEqual(@as(usize, 2), separated.flags.slowest);
    try testing.expectEqual(@as(?u64, 500 * time.ns_per_ms), separated.flags.timeout_ns);
}

test "flags parse every format value" {
    try testing.expectEqual(
        Format.quiet,
        (try parse(&[_][]const u8{ "test", "--format=quiet" })).flags.format.?,
    );
    try testing.expectEqual(
        Format.dots,
        (try parse(&[_][]const u8{ "test", "--format=dots" })).flags.format.?,
    );
    try testing.expectEqual(
        Format.testname,
        (try parse(&[_][]const u8{ "test", "--format=testname" })).flags.format.?,
    );
    try testing.expectEqual(
        Format.verbose,
        (try parse(&[_][]const u8{ "test", "--format=verbose" })).flags.format.?,
    );
    try testing.expectError(error.InvalidFormat, parse(&[_][]const u8{ "test", "--format=wat" }));
    try testing.expectError(error.MissingFlagValue, parse(&[_][]const u8{ "test", "--format" }));
}

test "flags parse timeout durations and off" {
    const defaults = try parse(&[_][]const u8{"test"});
    try testing.expectEqual(@as(?u64, 10 * time.ns_per_min), defaults.flags.timeout_ns);
    try testing.expectEqualStrings("10m", defaults.flags.timeout_text);

    try testing.expectEqual(@as(?u64, 500 * time.ns_per_ms), (try parse(&[_][]const u8{
        "test", "--timeout=500ms",
    })).flags.timeout_ns);
    try testing.expectEqual(@as(?u64, 90 * time.ns_per_s), (try parse(&[_][]const u8{
        "test", "--timeout=1m30s",
    })).flags.timeout_ns);
    try testing.expectEqual(@as(?u64, null), (try parse(&[_][]const u8{
        "test", "--timeout=off",
    })).flags.timeout_ns);
    try testing.expectEqual(@as(?u64, null), (try parse(&[_][]const u8{
        "test", "--timeout=0",
    })).flags.timeout_ns);
    try testing.expectError(
        error.InvalidTimeout,
        parse(&[_][]const u8{ "test", "--timeout=soon" }),
    );
}

test "flags validate count rerun-fails shuffle and slowest" {
    try testing.expectEqual(
        @as(usize, 3),
        (try parse(&[_][]const u8{ "test", "--count=3" })).flags.count,
    );
    try testing.expectError(error.InvalidCount, parse(&[_][]const u8{ "test", "--count=0" }));
    try testing.expectError(error.InvalidCount, parse(&[_][]const u8{ "test", "--count=x" }));

    try testing.expectEqual(@as(usize, 2), (try parse(&[_][]const u8{
        "test", "--rerun-fails=2",
    })).flags.rerun_fails);
    try testing.expectError(error.InvalidRerunFails, parse(&[_][]const u8{
        "test", "--rerun-fails=1",
    }));
    try testing.expectError(error.InvalidRerunFails, parse(&[_][]const u8{
        "test", "--rerun-fails=0",
    }));

    try testing.expectEqual(
        Shuffle.off,
        (try parse(&[_][]const u8{ "test", "--shuffle=off" })).flags.shuffle,
    );
    try testing.expectEqual(
        Shuffle.on,
        (try parse(&[_][]const u8{ "test", "--shuffle=on" })).flags.shuffle,
    );
    try testing.expectEqual(Shuffle{ .seed = 7 }, (try parse(&[_][]const u8{
        "test", "--shuffle=7",
    })).flags.shuffle);
    try testing.expectError(error.InvalidShuffle, parse(&[_][]const u8{
        "test", "--shuffle=sometimes",
    }));

    try testing.expectEqual(@as(usize, 5), (try parse(&[_][]const u8{
        "test", "--slowest=5",
    })).flags.slowest);
    try testing.expectEqual(@as(usize, 0), (try parse(&[_][]const u8{
        "test", "--slowest=0",
    })).flags.slowest);
}

test "flags reject unknown options, removed options, and missing values" {
    try testing.expectError(error.UnknownRunnerOption, parse(&[_][]const u8{ "test", "--wat" }));
    try testing.expectError(
        error.UnknownRunnerOption,
        parse(&[_][]const u8{ "test", "--verbose" }),
    );
    try testing.expectError(
        error.UnknownRunnerOption,
        parse(&[_][]const u8{ "test", "--no-verbose" }),
    );
    try testing.expectError(error.MissingFlagValue, parse(&[_][]const u8{ "test", "--filter" }));
    try testing.expectError(error.InvalidSeed, parse(&[_][]const u8{ "test", "--seed=zz" }));
}

test "duration parser accepts go-style durations" {
    try testing.expectEqual(@as(u64, 500 * time.ns_per_ms), try parseDurationNs("500ms"));
    try testing.expectEqual(@as(u64, 1500 * time.ns_per_ms), try parseDurationNs("1.5s"));
    try testing.expectEqual(@as(u64, 90 * time.ns_per_s), try parseDurationNs("1m30s"));
    try testing.expectEqual(@as(u64, 0), try parseDurationNs("0"));
    try testing.expectError(error.InvalidDuration, parseDurationNs(""));
    try testing.expectError(error.InvalidDuration, parseDurationNs("10"));
    try testing.expectError(error.InvalidDuration, parseDurationNs("-1s"));
    try testing.expectError(error.InvalidDuration, parseDurationNs("1w"));
}

test "shuffle is deterministic for a fixed seed" {
    var a: [16]usize = undefined;
    var b: [16]usize = undefined;
    var c: [16]usize = undefined;
    for (&a, 0..) |*value, idx| value.* = idx;
    for (&b, 0..) |*value, idx| value.* = idx;
    for (&c, 0..) |*value, idx| value.* = idx;

    shuffleIndices(a[0..], 42);
    shuffleIndices(b[0..], 42);
    shuffleIndices(c[0..], 43);

    try testing.expectEqualSlices(usize, a[0..], b[0..]);
    try testing.expect(!mem.eql(usize, a[0..], c[0..]));
}

test "filter matches substrings anchors and globs" {
    const named = "tests.fixtures.test.basic arithmetic passes";
    try testing.expect(matches("arithmetic", named));
    try testing.expect(matches("^tests.fixtures.test.basic arithmetic passes$", named));
    try testing.expect(!matches("^basic arithmetic$", named));
    try testing.expect(matches("basic*passes", named));
    try testing.expect(!matches("basic*fails", named));
}

test "filter matches comma-separated alternatives" {
    const error_log_test = "tests.fixtures.test.emits error log but succeeds";
    try testing.expect(matchesAny("leak, error log", error_log_test));
    try testing.expect(matchesAny("leak, error log", "tests.fixtures.test.memory leak detection"));
    try testing.expect(!matchesAny("leak, fuzz", error_log_test));
}

test "environment options come before the command line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = [_][]const u8{ "test", "--format=quiet", "--filter=argv" };
    const args = try collectArgs(arena, &argv, .{
        .format = "testname",
        .filter = "env pattern",
        .timeout = "30s",
        .fail_fast = "true",
        .allow_empty_filter = "1",
        .no_color = true,
    });

    try testing.expectEqualStrings("test", args[0]);
    try testing.expectEqualStrings("--format=testname", args[1]);
    try testing.expectEqualStrings("--filter=env pattern", args[2]);
    try testing.expectEqualStrings("--timeout=30s", args[3]);
    try testing.expectEqualStrings("--fail-fast", args[4]);
    try testing.expectEqualStrings("--allow-empty-filter", args[5]);
    try testing.expectEqualStrings("--plain", args[6]);
    // The command line is last, so parse() lets it override the variable.
    try testing.expectEqualStrings("--format=quiet", args[7]);
    try testing.expectEqualStrings("--filter=argv", args[8]);

    const parsed = try parse(args);
    try testing.expectEqual(Format.quiet, parsed.flags.format.?);
    try testing.expectEqualStrings("argv", parsed.flags.filter.?);
    try testing.expect(parsed.flags.fail_fast);
    try testing.expect(parsed.flags.allow_empty_filter);
    try testing.expect(parsed.flags.plain);
}

test "environment booleans accept only true and false spellings" {
    try testing.expectEqual(@as(?bool, true), envBool("1"));
    try testing.expectEqual(@as(?bool, true), envBool("TRUE"));
    try testing.expectEqual(@as(?bool, false), envBool("0"));
    try testing.expectEqual(@as(?bool, false), envBool("False"));
    try testing.expectEqual(@as(?bool, null), envBool(""));
    try testing.expectEqual(@as(?bool, null), envBool("yes"));
    try testing.expectEqual(@as(?bool, null), envBool(null));
}
