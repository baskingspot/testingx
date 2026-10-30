//! Benchmarks that sit beside your tests: Go's testing.B, in Zig.
//!
//! A benchmark suite is a program that registers what runs. The entrypoint
//! is `pub fn benchmarkMain(b: *B) !void` in the suite root:
//!
//!     const sort_bench = @import("bench/sort.zig");
//!
//!     pub fn benchmarkMain(b: *testingx.B) !void {
//!         try b.addMod(sort_bench); // bulk: every pub benchmark* at top level
//!         try b.add("Parser/Baseline", benchmarkParserBaseline); // one-off
//!     }
//!
//! `add` and `addMod` register. `finish` executes everything registered.
//! Inside a running benchmark, `b.run` executes a sub-benchmark immediately
//! (Go's `b.Run`); registering there is an error.
//!
//! `addMod` walks top-level declarations only, never nested structs. The
//! convention inside a module: `pub fn benchmark*(b: *B) !void`.
//!
//! Flags (parsed by the generated main, Go's set):
//!   --benchtime D   run for duration D (default 1s), or Nx for exactly N
//!   --count N       run each benchmark N times (default 1)
//!   --filter P      comma-separated patterns: contains, ^ anchors start,
//!                   $ anchors end, * matches any bytes
//!   --benchmem      print B/op and allocs/op
//!   --parallelism N default B.runParallel multiplier
//!   --config K=V    add a config line to the output header (repeatable)
//!   --jsonl         emit one JSON object per record instead of benchfmt text
//!
//! Text output is the Go benchmark format (`benchfmt.zig`); FAIL and SKIP
//! rows are comments so the result stream stays parseable. `--jsonl` is an
//! opt-in machine-readable mode.
//!
//! Environment, for CI policy: TESTINGX_BENCH_FILTER (same as `--filter`),
//! TESTINGX_BENCH_JSONL (1 or true, same as `--jsonl`), and
//! TESTINGX_BENCH_CYCLES (same as `--cycles`, so a shell can make counters
//! the local default). Flags win.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const time = std.time;
const Io = std.Io;
const atomic = std.atomic;
const Thread = std.Thread;
const testing = std.testing;
const doNotOptimizeAway = mem.doNotOptimizeAway;
const Alignment = mem.Alignment;
const builtin = @import("builtin");

const benchfmt = @import("benchfmt.zig");
const filter = @import("filter.zig");
const perfcounter = @import("perfcounter.zig");
const symbols = @import("symbols.zig");
const Timer = @import("timer.zig").Timer;

pub const Error = error{
    BenchmarkFailed,
    BenchmarkSkipped,
    InvalidMetricUnit,
    // `b.run` before `finish` executes anything, or `add`/`addMod` while a
    // benchmark is running. Registration happens in `benchmarkMain`; `b.run`
    // belongs inside a benchmark function.
    InvalidPhase,
};

/// The flags, as parsed by `benchMain` or built by a test.
pub const Options = struct {
    benchtime: DurationOrCount,
    benchmem: bool,
    count: usize,
    parallelism: usize,
    filter: ?[]const u8,
    emit_environment: bool,
    jsonl: bool,
    /// `--disasm`: print the linker symbol and disassembly of matching
    /// benchmarks instead of running anything.
    disasm: ?[]const u8,
    /// `--cycles`: read hardware counters around each timed section.
    cycles: bool,
    help: bool,
    writer: ?*Io.Writer,
    /// Extra config lines from `--config`, emitted before the environment.
    /// The list and its values are owned by this Options.
    config: std.ArrayList(benchfmt.Config),

    /// One second per benchmark, one iteration, no filter, the environment
    /// header on, and no config entries.
    pub const init: Options = .{
        .benchtime = .{ .duration_ns = time.ns_per_s },
        .benchmem = false,
        .count = 1,
        .parallelism = 1,
        .filter = null,
        .emit_environment = true,
        .jsonl = false,
        .disasm = null,
        .cycles = false,
        .help = false,
        .writer = null,
        .config = .empty,
    };

    pub fn deinit(self: *Options, allocator: Allocator) void {
        for (self.config.items) |entry| allocator.free(entry.value);
        self.config.deinit(allocator);
        self.* = undefined;
    }

    /// Accepts a standard-library argument iterator. Skips argv[0].
    /// Returned filter strings borrow the iterator's storage; `--config`
    /// values are duplicated with `allocator`, which also owns the list.
    /// `defaults` must not already carry config entries.
    pub fn parse(allocator: Allocator, args: anytype, defaults: Options) !Options {
        std.debug.assert(defaults.config.items.len == 0);
        _ = args.skip();

        var options = defaults;
        errdefer options.deinit(allocator);
        while (args.next()) |arg| {
            if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
                options.help = true;
            } else if (mem.eql(u8, arg, "--benchmem") or mem.eql(u8, arg, "-m")) {
                options.benchmem = true;
            } else if (mem.eql(u8, arg, "--no-env")) {
                options.emit_environment = false;
            } else if (mem.eql(u8, arg, "--jsonl")) {
                options.jsonl = true;
            } else if (mem.eql(u8, arg, "--cycles")) {
                options.cycles = true;
            } else if (mem.eql(u8, arg, "--disasm")) {
                options.disasm = try nextFlagValue(args);
            } else if (mem.startsWith(u8, arg, "--disasm=")) {
                options.disasm = arg["--disasm=".len..];
            } else if (mem.eql(u8, arg, "--count")) {
                options.count = try std.fmt.parseInt(usize, try nextFlagValue(args), 10);
            } else if (mem.startsWith(u8, arg, "--count=")) {
                options.count = try std.fmt.parseInt(usize, arg["--count=".len..], 10);
            } else if (try shortFlagValue(arg, "-c", args)) |value| {
                options.count = try std.fmt.parseInt(usize, value, 10);
            } else if (mem.eql(u8, arg, "--benchtime")) {
                options.benchtime = try .parse(try nextFlagValue(args));
            } else if (mem.startsWith(u8, arg, "--benchtime=")) {
                options.benchtime = try .parse(arg["--benchtime=".len..]);
            } else if (try shortFlagValue(arg, "-t", args)) |value| {
                options.benchtime = try .parse(value);
            } else if (mem.eql(u8, arg, "--filter")) {
                options.filter = try nextFlagValue(args);
            } else if (mem.startsWith(u8, arg, "--filter=")) {
                options.filter = arg["--filter=".len..];
            } else if (try shortFlagValue(arg, "-f", args)) |value| {
                options.filter = value;
            } else if (mem.eql(u8, arg, "--parallelism")) {
                options.parallelism = try std.fmt.parseInt(usize, try nextFlagValue(args), 10);
            } else if (mem.startsWith(u8, arg, "--parallelism=")) {
                options.parallelism = try std.fmt.parseInt(usize, arg["--parallelism=".len..], 10);
            } else if (try shortFlagValue(arg, "-p", args)) |value| {
                options.parallelism = try std.fmt.parseInt(usize, value, 10);
            } else if (mem.eql(u8, arg, "--config")) {
                try options.appendConfig(allocator, try nextFlagValue(args));
            } else if (mem.startsWith(u8, arg, "--config=")) {
                try options.appendConfig(allocator, arg["--config=".len..]);
            } else if (mem.eql(u8, arg, "--")) {
                // The bench binary takes no positional arguments, so the
                // separator is a no-op; `zig build bench -- -- ...` forwards it.
            } else return error.UnknownBenchmarkOption;
        }

        if (options.help) return options;
        if (options.count == 0) return error.InvalidCount;
        if (options.parallelism == 0) options.parallelism = 1;

        return options;
    }

    fn appendConfig(self: *Options, allocator: Allocator, spec: []const u8) !void {
        const equals = mem.findScalar(u8, spec, '=') orelse return error.InvalidConfig;
        const key = spec[0..equals];
        const value = spec[equals + 1 ..];
        if (!benchfmt.isValidConfigKey(key)) return error.InvalidConfig;
        if (value.len == 0 or mem.findScalar(u8, value, '\n') != null) {
            return error.InvalidConfig;
        }

        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        try self.config.append(allocator, .{ .key = key, .value = owned_value });
    }
};

fn nextFlagValue(args: anytype) ![]const u8 {
    return args.next() orelse error.MissingBenchmarkOptionValue;
}

fn shortFlagValue(arg: []const u8, flag: []const u8, args: anytype) !?[]const u8 {
    if (!mem.startsWith(u8, arg, flag)) return null;
    const value = arg[flag.len..];
    if (value.len == 0) return @as(?[]const u8, try nextFlagValue(args));
    if (mem.startsWith(u8, value, "=")) return value[1..];
    return value;
}

/// Arguments as a slice: the process main already has one in hand.
pub const SliceArgs = struct {
    args: []const []const u8,
    i: usize,

    /// An iterator positioned after argv[0].
    pub fn init(args: []const []const u8) SliceArgs {
        return .{ .args = args, .i = 1 };
    }

    pub fn skip(self: *SliceArgs) void {
        self.i = 1;
    }

    pub fn next(self: *SliceArgs) ?[]const u8 {
        if (self.i >= self.args.len) return null;
        const arg = self.args[self.i];
        self.i += 1;
        return arg;
    }
};

