//! Runner fixtures include intentional failures, a skip, and a leak.
//! The build checks their output and exit status.

const std = @import("std");
const testing = std.testing;

test "basic arithmetic passes" {
    // Captured and dropped: quiet and dots must not print a passing log.
    std.log.info("basic arithmetic {d}", .{1 + 1});
    try testing.expect(1 + 1 == 2);
}

test "string equality passes" {
    std.log.info("comparing {s}", .{"hello"});
    try testing.expectEqualStrings("hello", "hello");
}

test "skip demonstration" {
    return error.SkipZigTest;
}

test "intentional failure" {
    std.log.info("about to fail", .{});
    try testing.expect(1 == 2);
}

test "memory leak detection" {
    const allocator = testing.allocator;
    _ = try allocator.alloc(u8, 64);
}

test "emits error log but succeeds" {
    // Error logs must fail this test despite its successful return.
    std.log.err("something went wrong", .{});
    try testing.expect(true);
}

test "fuzz: simple corpus" {
    // Corpus execution does not require the server protocol.
    try testing.fuzz(.{}, fuzzCallback, .{
        .corpus = &.{
            "hello",
            "world",
            "",
        },
    });
}

fn fuzzCallback(_: @TypeOf(.{}), smith: *testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    _ = smith.slice(&buf);
}

test "fuzz corpus matches the standard runner" {
    var calls: u32 = 0;
    try testing.fuzz(&calls, fuzzCorpusCallback, .{ .corpus = &.{"hello"} });
    try testing.expectEqual(@as(u32, 2), calls);
}

fn fuzzCorpusCallback(calls: *u32, smith: *testing.Smith) anyerror!void {
    const expected: []const u8 = if (calls.* == 0) "hello" else "";
    try testing.expectEqualStrings(expected, smith.in.?);
    calls.* += 1;
}

test "fuzz without a corpus runs an empty smoke test" {
    var calls: u32 = 1;
    try testing.fuzz(&calls, fuzzCorpusCallback, .{});
    try testing.expectEqual(@as(u32, 2), calls);
}

test "testing.io and environ are initialized" {
    const allocator = testing.allocator;
    const path = try testing.environ.getAlloc(allocator, "PATH");
    defer allocator.free(path);
    try testing.expect(path.len > 0);
    const start = std.Io.Clock.Timestamp.now(testing.io, .awake);
    try testing.io.sleep(.fromMilliseconds(1), .awake);
    try testing.expect(start.untilNow(testing.io).raw.nanoseconds > 0);
}

test "seed supplied by runner" {
    const allocator = testing.allocator;
    const expected = testing.environ.getAlloc(
        allocator,
        "TESTINGX_EXPECT_SEED",
    ) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => return err,
    };
    defer allocator.free(expected);
    const seed = try std.fmt.parseUnsigned(u32, expected, 0);
    try testing.expectEqual(seed, testing.random_seed);
}
