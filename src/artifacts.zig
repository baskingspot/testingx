//! Retention for test output.
//!
//! A test asks for a directory, writes files into it, and the runner keeps the
//! directory only when the test fails. The path appears under the failure, so
//! the files are where the person reading the failure looks.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The directory this test may write files into, or null when the runner was
/// not asked to collect artifacts with `--artifacts=DIR` or
/// `TESTINGX_ARTIFACTS`.
///
/// Call this from a test. The directory is created on the first call. The
/// runner keeps it when the test fails, deletes it when the test passes, and
/// prints its path with the failure. The returned path belongs to `allocator`.
///
/// The value travels on `std.testing.environ`, the one channel the runner and
/// the test module share.
pub fn artifactDir(allocator: Allocator) !?[]const u8 {
    const path = std.testing.environ.getAlloc(
        allocator,
        "TESTINGX_ARTIFACT_DIR",
    ) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    errdefer allocator.free(path);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    return path;
}

/// Write `name` into the test's artifact directory. Does nothing when the
/// runner was not asked to keep artifacts.
///
/// `name` is relative to the directory, which already exists. A name that
/// contains a path separator needs the parent directory to exist first.
pub fn writeArtifact(allocator: Allocator, name: []const u8, bytes: []const u8) !void {
    const dir = (try artifactDir(allocator)) orelse return;
    defer allocator.free(dir);

    const path = try std.Io.Dir.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);

    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}