const EnvOptions = struct {
    filter: ?[]const u8 = null,
    jsonl: ?[]const u8 = null,
    cycles: ?[]const u8 = null,
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
    if (env.filter) |value| {
        try args.append(arena, try std.fmt.allocPrint(arena, "--filter={s}", .{value}));
    }
    if (envBool(env.jsonl)) |on| {
        if (on) try args.append(arena, "--jsonl");
    }
    if (envBool(env.cycles)) |on| {
        if (on) try args.append(arena, "--cycles");
    }
    try args.appendSlice(arena, argv[1..]);
    return args.items;
}

/// `1`/`true` and `0`/`false`, case-insensitive. Anything else is unset.
fn envBool(value: ?[]const u8) ?bool {
    const text = value orelse return null;
    if (std.ascii.eqlIgnoreCase(text, "1") or std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "0") or std.ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

/// A missing variable is null. Any other failure to read it is fatal.
fn envGet(arena: Allocator, environ: std.process.Environ, key: []const u8) ?[]const u8 {
    return std.process.Environ.getAlloc(environ, arena, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => @panic("testingx: cannot read the environment"),
    };
}

pub const DurationOrCount = union(enum) {
    duration_ns: u64,
    count: u64,

    pub fn parse(s: []const u8) !DurationOrCount {
        if (mem.endsWith(u8, s, "x")) {
            const n = try std.fmt.parseInt(u64, s[0 .. s.len - 1], 10);
            if (n == 0) return error.InvalidCount;
            return .{ .count = n };
        }

        return .{ .duration_ns = try parseDurationNs(s) };
    }
};

pub const Function = *const fn (*B) anyerror!void;

pub const Spec = struct {
    name: []const u8,
    func: Function,
};

pub const Result = struct {
    n: u64,
    t_ns: u64,
    bytes: i64,
    mem_allocs: u64,
    mem_bytes: u64,
    extra: MetricMap,

    /// Nothing measured: no iterations, time, bytes, allocations, or metrics.
    pub const zero: Result = .{
        .n = 0,
        .t_ns = 0,
        .bytes = 0,
        .mem_allocs = 0,
        .mem_bytes = 0,
        .extra = .empty,
    };

    pub fn deinit(self: *Result, allocator: Allocator) void {
        freeMetricKeys(allocator, &self.extra);
        self.extra.deinit(allocator);
        self.* = undefined;
    }

    pub fn nsPerOp(self: *const Result) i64 {
        if (self.extra.get("ns/op")) |v| return @intFromFloat(v);
        if (self.n == 0) return 0;
        return @intCast(self.t_ns / self.n);
    }

    pub fn mbPerSec(self: *const Result) f64 {
        if (self.extra.get("MB/s")) |v| return v;
        if (self.bytes <= 0 or self.t_ns == 0 or self.n == 0) return 0;
        const bytes: f64 = @floatFromInt(self.bytes);
        const n: f64 = @floatFromInt(self.n);
        const seconds = @as(f64, @floatFromInt(self.t_ns)) / time.ns_per_s;
        return (bytes * n / 1e6) / seconds;
    }

    pub fn allocsPerOp(self: *const Result) i64 {
        if (self.extra.get("allocs/op")) |v| return @intFromFloat(v);
        if (self.n == 0) return 0;
        return @intCast(self.mem_allocs / self.n);
    }

    pub fn allocedBytesPerOp(self: *const Result) i64 {
        if (self.extra.get("B/op")) |v| return @intFromFloat(v);
        if (self.n == 0) return 0;
        return @intCast(self.mem_bytes / self.n);
    }

    /// Append this result's measurements in print order. `ns/op` is always
    /// present, so the encoded result line always has a value/unit pair.
    pub fn appendValues(
        self: *const Result,
        allocator: Allocator,
        values: *std.ArrayList(benchfmt.Value),
        include_mem: bool,
    ) !void {
        try values.append(allocator, .{
            .value = @floatFromInt(self.nsPerOp()),
            .unit = "ns/op",
        });

        const mbs = self.mbPerSec();
        if (mbs != 0) try values.append(allocator, .{ .value = mbs, .unit = "MB/s" });

        var it = self.extra.iterator();
        while (it.next()) |entry| {
            const unit = entry.key_ptr.*;
            if (mem.eql(u8, unit, "ns/op") or
                mem.eql(u8, unit, "MB/s") or
                mem.eql(u8, unit, "B/op") or
                mem.eql(u8, unit, "allocs/op")) continue;

            try values.append(allocator, .{ .value = entry.value_ptr.*, .unit = unit });
        }

        if (include_mem) {
            try values.append(allocator, .{
                .value = @floatFromInt(self.allocedBytesPerOp()),
                .unit = "B/op",
            });
            try values.append(allocator, .{
                .value = @floatFromInt(self.allocsPerOp()),
                .unit = "allocs/op",
            });
        }
    }
};

const MetricMap = std.array_hash_map.String(f64);

pub const CountingAllocator = struct {
    child: Allocator,
    total_allocs: atomic.Value(u64),
    total_bytes: atomic.Value(u64),

    pub fn init(child: Allocator) CountingAllocator {
        return .{
            .child = child,
            .total_allocs = .init(0),
            .total_bytes = .init(0),
        };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn reset(self: *CountingAllocator) void {
        self.total_allocs.store(0, .seq_cst);
        self.total_bytes.store(0, .seq_cst);
    }

    pub fn allocs(self: *CountingAllocator) u64 {
        return self.total_allocs.load(.seq_cst);
    }

    pub fn bytes(self: *CountingAllocator) u64 {
        return self.total_bytes.load(.seq_cst);
    }

    fn record(self: *CountingAllocator, len: usize) void {
        _ = self.total_allocs.fetchAdd(1, .seq_cst);
        _ = self.total_bytes.fetchAdd(@intCast(len), .seq_cst);
    }

    fn recordGrowth(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) _ = self.total_bytes.fetchAdd(@intCast(new_len - old_len), .seq_cst);
    }

    fn rawAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.record(len);
        return ptr;
    }

    fn rawResize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.recordGrowth(memory.len, new_len);
        return true;
    }

    fn rawRemap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.recordGrowth(memory.len, new_len);
        return ptr;
    }

    fn rawFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

