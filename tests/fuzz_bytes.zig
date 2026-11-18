//! Fuzz fixture for `testingx.fuzzBytes`.
//!
//! This root imports testingx for the adapter only. Compiling it is the check
//! that a fuzz-only module does not analyze the bench engine. The `test` step
//! runs it under testingx's runner, which replays the corpus and the empty
//! smoke input. Mutation is proved by `tests/fuzz_probe.zig`, an expected-fail
//! step.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const testingx = @import("testingx");

const max_len = 64;

// In a replayed corpus, `Smith.slice` reads a little-endian u32 length and
// then that many bytes. A raw string is not a slice input.
const hello_seed = std.mem.toBytes(std.mem.nativeToLittle(u32, 5)) ++ "hello";
const world_seed = std.mem.toBytes(std.mem.nativeToLittle(u32, 5)) ++ "world";

const Replay = struct {
    index: usize = 0,

    fn one(self: *Replay, input: []const u8) anyerror!void {
        // Fuzz mode does not replay the corpus through this callback. The
        // expected-fail probe covers that path.
        if (builtin.fuzz) return;

        const corpus = [_][]const u8{ "hello", "world", "" };
        try testing.expect(self.index < corpus.len);
        try testing.expectEqualStrings(corpus[self.index], input);
        self.index += 1;
    }
};

test "fuzzBytes replays the corpus and one empty input" {
    var replay: Replay = .{};
    try testingx.fuzzBytes(&replay, max_len, Replay.one, .{
        .corpus = &.{ hello_seed, world_seed },
    });
    if (!builtin.fuzz) {
        try testing.expectEqual(@as(usize, 3), replay.index);
    }
}
