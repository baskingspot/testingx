//! Fixture for the timeout watchdog: one test that outlasts --timeout.

const std = @import("std");
const testing = std.testing;

test "timeout demonstration" {
    try testing.io.sleep(.fromMilliseconds(2000), .awake);
}