/// A `B` is the suite during registration (`benchmarkMain`) and one running
/// benchmark during execution. The phase decides what `add`/`addMod`/`run` do.
pub const B = struct {
    internal_allocator: Allocator,
    /// The I/O of this B. In the suite phase it is the process I/O; in a
    /// spawned benchmark it is `io_instance.io()` (mirrors `testing.io`:
    /// a fresh `Io.Threaded` per benchmark, on the same counting allocator
    /// as `allocator`, so its allocations are counted).
    io: Io,
    io_instance: Io.Threaded,
    argv0: Io.Threaded.Argv0,
    environ: std.process.Environ,
    options: Options,
    specs: std.ArrayList(Spec),
    writer: ?*Io.Writer,
    stdout_buf: [4096]u8,
    stdout: Io.File.Writer,
    executing: bool,
    allocator: Allocator,
    counting_allocator: CountingAllocator,
    name: []const u8,
    n: u64,
    failed: bool,
    skipped: bool,

    bench_func: ?Function,
    bench_time: DurationOrCount,
    bytes: i64,
    timer: Timer,
    timer_on: bool,
    duration_ns: u64,
    start_allocs: u64,
    start_bytes: u64,
    net_allocs: u64,
    net_bytes: u64,
    show_alloc_result: bool,
    benchmem: bool,
    jsonl: bool,
    filter_pattern: ?[]const u8,
    counters: perfcounter.Counters,
    counters_error: ?anyerror,
    counters_warned: bool,
    result: Result,
    parallelism: usize,
    previous_n: u64,
    previous_duration_ns: u64,
    loop_state: LoopState,
    has_sub: bool,
    missing_bytes: bool,
    extra: MetricMap,

    const LoopState = struct {
        n: u64 = 0,
        i: u64 = 0,
        done: bool = false,
    };

    /// Every field at its zero value. `init`, `initProcess`, and `spawn` then
    /// fill in the fields that carry state, so a B never comes from a bare
    /// literal.
    fn blank() B {
        return .{
            .internal_allocator = undefined,
            .io = undefined,
            .io_instance = undefined,
            .argv0 = .empty,
            .environ = .empty,
            .options = .init,
            .specs = .empty,
            .writer = null,
            .stdout_buf = undefined,
            .stdout = undefined,
            .executing = false,
            .allocator = undefined,
            .counting_allocator = undefined,
            .name = "",
            .n = 0,
            .failed = false,
            .skipped = false,
            .bench_func = null,
            .bench_time = .{ .duration_ns = time.ns_per_s },
            .bytes = 0,
            .timer = undefined,
            .timer_on = false,
            .duration_ns = 0,
            .start_allocs = 0,
            .start_bytes = 0,
            .net_allocs = 0,
            .net_bytes = 0,
            .show_alloc_result = false,
            .benchmem = false,
            .jsonl = false,
            .filter_pattern = null,
            .counters = .empty,
            .counters_error = null,
            .counters_warned = false,
            .result = .zero,
            .parallelism = 1,
            .previous_n = 0,
            .previous_duration_ns = 0,
            .loop_state = .{},
            .has_sub = false,
            .missing_bytes = false,
            .extra = .empty,
        };
    }

    /// Create a suite for registration. `io` is required: everything here
    /// does I/O and refuses to guess.
    pub fn init(allocator: Allocator, io: Io, options: Options) B {
        var b = blank();
        b.internal_allocator = allocator;
        b.io = io;
        b.options = options;
        b.bench_time = options.benchtime;
        b.benchmem = options.benchmem;
        b.jsonl = options.jsonl;
        b.parallelism = options.parallelism;
        b.filter_pattern = options.filter;
        b.writer = options.writer;
        return b;
    }

    /// Create a suite from a process entry: parses flags from argv.
    pub fn initProcess(entry: std.process.Init) !B {
        const arena = entry.arena.allocator();
        const argv = try entry.minimal.args.toSlice(arena);
        const environ = entry.minimal.environ;
        const combined = try collectArgs(arena, argv, .{
            .filter = envGet(arena, environ, "TESTINGX_BENCH_FILTER"),
            .jsonl = envGet(arena, environ, "TESTINGX_BENCH_JSONL"),
            .cycles = envGet(arena, environ, "TESTINGX_BENCH_CYCLES"),
        });
        var args = SliceArgs.init(combined);
        const options = try Options.parse(arena, &args, .init);
        var b = blank();
        b.internal_allocator = arena;
        b.io = entry.io;
        b.argv0 = .init(entry.minimal.args);
        b.environ = entry.minimal.environ;
        b.options = options;
        b.bench_time = options.benchtime;
        b.benchmem = options.benchmem;
        b.jsonl = options.jsonl;
        b.parallelism = options.parallelism;
        b.filter_pattern = options.filter;
        b.writer = options.writer;
        return b;
    }

    pub fn deinit(self: *B) void {
        self.counters.close();
        freeMetricKeys(self.internal_allocator, &self.extra);
        self.extra.deinit(self.internal_allocator);
        self.result.deinit(self.internal_allocator);
        self.specs.deinit(self.internal_allocator);
        self.options.deinit(self.internal_allocator);
        if (self.bench_func != null) self.io_instance.deinit();
        self.* = undefined;
    }

    fn resolveWriter(self: *B) *Io.Writer {
        if (self.options.writer) |w| return w;
        if (self.writer == null) {
            self.stdout = Io.File.stdout().writerStreaming(self.io, &self.stdout_buf);
            self.writer = &self.stdout.interface;
        }
        return self.writer.?;
    }

    /// Register one benchmark by name.
    pub fn add(self: *B, name: []const u8, func: Function) !void {
        if (self.executing) return Error.InvalidPhase;
        try self.specs.append(self.internal_allocator, .{ .name = name, .func = func });
    }

    /// Register every top-level `pub fn benchmark*(b: *B) !void` in `mod`.
    /// One line per module, zero per function. Names drop the prefix:
    /// `benchmarkSort` registers as "Sort".
    pub fn addMod(self: *B, comptime mod: type) !void {
        if (self.executing) return Error.InvalidPhase;
        @setEvalBranchQuota(100_000);
        inline for (@typeInfo(mod).@"struct".decls) |decl| {
            if (comptime isBenchmarkDecl(mod, decl)) {
                try self.specs.append(self.internal_allocator, .{
                    .name = comptime B.benchmarkName(decl.name),
                    .func = @field(mod, decl.name),
                });
            }
        }
    }

    fn isBenchmarkDecl(comptime mod: type, comptime decl: std.builtin.Type.Declaration) bool {
        // `decls` already lists only public declarations from another module.
        if (!isBenchmarkName(decl.name)) return false;
        return isBenchmarkFunction(@field(mod, decl.name));
    }

    fn isBenchmarkName(comptime name: []const u8) bool {
        return mem.startsWith(u8, name, "Benchmark") or mem.startsWith(u8, name, "benchmark");
    }

    fn isBenchmarkFunction(comptime value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        const fn_info = switch (info) {
            .@"fn" => |fn_info| fn_info,
            .pointer => |pointer| switch (@typeInfo(pointer.child)) {
                .@"fn" => |fn_info| fn_info,
                else => return false,
            },
            else => return false,
        };

        if (fn_info.params.len != 1 or fn_info.params[0].type != *B) return false;
        const return_type = fn_info.return_type orelse return false;
        return @typeInfo(return_type) == .error_union and
            @typeInfo(return_type).error_union.payload == void;
    }

    fn benchmarkName(comptime name: []const u8) []const u8 {
        if (mem.startsWith(u8, name, "Benchmark")) return name["Benchmark".len..];
        if (mem.startsWith(u8, name, "benchmark")) return name["benchmark".len..];
        return name;
    }

    /// Execute everything registered. Returns true when all passed.
    pub fn finish(self: *B) !bool {
        const writer = self.resolveWriter();
        self.executing = true;
        defer writer.flush() catch {};

        if (self.options.help) {
            try printUsage(writer);
            return true;
        }

        if (self.options.disasm) |pattern| {
            return self.printDisasm(writer, pattern);
        }

        const environment = try Environment.detect();
        if (self.jsonl) {
            try emitJsonHeader(writer, &self.options, &environment);
        } else {
            try emitHeader(writer, &self.options, &environment);
        }

        var ok = true;
        for (self.specs.items) |entry| {
            if (self.filter_pattern) |pattern| {
                if (!filterMatches(pattern, entry.name) and
                    !filterMayMatchChild(pattern, entry.name)) continue;
            }

            var i: usize = 0;
            while (i < self.options.count) : (i += 1) {
                var bench_b: B = undefined;
                try self.spawn(&bench_b, entry.name, entry.func);
                defer bench_b.deinit();

                try bench_b.run1AndMaybeLaunch();

                if (bench_b.counters_error) |err| {
                    if (!self.counters_warned) {
                        self.counters_warned = true;
                        if (!self.jsonl) try writer.print(
                            "# testingx: hardware counters unavailable: {t}\n",
                            .{err},
                        );
                    }
                }

                if (bench_b.has_sub) {
                    if (bench_b.failed) ok = false;
                    continue;
                }

                try printBenchmarkResult(writer, entry.name, &bench_b, self.benchmem);
                if (bench_b.failed) ok = false;
            }
        }
        return ok;
    }

    /// `--disasm`: resolve each matching benchmark to the linker symbol and
    /// hand its address range to objdump. The binary path comes from this
    /// process's own debug info, so it always disassembles the build that ran.
    fn printDisasm(self: *B, writer: *Io.Writer, pattern: []const u8) !bool {
        var matched = false;
        for (self.specs.items) |entry| {
            if (!filterMatches(pattern, entry.name)) continue;
            matched = true;

            const target = self.resolveSymbol(entry.func) catch |err| {
                try writer.print("Benchmark{s}: no symbol ({t})\n", .{ entry.name, err });
                try writer.flush();
                continue;
            };

            try writer.print("Benchmark{s}\n", .{entry.name});
            try writer.print("  {s}  {x}..{x}  {d} bytes\n", .{
                target.symbol.name,
                target.symbol.address,
                target.symbol.end(),
                target.symbol.size,
            });
            try writer.flush();

            try self.runObjdump(writer, target);
        }

        if (!matched) {
            try writer.print("testingx: no benchmark matches \"{s}\"\n", .{pattern});
            try writer.flush();
        }
        return matched;
    }

    const DisasmTarget = struct {
        symbol: symbols.Symbol,
        path: []const u8,
    };

    fn resolveSymbol(self: *B, func: Function) !DisasmTarget {
        // Windows debug info in Zig 0.16.0 does not compile, and objdump is not
        // there either, so the whole body stays unanalyzed off POSIX-ELF.
        if (comptime builtin.os.tag == .windows) {
            return error.UnsupportedPlatform;
        } else {
            const info = try std.debug.getSelfDebugInfo();
            const address = @intFromPtr(func);
            const slide = info.getModuleSlide(self.io, address) catch 0;
            const path = try info.getModuleName(self.io, address);
            const symbol = try symbols.lookup(
                self.internal_allocator,
                self.io,
                path,
                address - slide,
            );
            return .{ .symbol = symbol, .path = path };
        }
    }

    fn runObjdump(self: *B, writer: *Io.Writer, target: DisasmTarget) !void {
        const start = try std.fmt.allocPrint(
            self.internal_allocator,
            "--start-address=0x{x}",
            .{target.symbol.address},
        );
        const stop = try std.fmt.allocPrint(
            self.internal_allocator,
            "--stop-address=0x{x}",
            .{target.symbol.end()},
        );
        const argv = [_][]const u8{
            "objdump", "-dS", "--no-show-raw-insn", start, stop, target.path,
        };

        var child = std.process.spawn(self.io, .{
            .argv = &argv,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch |err| {
            try writer.print("  objdump unavailable ({t}); run:\n  ", .{err});
            try writeCommand(writer, &argv);
            return;
        };

        // Drain the pipe before waiting: objdump on a big function can fill it.
        const stdout = child.stdout.?;
        var buffer: [4096]u8 = undefined;
        var reader = stdout.reader(self.io, &buffer);
        const text = reader.interface.allocRemaining(self.internal_allocator, .unlimited) catch
            try self.internal_allocator.dupe(u8, "");
        const term = child.wait(self.io) catch |err| {
            try writer.print("  objdump failed: {t}\n", .{err});
            return;
        };
        defer stdout.close(self.io);
        _ = term;

        try writeNormalized(writer, text);
    }

    /// Spawn one running benchmark into `dest`, in place. `io` and
    /// `allocator` point into `dest`'s own `io_instance` and
    /// `counting_allocator`, so a spawned B must never be copied, the same
    /// contract `testing.io` has.
    fn spawn(self: *const B, dest: *B, name: []const u8, func: Function) !void {
        dest.* = blank();
        dest.internal_allocator = self.internal_allocator;
        dest.io = self.io;
        dest.argv0 = self.argv0;
        dest.environ = self.environ;
        dest.writer = self.writer;
        dest.executing = true;
        dest.name = name;
        dest.bench_func = func;
        dest.bench_time = self.bench_time;
        dest.benchmem = self.benchmem;
        dest.jsonl = self.jsonl;
        dest.filter_pattern = self.filter_pattern;
        dest.parallelism = self.parallelism;

        dest.counting_allocator = .init(self.internal_allocator);
        dest.allocator = dest.counting_allocator.allocator();
        dest.io_instance = .init(dest.allocator, .{
            .argv0 = self.argv0,
            .environ = self.environ,
        });
        dest.io = dest.io_instance.io();
        dest.timer = .start(dest.io);
        if (self.options.cycles) {
            dest.counters.open() catch |err| {
                dest.counters_error = err;
            };
        }
    }

    /// Execute a sub-benchmark (Go's `b.Run`). Only valid inside a running
    /// benchmark: `benchmarkMain` registers with `add`/`addMod` instead.
    pub fn run(self: *B, name: []const u8, func: Function) !bool {
        if (!self.executing) return Error.InvalidPhase;
        self.has_sub = true;

        const full_name = if (self.name.len == 0)
            name
        else
            try std.fmt.allocPrint(self.internal_allocator, "{s}/{s}", .{ self.name, name });
        defer if (self.name.len != 0) self.internal_allocator.free(full_name);

        if (self.filter_pattern) |pattern| {
            if (!filterMatches(pattern, self.name) and
                !filterMatches(pattern, full_name)) return true;
        }

        var sub: B = undefined;
        try self.spawn(&sub, full_name, func);
        defer sub.deinit();
        try sub.run1AndMaybeLaunch();

        if (self.writer) |w| try printBenchmarkResult(w, sub.name, &sub, self.benchmem);
        if (!sub.failed and !sub.skipped) self.addResult(sub.result);
        if (sub.failed) self.failed = true;
        return !sub.failed;
    }

    pub fn startTimer(self: *B) void {
        if (!self.timer_on) {
            self.start_allocs = self.counting_allocator.allocs();
            self.start_bytes = self.counting_allocator.bytes();
            // Enable before the clock starts: the ioctls must not land in
            // the window they measure.
            self.counters.enable();
            self.timer.reset();
            self.timer_on = true;
        }
    }

    pub fn stopTimer(self: *B) void {
        if (self.timer_on) {
            // Read the clock first, then tear the counters down, so the
            // disable and read syscalls stay out of `t_ns`. The counts pick
            // them up instead, which is the cheaper lie of the two.
            self.duration_ns += self.timer.read();
            self.counters.disable();
            self.counters.accumulate();
            self.net_allocs += self.counting_allocator.allocs() - self.start_allocs;
            self.net_bytes += self.counting_allocator.bytes() - self.start_bytes;
            self.timer_on = false;
        }
    }

    pub fn resetTimer(self: *B) void {
        self.duration_ns = 0;
        self.net_allocs = 0;
        self.net_bytes = 0;
        self.counters.reset();
        if (self.timer_on) {
            self.start_allocs = self.counting_allocator.allocs();
            self.start_bytes = self.counting_allocator.bytes();
            self.timer.reset();
        }
        freeMetricKeys(self.internal_allocator, &self.extra);
        self.extra.clearRetainingCapacity();
    }

    pub fn elapsed(self: *B) u64 {
        var d = self.duration_ns;
        if (self.timer_on) d += self.timer.read();
        return d;
    }

    pub fn setBytes(self: *B, n: i64) void {
        self.bytes = n;
    }

    pub fn reportAllocs(self: *B) void {
        self.show_alloc_result = true;
    }

    /// Count hardware events for this benchmark, the per-benchmark form of
    /// `--cycles`: the row gains `cycles/op`, `instructions/op`, `ipc`, and
    /// whatever else the PMU granted. Counters open here, inside the timed
    /// body, so a benchmark that asks for them pays for them whether or not
    /// the suite passed `--cycles`. A host without a PMU reports timings
    /// alone; requesting counters never fails a run.
    pub fn reportCounters(self: *B) void {
        if (self.counters.isOpen()) return;
        self.counters.open() catch |err| {
            self.counters_error = err;
            return;
        };
        if (self.timer_on) self.counters.enable();
    }

    pub fn reportMetric(self: *B, n: f64, unit: []const u8) !void {
        if (unit.len == 0) return Error.InvalidMetricUnit;
        for (unit) |c| if (std.ascii.isWhitespace(c)) return Error.InvalidMetricUnit;

        if (self.extra.getKey(unit)) |old_key| {
            try self.extra.put(self.internal_allocator, old_key, n);
            return;
        }
        const owned_unit = try self.internal_allocator.dupe(u8, unit);
        errdefer self.internal_allocator.free(owned_unit);
        try self.extra.put(self.internal_allocator, owned_unit, n);
    }

    pub fn fail(self: *B) Error!void {
        self.failed = true;
        return Error.BenchmarkFailed;
    }

    pub fn skip(self: *B) Error!void {
        self.skipped = true;
        return Error.BenchmarkSkipped;
    }

    pub fn loop(self: *B) !bool {
        if (self.loop_state.i < self.loop_state.n) {
            self.loop_state.i += 1;
            return true;
        }
        return self.loopSlowPath();
    }

    pub fn runParallel(self: *B, body: *const fn (*Pb) anyerror!void) !void {
        if (self.n == 0) return;

        var grain: u64 = 1;
        if (self.previous_n > 0 and self.previous_duration_ns > 0) {
            grain = 100_000 * self.previous_n / self.previous_duration_ns;
            if (grain < 1) grain = 1;
            if (grain > 10_000) grain = 10_000;
        }

        var global_n: atomic.Value(u64) = .init(0);
        const cpu_count = Thread.getCpuCount() catch 1;
        const thread_count = @max(@as(usize, 1), self.parallelism * cpu_count);
        const threads = try self.internal_allocator.alloc(std.Thread, thread_count);
        defer self.internal_allocator.free(threads);

        var ctx: ParallelContext = .{
            .global_n = &global_n,
            .grain = grain,
            .b_n = self.n,
            .body = body,
            .failed = .init(0),
        };

        for (threads) |*thread| thread.* = try .spawn(.{}, parallelWorker, .{&ctx});
        for (threads) |thread| thread.join();

        if (ctx.failed.load(.seq_cst) != 0) return Error.BenchmarkFailed;
        if (global_n.load(.seq_cst) <= self.n and !self.failed) return self.fail();
    }

    pub fn setParallelism(self: *B, p: usize) void {
        if (p >= 1) self.parallelism = p;
    }

    /// Keep a computed value from being optimized away. Idiomatic shape:
    /// declare the sink, `defer b.keepAlive(sink);`, then compute in the
    /// loop. The defer guarantees the final value is observed, which keeps
    /// every iteration that contributes to it.
    pub inline fn keepAlive(_: *B, value: anytype) void {
        mem.doNotOptimizeAway(value);
    }

    pub inline fn blackBox(_: *B, value: anytype) @TypeOf(value) {
        var runtime_value = value;
        mem.doNotOptimizeAway(&runtime_value);
        return runtime_value;
    }

    fn run1AndMaybeLaunch(self: *B) !void {
        try self.runN(1);
        if (!self.failed and !self.skipped and !self.has_sub) try self.launch();
    }

    fn runN(self: *B, n: u64) !void {
        self.n = n;
        self.loop_state = .{};
        self.parallelism = @max(self.parallelism, 1);
        self.resetTimer();
        self.startTimer();
        self.bench_func.?(self) catch |err| switch (err) {
            Error.BenchmarkFailed => self.failed = true,
            Error.BenchmarkSkipped => self.skipped = true,
            else => self.failed = true,
        };
        self.stopTimer();
        self.previous_n = n;
        self.previous_duration_ns = self.duration_ns;

        // A benchmark that leaves `b.loop()` unfinished is a failure, but it
        // is reported like any other failure instead of aborting the suite.
        if (self.loop_state.n > 0 and !self.loop_state.done and
            !self.failed and !self.skipped)
        {
            self.failed = true;
        }
    }

    fn launch(self: *B) !void {
        if (self.loop_state.n == 0) switch (self.bench_time) {
            .count => |count| if (count > 1) try self.runN(count),
            .duration_ns => |goal| {
                var n: u64 = 1;
                while (!self.failed and self.duration_ns < goal and n < max_predict_iters) {
                    const last = n;
                    n = predictN(goal, self.n, self.duration_ns, last);
                    try self.runN(n);
                }
            },
        };

        self.result.deinit(self.internal_allocator);
        try self.recordCounters();
        self.result = .{
            .n = self.n,
            .t_ns = self.duration_ns,
            .bytes = self.bytes,
            .mem_allocs = self.net_allocs,
            .mem_bytes = self.net_bytes,
            .extra = try cloneMetrics(self.internal_allocator, self.extra),
        };
    }

    /// Turn the raw counter totals into per-op units. `resetTimer` zeroed
    /// them at the start of the timed section, so the totals cover exactly the
    /// window `t_ns` covers.
    fn recordCounters(self: *B) !void {
        if (self.n == 0) return;

        const n: f64 = @floatFromInt(self.n);
        for (std.enums.values(perfcounter.Metric)) |metric| {
            if (!self.counters.available(metric)) continue;
            const total: f64 = @floatFromInt(self.counters.count(metric));
            try self.reportMetric(total / n, metric.unit());
        }

        if (!self.counters.available(.cycles) or !self.counters.available(.instructions)) return;
        const cycles = self.counters.count(.cycles);
        if (cycles == 0) return;
        const instructions: f64 = @floatFromInt(self.counters.count(.instructions));
        try self.reportMetric(instructions / @as(f64, @floatFromInt(cycles)), "ipc");
    }

    fn loopSlowPath(self: *B) !bool {
        if (!self.timer_on) {
            try self.fail();
            return false;
        }

        if (self.loop_state.n == 0) {
            self.loop_state.n = switch (self.bench_time) {
                .count => |count| count,
                .duration_ns => 1,
            };
            self.n = 0;
            self.resetTimer();
            self.loop_state.i += 1;
            return true;
        }

        const more = switch (self.bench_time) {
            .count => false,
            .duration_ns => |goal| blk: {
                const t = self.elapsed();
                if (t >= goal) break :blk false;
                const prev = self.loop_state.n;
                self.loop_state.n = predictN(goal, prev, t, prev);
                break :blk prev < self.loop_state.n;
            },
        };

        if (!more) {
            self.stopTimer();
            self.n = self.loop_state.n;
            self.loop_state.done = true;
            return false;
        }

        self.loop_state.i += 1;
        return true;
    }

    fn addResult(self: *B, other: Result) void {
        self.result.n = 1;
        self.result.t_ns += @intCast(other.nsPerOp());
        if (other.bytes == 0) {
            self.missing_bytes = true;
            self.result.bytes = 0;
        }
        if (!self.missing_bytes) self.result.bytes += other.bytes;
        self.result.mem_allocs += @intCast(other.allocsPerOp());
        self.result.mem_bytes += @intCast(other.allocedBytesPerOp());
    }
};

pub const Pb = struct {
    global_n: *atomic.Value(u64),
    grain: u64,
    cache: u64,
    b_n: u64,

    /// An iterator over `b_n` iterations, with no grain cached yet.
    pub fn init(global_n: *atomic.Value(u64), grain: u64, b_n: u64) Pb {
        return .{ .global_n = global_n, .grain = grain, .cache = 0, .b_n = b_n };
    }

    pub fn next(self: *Pb) bool {
        if (self.cache == 0) {
            const n = self.global_n.fetchAdd(self.grain, .seq_cst) + self.grain;
            if (n <= self.b_n) {
                self.cache = self.grain;
            } else if (n < self.b_n + self.grain) {
                self.cache = self.b_n + self.grain - n;
            } else {
                return false;
            }
        }
        self.cache -= 1;
        return true;
    }
};

const ParallelContext = struct {
    global_n: *atomic.Value(u64),
    grain: u64,
    b_n: u64,
    body: *const fn (*Pb) anyerror!void,
    failed: atomic.Value(u64),
};

fn parallelWorker(ctx: *ParallelContext) void {
    var pb = Pb.init(ctx.global_n, ctx.grain, ctx.b_n);
    ctx.body(&pb) catch ctx.failed.store(1, .seq_cst);
}

/// Run one benchmark function in isolation and return its result.
pub fn benchmark(allocator: Allocator, io: Io, func: Function, options: Options) !Result {
    var suite = B.init(allocator, io, options);
    defer suite.deinit();
    var bench_b: B = undefined;
    try suite.spawn(&bench_b, "bench", func);
    defer bench_b.deinit();
    try bench_b.run1AndMaybeLaunch();
    return .{
        .n = bench_b.result.n,
        .t_ns = bench_b.result.t_ns,
        .bytes = bench_b.result.bytes,
        .mem_allocs = bench_b.result.mem_allocs,
        .mem_bytes = bench_b.result.mem_bytes,
        .extra = try cloneMetrics(allocator, bench_b.result.extra),
    };
}

/// Filters match a benchmark by the name as printed, which carries the
/// `Benchmark` prefix, and by the registered name, which does not. Copy a name
/// out of the output and it selects that benchmark, prefix included.
fn filterMatches(pattern: []const u8, name: []const u8) bool {
    if (filter.matchesAny(pattern, name)) return true;
    var buf: [512]u8 = undefined;
    const printed = std.fmt.bufPrint(&buf, "Benchmark{s}", .{name}) catch return false;
    return filter.matchesAny(pattern, printed);
}

/// The same for the parent half of a sub-benchmark pattern, e.g.
/// `^BenchmarkParent/Selected$`.
fn filterMayMatchChild(pattern: []const u8, name: []const u8) bool {
    if (filter.mayMatchAnyChild(pattern, name)) return true;
    var buf: [512]u8 = undefined;
    const printed = std.fmt.bufPrint(&buf, "Benchmark{s}", .{name}) catch return false;
    return filter.mayMatchAnyChild(pattern, printed);
}

/// The generated bench main calls this: parse flags, run `benchmarkMain`,
/// exit non-zero on failure.
pub fn benchMain(comptime root: type, init: std.process.Init) u8 {
    var suite = B.initProcess(init) catch |err|
        std.process.fatal("testingx: {t}", .{err});
    defer suite.deinit();
    root.benchmarkMain(&suite) catch |err|
        std.process.fatal("testingx: benchmarkMain: {t}", .{err});
    const ok = suite.finish() catch |err|
        std.process.fatal("testingx: {t}", .{err});
    return @intFromBool(!ok);
}

pub fn printUsage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: bench [options]
        \\
        \\Options:
        \\  -h, --help                         show this help
        \\  -c N, -cN, --count N, --count=N    run each benchmark N times
        \\  -t D, -tD, --benchtime D           run each benchmark for duration D
        \\  -t Nx, -tNx, --benchtime Nx        run exactly N iterations
        \\  -f P, -fP, --filter P              run benchmarks matching pattern P
        \\  -m, --benchmem                     print B/op and allocs/op
        \\  -p N, -pN, --parallelism N         default B.runParallel multiplier
        \\  --config K=V                       add config line K: V to the header (repeatable)
        \\  --jsonl                            emit JSONL records instead of benchfmt text
        \\  --no-env                           suppress environment header lines
        \\  --cycles                           add cycles/op, instructions/op, ipc (Linux)
        \\  --disasm P                         disassemble benchmarks matching pattern P
        \\
        \\Durations use ns, us, µs, ms, s, m, or h. Filters are comma-separated glob-like patterns:
        \\plain text contains, ^ anchors start, $ anchors end, * matches any bytes.
        \\
    );
}

