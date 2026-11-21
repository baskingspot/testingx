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
pub const benchPanic = bench.panic;

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
///
/// A corpus entry is the bytes the target receives, so a seed file named for
/// what the target should see holds exactly that. `Smith.slice` reads a length
/// before the bytes, so the adapter frames each entry and no seed file carries
/// a hand-written prefix.
///
/// Two consequences follow. An entry longer than `max_len` reaches the target
/// as its first `max_len` bytes: the adapter writes the length that will
/// arrive, because an untouched length is read back as 0 during corpus replay
/// and as an arbitrary length under the fuzzer. And an input the fuzzer saved
/// is already framed, so a crash file cannot be copied into `options.corpus`
/// as-is; unwrap it first, or keep it out of the corpus.
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

    // No corpus means nothing to frame, and the empty smoke input is added by
    // the runner, so this path stays allocation-free.
    if (options.corpus.len == 0) return testing.fuzz(context, Wrapper.run, options);

    const framed = try frameCorpus(options.corpus, max_len);
    defer {
        testing.allocator.free(framed.bytes);
        testing.allocator.free(framed.entries);
    }
    var framed_options = options;
    framed_options.corpus = framed.entries;
    return testing.fuzz(context, Wrapper.run, framed_options);
}

const FramedCorpus = struct {
    entries: [][]const u8,
    bytes: []u8,
};

/// Prefix every entry with the little-endian u32 length `Smith.slice` consumes.
/// The copies live until `testing.fuzz` returns, because both runners keep the
/// corpus for the whole run.
///
/// The length is clamped to `max_len`. A longer length would be read back as 0
/// in corpus replay, and as an arbitrary length under the fuzzer, so the target
/// would see something unrelated to the seed rather than its first `max_len`
/// bytes.
fn frameCorpus(corpus: []const []const u8, max_len: usize) !FramedCorpus {
    var total: usize = 0;
    for (corpus) |entry| total += @sizeOf(u32) + @min(entry.len, max_len);

    const bytes = try testing.allocator.alloc(u8, total);
    errdefer testing.allocator.free(bytes);
    const entries = try testing.allocator.alloc([]const u8, corpus.len);
    errdefer testing.allocator.free(entries);

    var offset: usize = 0;
    for (corpus, entries) |entry, *slot| {
        const len = @min(entry.len, max_len);
        std.mem.writeInt(u32, bytes[offset..][0..@sizeOf(u32)], @intCast(len), .little);
        @memcpy(bytes[offset + @sizeOf(u32) ..][0..len], entry[0..len]);
        slot.* = bytes[offset..][0 .. @sizeOf(u32) + len];
        offset += @sizeOf(u32) + len;
    }
    return .{ .entries = entries, .bytes = bytes };
}

test "frameCorpus writes the length before the bytes" {
    const corpus = [_][]const u8{ "hello", "", "ab" };
    const framed = try frameCorpus(&corpus, 64);
    defer {
        testing.allocator.free(framed.bytes);
        testing.allocator.free(framed.entries);
    }

    try testing.expectEqual(corpus.len, framed.entries.len);
    try testing.expectEqualSlices(u8, "\x05\x00\x00\x00hello", framed.entries[0]);
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x00", framed.entries[1]);
    try testing.expectEqualSlices(u8, "\x02\x00\x00\x00ab", framed.entries[2]);
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
