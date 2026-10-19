//! Fixture for --rerun-fails: fails on the first call, passes on the second.

const std = @import("std");
const testing = std.testing;

var attempts: usize = 0;

test "flaky demonstration" {
    attempts += 1;
    if (attempts == 1) return error.FirstAttemptFails;
    try testing.expectEqual(@as(usize, 2), attempts);
}