/// Strip what moves between two builds: the address column, and the absolute
/// target of a branch (the symbol printed after it does not move). Two builds
/// of the same function then diff clean, which is the whole point.
fn writeNormalized(writer: *Io.Writer, text: []const u8) !void {
    var scratch: [1024]u8 = undefined;
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var out: []const u8 = line;
        var instruction = false;

        // "0000000001086a1c <filter.foo>:" -> "<filter.foo>:"
        if (mem.findScalar(u8, line, '<')) |lt| {
            if (isAddress(mem.trim(u8, line[0..lt], " \t"))) out = line[lt..];
        }
        // " 1086a1c:\tstp\tx29, x30" -> "stp\tx29, x30"
        if (mem.findScalar(u8, out, ':')) |colon| {
            if (isAddress(mem.trim(u8, out[0..colon], " \t"))) {
                out = mem.trim(u8, out[colon + 1 ..], " \t");
                instruction = true;
            }
        }
        // "bl\t10864f8 <bench.B.loop>" -> "bl\t<bench.B.loop>"
        if (mem.findScalar(u8, out, '<')) |lt| {
            if (mem.findScalarLast(u8, out[0..lt], ' ')) |space| {
                if (isAddress(out[space + 1 .. lt])) {
                    const head = out[0 .. space + 1];
                    const tail = out[lt..];
                    if (head.len + tail.len <= scratch.len) {
                        @memcpy(scratch[0..head.len], head);
                        @memcpy(scratch[head.len..][0..tail.len], tail);
                        out = scratch[0 .. head.len + tail.len];
                    }
                }
            }
        }

        if (instruction) try writer.writeByte(' ');
        try writer.writeAll(out);
        try writer.writeByte('\n');
    }
}

