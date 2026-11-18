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

// A seed file holds the bytes the target receives. `Smith.slice` reads a
// length before the bytes, and the adapter writes that frame, so these stay
// raw. The last entry is longer than `max_len`, and it must arrive truncated
// rather than reinterpreted.
const long_seed = "0123456789012345678901234567890123456789012345678901234567890123456789";
const corpus = [_][]const u8{ "hello", "world", long_seed };

const Replay = struct {
    index: usize = 0,

    fn one(self: *Replay, input: []const u8) anyerror!void {
        // Fuzz mode mutates rather than replaying the corpus, so these
        // assertions only hold for a replay. The expected-fail probe covers
        // the mutation path.
        if (builtin.fuzz) return;

        // An entry reaches the target as itself: `hello` as `hello`, no
        // prefix in the file and nothing consumed on the way in. An entry
        // longer than `max_len` arrives as its first `max_len` bytes, which
        // is a truncation of the seed and not the length read back some
        // other way.
        const entry: []const u8 = if (self.index < corpus.len) corpus[self.index] else "";
        try testing.expectEqualStrings(entry[0..@min(entry.len, max_len)], input);
        self.index += 1;
    }
};

test "fuzzBytes replays the corpus and one empty input" {
    var replay: Replay = .{};
    try testingx.fuzzBytes(&replay, max_len, Replay.one, .{ .corpus = &corpus });
    if (!builtin.fuzz) {
        try testing.expectEqual(corpus.len + 1, replay.index);
    }
}