fn isAddress(token: []const u8) bool {
    if (token.len == 0) return false;
    const digits = if (mem.startsWith(u8, token, "0x")) token[2..] else token;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn writeCommand(writer: *Io.Writer, argv: []const []const u8) !void {
    for (argv, 0..) |arg, i| {
        if (i != 0) try writer.writeByte(' ');
        try writer.writeAll(arg);
    }
    try writer.writeByte('\n');
}

fn printBenchmarkResult(writer: *Io.Writer, name: []const u8, b: *const B, benchmem: bool) !void {
    if (b.jsonl) return printJsonResult(writer, name, b, benchmem);

    var format: benchfmt.Writer = .init(writer);
    if (b.failed) {
        try format.writeCommentFmt("FAIL: {s}", .{name});
        try writer.flush();
        return;
    }
    if (b.skipped) {
        try format.writeCommentFmt("SKIP: {s}", .{name});
        try writer.flush();
        return;
    }

    var values: std.ArrayList(benchfmt.Value) = .empty;
    defer values.deinit(b.internal_allocator);
    try b.result.appendValues(
        b.internal_allocator,
        &values,
        benchmem or b.show_alloc_result,
    );
    try format.writeResult(name, b.result.n, values.items);
    try writer.flush();
}

const JsonStatus = enum { ok, failed, skipped };

const JsonResult = struct {
    name: []const u8,
    status: JsonStatus,
    iters: ?u64 = null,
    values: ?[]const benchfmt.Value = null,
};

fn printJsonResult(writer: *Io.Writer, name: []const u8, b: *const B, benchmem: bool) !void {
    if (b.failed or b.skipped) {
        const status: JsonStatus = if (b.failed) .failed else .skipped;
        try writeJsonLine(writer, .{ .name = name, .status = status });
        return;
    }

    var values: std.ArrayList(benchfmt.Value) = .empty;
    defer values.deinit(b.internal_allocator);
    try b.result.appendValues(
        b.internal_allocator,
        &values,
        benchmem or b.show_alloc_result,
    );
    try writeJsonLine(writer, .{
        .name = name,
        .status = .ok,
        .iters = b.result.n,
        .values = values.items,
    });
}

fn writeJsonLine(writer: *Io.Writer, record: JsonResult) !void {
    try std.json.Stringify.value(record, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

/// The environment lines, computed once per run.
const Environment = struct {
    target_buf: [128]u8 = undefined,
    target_len: usize = 0,
    cpu: []const u8 = "",
    mode: []const u8 = "",

    fn detect() !Environment {
        var environment: Environment = .{
            .cpu = builtin.cpu.model.name,
            .mode = @tagName(builtin.mode),
        };
        const target = try std.fmt.bufPrint(&environment.target_buf, "{s}-{s}-{s}", .{
            @tagName(builtin.target.cpu.arch),
            @tagName(builtin.target.os.tag),
            @tagName(builtin.target.abi),
        });
        environment.target_len = target.len;
        return environment;
    }

    fn entries(self: *const Environment) [3]benchfmt.Config {
        return .{
            .{ .key = "target", .value = self.target_buf[0..self.target_len] },
            .{ .key = "cpu", .value = self.cpu },
            .{ .key = "mode", .value = self.mode },
        };
    }
};

fn emitHeader(writer: *Io.Writer, options: *const Options, environment: *const Environment) !void {
    // The target triple replaces goos/goarch; `mode` replaces Go's implicit
    // build mode because Debug and ReleaseFast numbers are not comparable.
    var format: benchfmt.Writer = .init(writer);
    for (options.config.items) |entry| try format.writeConfig(entry.key, entry.value);
    if (options.emit_environment) {
        for (environment.entries()) |entry| try format.writeConfig(entry.key, entry.value);
    }
}

fn emitJsonHeader(
    writer: *Io.Writer,
    options: *const Options,
    environment: *const Environment,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("config");
    try json.beginObject();
    for (options.config.items) |entry| {
        try json.objectField(entry.key);
        try json.write(entry.value);
    }
    if (options.emit_environment) {
        for (environment.entries()) |entry| {
            try json.objectField(entry.key);
            try json.write(entry.value);
        }
    }
    try json.endObject();
    try json.endObject();
    try writer.writeByte('\n');
    try writer.flush();
}

const max_predict_iters = 1_000_000_000;

fn predictN(goal_ns: u64, prev_iters: u64, prev_ns_raw: u64, last: u64) u64 {
    const prev_ns = if (prev_ns_raw == 0) 1 else prev_ns_raw;
    var n = goal_ns * prev_iters / prev_ns;
    n += n / 5;
    n = @min(n, 100 * last);
    n = @max(n, last + 1);
    n = @min(n, max_predict_iters);
    return n;
}

// Map clones copy key slices but do not duplicate their storage.
fn cloneMetrics(allocator: Allocator, src: MetricMap) !MetricMap {
    var dst: MetricMap = .empty;
    errdefer {
        freeMetricKeys(allocator, &dst);
        dst.deinit(allocator);
    }

    var it = src.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        try dst.put(allocator, key, entry.value_ptr.*);
    }
    return dst;
}

fn freeMetricKeys(allocator: Allocator, map: *MetricMap) void {
    var it = map.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
}

// The runner embeds its own copy (src/runner.zig) because a file cannot be
// part of two modules. Keep the two duration grammars in sync.
fn parseDurationNs(s: []const u8) !u64 {
    const units = [_]struct { suffix: []const u8, scale: u64 }{
        .{ .suffix = "ns", .scale = 1 },
        .{ .suffix = "us", .scale = time.ns_per_us },
        .{ .suffix = "µs", .scale = time.ns_per_us },
        .{ .suffix = "ms", .scale = time.ns_per_ms },
        .{ .suffix = "s", .scale = time.ns_per_s },
        .{ .suffix = "m", .scale = time.ns_per_min },
        .{ .suffix = "h", .scale = time.ns_per_hour },
    };

    for (units) |unit| {
        if (mem.endsWith(u8, s, unit.suffix)) {
            const value = try std.fmt.parseFloat(f64, s[0 .. s.len - unit.suffix.len]);
            if (value <= 0) return error.InvalidDuration;
            return @intFromFloat(value * @as(f64, @floatFromInt(unit.scale)));
        }
    }
    return error.InvalidDuration;
}

test "benchmarkName strips either prefix and keeps other names" {
    try testing.expectEqualStrings("Sort", comptime B.benchmarkName("benchmarkSort"));
    try testing.expectEqualStrings("Hash", comptime B.benchmarkName("BenchmarkHash"));
    try testing.expectEqualStrings("Plain", comptime B.benchmarkName("Plain"));
}

test "addMod discovers top-level public benchmark declarations only" {
    const Mod = struct {
        pub fn benchmarkSort(_: *B) !void {}
        pub fn benchmarkHash(_: *B) !void {}
        pub fn notABenchmark() void {}
        fn benchmarkPrivate(_: *B) !void {}
        pub const nested = struct {
            pub fn benchmarkNested(_: *B) !void {}
        };
    };

    var suite = B.init(testing.allocator, testing.io, .init);
    defer suite.deinit();
    try suite.addMod(Mod);

    try testing.expectEqual(@as(usize, 2), suite.specs.items.len);
    try testing.expectEqualStrings("Sort", suite.specs.items[0].name);
    try testing.expectEqualStrings("Hash", suite.specs.items[1].name);
}

const phase_suite = struct {
    fn body(b: *B) !void {
        try testing.expectError(Error.InvalidPhase, b.add("Late", body));
    }
};

test "add during execution and run during registration are phase errors" {
    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    var options = Options.init;
    options.writer = &writer;
    options.emit_environment = false;
    options.benchtime = .{ .count = 1 };
    var suite = B.init(testing.allocator, testing.io, options);
    defer suite.deinit();
    try suite.add("Body", phase_suite.body);
    _ = try suite.finish();
    try testing.expectError(Error.InvalidPhase, suite.add("Late", phase_suite.body));
    var fresh = B.init(testing.allocator, testing.io, .init);
    defer fresh.deinit();
    try testing.expectError(Error.InvalidPhase, fresh.run("Early", phase_suite.body));
}

test "filters accept the printed name and the registered name" {
    const Suite = struct {
        fn parent(b: *B) !void {
            _ = try b.run("Selected", selected);
            _ = try b.run("Excluded", excluded);
        }
        fn selected(b: *B) !void {
            while (try b.loop()) {}
        }
        fn excluded(_: *B) !void {
            return error.TestUnexpectedResult;
        }
    };

    // Copy a name out of the output (`BenchmarkParent/Selected`) and anchor
    // it; it selects. The registered form (`Parent/Selected`) selects too.
    for ([_][]const u8{ "^BenchmarkParent/Selected$", "^Parent/Selected$" }) |pattern| {
        var buffer: [4096]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);

        var options = Options.init;
        options.writer = &writer;
        options.emit_environment = false;
        options.filter = pattern;
        options.benchtime = .{ .count = 3 };
        var suite = B.init(testing.allocator, testing.io, options);
        defer suite.deinit();
        try suite.add("Parent", Suite.parent);
        try testing.expect(try suite.finish());

        const output = writer.buffered();
        try testing.expectEqual(@as(usize, 1), mem.count(u8, output, "BenchmarkParent/Selected"));
        try testing.expect(!mem.containsAtLeast(u8, output, 1, "Excluded"));
    }
}

test "registered suite runs with filter, sub-benchmarks, and memory results" {
    const Suite = struct {
        fn parent(b: *B) !void {
            _ = try b.run("Selected", selected);
            _ = try b.run("Excluded", excluded);
        }
        fn selected(b: *B) !void {
            while (try b.loop()) {
                const bytes = try b.allocator.alloc(u8, 16);
                b.allocator.free(bytes);
            }
            try b.reportMetric(42, "ns/op");
            b.setBytes(16);
        }
        fn excluded(_: *B) !void {
            return error.TestUnexpectedResult;
        }
    };

    var buffer: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    var options = Options.init;
    options.writer = &writer;
    options.emit_environment = false;
    options.filter = "^Parent/Selected$";
    options.count = 2;
    options.benchtime = .{ .count = 7 };
    options.benchmem = true;
    var suite = B.init(testing.allocator, testing.io, options);
    defer suite.deinit();
    try suite.add("Parent", Suite.parent);
    try testing.expect(try suite.finish());

    const output = writer.buffered();
    try testing.expectEqual(@as(usize, 2), mem.count(u8, output, "Parent/Selected\t       7"));
    try testing.expectEqual(@as(usize, 2), mem.count(u8, output, "42.00 ns/op"));
    const mem_line = "      16 B/op\t       1 allocs/op";
    try testing.expectEqual(@as(usize, 2), mem.count(u8, output, mem_line));
    try testing.expect(!mem.containsAtLeast(u8, output, 1, "Excluded"));
}

test "failing sub-benchmark fails the suite" {
    const Suite = struct {
        fn parent(b: *B) !void {
            _ = try b.run("Bad", bad);
        }
        fn bad(_: *B) !void {
            return error.TestUnexpectedResult;
        }
    };

    var buffer: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    var options = Options.init;
    options.writer = &writer;
    options.emit_environment = false;
    var suite = B.init(testing.allocator, testing.io, options);
    defer suite.deinit();
    try suite.add("Parent", Suite.parent);
    try testing.expect(!try suite.finish());
    try testing.expect(mem.containsAtLeast(u8, writer.buffered(), 1, "# FAIL: Parent/Bad"));
}

test "predictN matches Go growth constraints" {
    try testing.expectEqual(@as(u64, 100), predictN(1000, 1, 10, 1));
    try testing.expectEqual(@as(u64, 2), predictN(1, 1, 1000, 1));
}

test "Loop benchmark runs and records iterations" {
    const bench_fn = struct {
        fn run(b: *B) !void {
            var x: u64 = 0;
            while (try b.loop()) x +%= 1;
            try b.reportMetric(@floatFromInt(x), "iters");
        }
    }.run;

    var options = Options.init;
    options.benchtime = .{ .count = 5 };
    var result = try benchmark(testing.allocator, testing.io, bench_fn, options);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 5), result.n);
    try testing.expectEqual(@as(f64, 5), result.extra.get("iters").?);
}

test "B.N style benchmark runs requested count" {
    const bench_fn = struct {
        fn run(b: *B) !void {
            var i: u64 = 0;
            while (i < b.n) : (i += 1) {}
        }
    }.run;

    var options = Options.init;
    options.benchtime = .{ .count = 7 };
    var result = try benchmark(testing.allocator, testing.io, bench_fn, options);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 7), result.n);
}

test "b.allocator records timed allocations" {
    const bench_fn = struct {
        fn run(b: *B) !void {
            while (try b.loop()) {
                const memory = try b.allocator.alloc(u8, 16);
                defer b.allocator.free(memory);
            }
        }
    }.run;

    var options = Options.init;
    options.benchtime = .{ .count = 3 };
    var result = try benchmark(testing.allocator, testing.io, bench_fn, options);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 3), result.mem_allocs);
    try testing.expectEqual(@as(u64, 48), result.mem_bytes);
    try testing.expectEqual(@as(i64, 1), result.allocsPerOp());
    try testing.expectEqual(@as(i64, 16), result.allocedBytesPerOp());
}

const TestArgs = std.process.Args.IteratorGeneral(.{});

test "reportCounters adds counter units when the PMU allows" {
    const bench_fn = struct {
        fn run(b: *B) !void {
            b.reportCounters();
            var sink: u64 = 0;
            defer b.keepAlive(sink);
            while (try b.loop()) sink +%= 1;
        }
    }.run;

    var options = Options.init;
    options.benchtime = .{ .count = 1000 };
    var result = try benchmark(testing.allocator, testing.io, bench_fn, options);
    defer result.deinit(testing.allocator);

    // No PMU, or perf_event_paranoid says no: timings only, and no failure.
    const cycles = result.extra.get("cycles/op") orelse return;
    try testing.expect(cycles > 0);
    try testing.expect(result.extra.get("ipc") != null);
}

test "CLI split equal and short flags preserve options" {
    const commands = [_][]const u8{
        "bench --count 2 --benchtime 7x --filter Alloc --parallelism 3 --benchmem --no-env",
        "bench --count=2 --benchtime=7x --filter=Alloc --parallelism=3 --benchmem --no-env",
        "bench -c 2 -t 7x -f Alloc -p 3 -m --no-env",
        "bench -c2 -t7x -fAlloc -p3 -m --no-env",
        "bench -c=2 -t=7x -f=Alloc -p=3 -m --no-env",
    };
    for (commands) |command| {
        var args = try TestArgs.init(testing.allocator, command);
        defer args.deinit();
        var options = try Options.parse(testing.allocator, &args, .init);
        defer options.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), options.count);
        try testing.expectEqual(@as(u64, 7), options.benchtime.count);
        try testing.expectEqualStrings("Alloc", options.filter.?);
        try testing.expectEqual(@as(usize, 3), options.parallelism);
        try testing.expect(options.benchmem);
        try testing.expect(!options.emit_environment);
    }
}

test "CLI help durations defaults and errors" {
    var args = try TestArgs.init(testing.allocator, "bench --help --benchtime=1.5ms");
    defer args.deinit();
    var defaults = Options.init;
    defaults.count = 3;
    var options = try Options.parse(testing.allocator, &args, defaults);
    defer options.deinit(testing.allocator);
    try testing.expect(options.help);
    try testing.expectEqual(@as(usize, 3), options.count);
    try testing.expectEqual(@as(u64, 1_500_000), options.benchtime.duration_ns);

    const cases = .{
        .{ "bench --count", error.MissingBenchmarkOptionValue },
        .{ "bench --count=0", error.InvalidCount },
        .{ "bench --benchtime=0x", error.InvalidCount },
        .{ "bench --unknown", error.UnknownBenchmarkOption },
    };
    inline for (cases) |case| {
        var invalid = try TestArgs.init(testing.allocator, case[0]);
        defer invalid.deinit();
        try testing.expectError(case[1], Options.parse(testing.allocator, &invalid, .init));
    }
}

test "CLI config entries, jsonl, and the argument separator" {
    var args = try TestArgs.init(
        testing.allocator,
        "bench --config=rev=test --config shape=smoke --jsonl -- --benchtime=50x",
    );
    defer args.deinit();
    var options = try Options.parse(testing.allocator, &args, .init);
    defer options.deinit(testing.allocator);

    try testing.expect(options.jsonl);
    try testing.expectEqual(@as(u64, 50), options.benchtime.count);
    try testing.expectEqual(@as(usize, 2), options.config.items.len);
    try testing.expectEqualStrings("rev", options.config.items[0].key);
    try testing.expectEqualStrings("test", options.config.items[0].value);
    try testing.expectEqualStrings("shape", options.config.items[1].key);
    try testing.expectEqualStrings("smoke", options.config.items[1].value);

    const invalid = [_][]const u8{
        "bench --config=novalue",
        "bench --config==value",
        "bench --config=Bad=value",
        "bench --config=key=",
    };
    for (invalid) |command| {
        var bad_args = try TestArgs.init(testing.allocator, command);
        defer bad_args.deinit();
        try testing.expectError(
            error.InvalidConfig,
            Options.parse(testing.allocator, &bad_args, .init),
        );
    }

    var no_value = try TestArgs.init(testing.allocator, "bench --config");
    defer no_value.deinit();
    try testing.expectError(
        error.MissingBenchmarkOptionValue,
        Options.parse(testing.allocator, &no_value, .init),
    );
}

test "slice args parse like iterator args" {
    const argv = [_][]const u8{ "bench", "-c2", "--benchtime=7x" };
    var args = SliceArgs.init(&argv);
    var options = try Options.parse(testing.allocator, &args, .init);
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), options.count);
    try testing.expectEqual(@as(u64, 7), options.benchtime.count);
}

test "parallel benchmark preserves iteration accounting" {
    const work = struct {
        var completed: atomic.Value(u64) = .init(0);
        fn body(pb: *Pb) !void {
            while (pb.next()) _ = completed.fetchAdd(1, .seq_cst);
        }
        fn run(b: *B) !void {
            try b.runParallel(body);
        }
    };
    work.completed.store(0, .seq_cst);
    var options = Options.init;
    options.benchtime = .{ .count = 7 };
    var result = try benchmark(testing.allocator, testing.io, work.run, options);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 7), result.n);
    try testing.expectEqual(@as(u64, 8), work.completed.load(.seq_cst)); // warmup plus measured run
}

test "suite output round-trips through the benchfmt parser" {
    const Suite = struct {
        fn good(b: *B) !void {
            while (try b.loop()) {
                const memory = try b.allocator.alloc(u8, 8);
                b.allocator.free(memory);
            }
            try b.reportMetric(3, "widgets/op");
        }
        fn bad(b: *B) !void {
            try b.fail();
        }
        fn slow(b: *B) !void {
            try b.skip();
        }
        fn group(b: *B) !void {
            _ = try b.run("key=value", good);
            _ = try b.run("8B", good);
        }
    };

    var buffer: [8192]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    var args = try TestArgs.init(
        testing.allocator,
        "bench --config=rev=test --benchtime=3x --count=3",
    );
    defer args.deinit();
    var options = try Options.parse(testing.allocator, &args, .init);
    options.writer = &writer;
    options.emit_environment = false;
    var suite = B.init(testing.allocator, testing.io, options);
    defer suite.deinit();

    try suite.add("Good", Suite.good);
    try suite.add("Bad", Suite.bad);
    try suite.add("SkipMe", Suite.slow);
    try suite.add("Group", Suite.group);
    try testing.expect(!try suite.finish());

    var reader: benchfmt.Reader = .init(testing.allocator, writer.buffered());
    defer reader.deinit();

    var good_count: usize = 0;
    var fail_comments: usize = 0;
    var skip_comments: usize = 0;
    var group_count: usize = 0;
    while (try reader.next()) |record| {
        switch (record) {
            .config => |config| {
                try testing.expectEqualStrings("rev", config.key);
                try testing.expectEqualStrings("test", config.value);
            },
            .comment => |text| {
                if (mem.eql(u8, text, "FAIL: Bad")) fail_comments += 1;
                if (mem.eql(u8, text, "SKIP: SkipMe")) skip_comments += 1;
            },
            .syntax_error => |syntax_error| {
                std.debug.print("unexpected syntax error on line {d}: {s}\n", .{
                    syntax_error.line,
                    syntax_error.message(),
                });
                return error.UnexpectedSyntaxError;
            },
            .result => |result| {
                if (mem.eql(u8, result.name.full, "Good")) {
                    good_count += 1;
                    try testing.expectEqual(@as(u64, 3), result.iters);
                    try testing.expect(result.values.len >= 2);
                    try testing.expectEqualStrings("ns/op", result.values[0].unit);
                    try testing.expectEqualStrings("widgets/op", result.values[1].unit);
                    try testing.expectEqual(@as(f64, 3), result.values[1].value);
                } else if (mem.eql(u8, result.name.full, "Group/key=value") or
                    mem.eql(u8, result.name.full, "Group/8B"))
                {
                    group_count += 1;
                    try testing.expectEqualStrings("Group", result.name.base());
                    var parts = try result.name.parts(testing.allocator);
                    defer parts.deinit();
                    try testing.expectEqual(@as(usize, 2), parts.items.len);
                }
            },
        }
    }

    try testing.expectEqual(@as(usize, 3), good_count);
    try testing.expectEqual(@as(usize, 3), fail_comments);
    try testing.expectEqual(@as(usize, 3), skip_comments);
    try testing.expectEqual(@as(usize, 6), group_count);
    try testing.expectEqualStrings("test", reader.config.get("rev").?);
}

test "jsonl output records config, results, failures, and skips" {
    const Suite = struct {
        fn good(b: *B) !void {
            while (try b.loop()) {}
            try b.reportMetric(2.5, "widgets/op");
        }
        fn bad(b: *B) !void {
            try b.fail();
        }
        fn slow(b: *B) !void {
            try b.skip();
        }
    };

    var buffer: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    var args = try TestArgs.init(
        testing.allocator,
        "bench --config=rev=jsonl --benchtime=2x --jsonl",
    );
    defer args.deinit();
    var options = try Options.parse(testing.allocator, &args, .init);
    options.writer = &writer;
    options.emit_environment = false;
    var suite = B.init(testing.allocator, testing.io, options);
    defer suite.deinit();

    try suite.add("Good", Suite.good);
    try suite.add("Bad", Suite.bad);
    try suite.add("SkipMe", Suite.slow);
    try testing.expect(!try suite.finish());

    var lines = mem.splitScalar(u8, mem.trimEnd(u8, writer.buffered(), "\n"), '\n');
    try testing.expectEqualStrings("{\"config\":{\"rev\":\"jsonl\"}}", lines.next().?);

    const good = try std.json.parseFromSlice(JsonResult, testing.allocator, lines.next().?, .{});
    defer good.deinit();
    try testing.expectEqualStrings("Good", good.value.name);
    try testing.expectEqual(JsonStatus.ok, good.value.status);
    try testing.expectEqual(@as(u64, 2), good.value.iters.?);
    try testing.expectEqual(@as(usize, 2), good.value.values.?.len);
    try testing.expectEqualStrings("widgets/op", good.value.values.?[1].unit);
    try testing.expectEqual(@as(f64, 2.5), good.value.values.?[1].value);

    const bad = try std.json.parseFromSlice(JsonResult, testing.allocator, lines.next().?, .{});
    defer bad.deinit();
    try testing.expectEqualStrings("Bad", bad.value.name);
    try testing.expectEqual(JsonStatus.failed, bad.value.status);
    try testing.expectEqual(@as(?u64, null), bad.value.iters);

    const slow = try std.json.parseFromSlice(JsonResult, testing.allocator, lines.next().?, .{});
    defer slow.deinit();
    try testing.expectEqualStrings("SkipMe", slow.value.name);
    try testing.expectEqual(JsonStatus.skipped, slow.value.status);
    try testing.expectEqual(@as(?[]const benchfmt.Value, null), slow.value.values);

    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "environment header is a benchfmt config block" {
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var options = Options.init;
    options.writer = &writer;
    options.benchtime = .{ .count = 1 };
    var suite = B.init(testing.allocator, testing.io, options);
    defer suite.deinit();
    try testing.expect(try suite.finish());

    var reader: benchfmt.Reader = .init(testing.allocator, writer.buffered());
    defer reader.deinit();

    const expected_keys = [_][]const u8{ "target", "cpu", "mode" };
    for (expected_keys) |key| {
        const record = (try reader.next()).?;
        try testing.expectEqual(benchfmt.Record.config, std.meta.activeTag(record));
        try testing.expectEqualStrings(key, record.config.key);
        try testing.expect(record.config.value.len > 0);
    }
    try testing.expectEqualStrings(@tagName(builtin.mode), reader.config.get("mode").?);
    try testing.expectEqual(@as(?benchfmt.Record, null), try reader.next());
}

test "bench environment options come before the command line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = [_][]const u8{ "bench", "--filter=argv" };
    const args = try collectArgs(arena, &argv, .{
        .filter = "env pattern",
        .jsonl = "true",
    });
    try testing.expectEqualStrings("bench", args[0]);
    try testing.expectEqualStrings("--filter=env pattern", args[1]);
    try testing.expectEqualStrings("--jsonl", args[2]);
    try testing.expectEqualStrings("--filter=argv", args[3]);

    var parsed_args = SliceArgs.init(args);
    const options = try Options.parse(arena, &parsed_args, .init);
    try testing.expectEqualStrings("argv", options.filter.?);
    try testing.expect(options.jsonl);
}
