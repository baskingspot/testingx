//! Embedded fixtures: txtar archives and base64 or hex blobs, read at comptime.
//!
//! `fixtures` parses an embedded txtar archive into compile-time constants.
//! `b64` and `hex` decode one embedded file with no archive around it.

const std = @import("std");
const mem = std.mem;

const txtar = @import("txtar.zig");

pub const Fixture = struct {
    /// The marker name.
    name: []const u8,
    /// The section text, without decoding.
    text: []const u8,
};

/// An embedded txtar archive, read at comptime.
///
/// `archive` must be comptime-known; `@embedFile` provides that. The value
/// holds the comment and the section list; the decoded bytes live in
/// compile-time constants on the generated type. A local
/// `const fx = fixtures(@embedFile(...))` works.
///
/// The value has:
/// - `comment`: the archive comment.
/// - `files`: every section, as `Fixture { name, text }`.
/// - `get(name)`: the section text.
/// - `b64(name)` and `hex(name)`: decoded bytes.
/// - `find(name)`: runtime lookup, returning a `Fixture`.
pub fn fixtures(comptime archive: []const u8) Set(archive) {
    const T = Set(archive);
    return .{ .comment = T.parsed.comment, .files = &T.data };
}

fn Set(comptime archive: []const u8) type {
    return struct {
        const Self = @This();
        const parsed = txtar.parse(archive);
        const data = buildFiles(parsed.files.len, parsed.files);

        /// The archive comment, verbatim.
        comment: []const u8,

        /// Every section, in archive order.
        files: []const Fixture,

        /// The section text, as stored in the archive.
        ///
        /// A name that is not in the archive is a compile error.
        pub fn get(_: Self, comptime name: []const u8) []const u8 {
            return section(name).text;
        }

        /// Base64-decode a section at comptime. Whitespace is ignored, so
        /// wrapped base64 works.
        pub fn b64(_: Self, comptime name: []const u8) []const u8 {
            return decode(section(name).text, .base64);
        }

        /// Hex-decode a section at comptime. Whitespace is ignored.
        pub fn hex(_: Self, comptime name: []const u8) []const u8 {
            return decode(section(name).text, .hex);
        }

        /// Runtime lookup for a name that is not known at comptime. Returns
        /// the section text without decoding.
        pub fn find(self: Self, name: []const u8) ?Fixture {
            for (self.files) |file| {
                if (std.mem.eql(u8, file.name, name)) return file;
            }
            return null;
        }

        fn section(comptime name: []const u8) Fixture {
            return comptime blk: {
                for (data) |file| {
                    if (std.mem.eql(u8, file.name, name)) break :blk file;
                }
                var message: []const u8 = "no fixture named '" ++ name ++ "'. Known names:";
                for (data) |file| message = message ++ "\n  " ++ file.name;
                @compileError(message);
            };
        }
    };
}

/// Base64-decode one embedded file at comptime.
pub inline fn b64(comptime text: []const u8) []const u8 {
    return decode(text, .base64);
}

/// Hex-decode one embedded file at comptime.
pub inline fn hex(comptime text: []const u8) []const u8 {
    return decode(text, .hex);
}

const Encoding = enum { base64, hex };

fn decode(comptime text: []const u8, comptime encoding: Encoding) []const u8 {
    @setEvalBranchQuota(comptime quota(text));
    const bytes = comptime blk: {
        var clean: [text.len]u8 = undefined;
        var len: usize = 0;
        for (text) |c| {
            if (std.ascii.isWhitespace(c)) continue;
            clean[len] = c;
            len += 1;
        }
        const stripped = clean[0..len];
        switch (encoding) {
            .base64 => {
                const size = std.base64.standard.Decoder.calcSizeForSlice(stripped) catch
                    @compileError("invalid base64 fixture");
                var out: [size]u8 = undefined;
                _ = std.base64.standard.Decoder.decode(&out, stripped) catch
                    @compileError("invalid base64 fixture");
                break :blk out;
            },
            .hex => {
                if (stripped.len % 2 != 0) @compileError("odd-length hex fixture");
                var out: [stripped.len / 2]u8 = undefined;
                _ = std.fmt.hexToBytes(&out, stripped) catch
                    @compileError("invalid hex fixture");
                break :blk out;
            },
        }
    };
    // A slice into a container-level constant, so the decoded bytes are static.
    const S = struct {
        const data = bytes;
    };
    return &S.data;
}

fn buildFiles(comptime n: usize, comptime entries: [n]txtar.File) [n]Fixture {
    // Sort the names once to find duplicates in O(n log n) instead of
    // comparing every pair. The budget stays linear, with headroom for the
    // log factor; the default 1000 is not enough for a large archive.
    @setEvalBranchQuota(@intCast(10_000 + n * 512));

    var names: [n][]const u8 = undefined;
    for (entries, 0..) |entry, i| names[i] = entry.name;
    std.mem.sortUnstable([]const u8, &names, {}, nameLessThan);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        if (std.mem.eql(u8, names[i - 1], names[i])) {
            @compileError("duplicate fixture name '" ++ names[i] ++ "'");
        }
    }

    var files: [n]Fixture = undefined;
    for (entries, 0..) |entry, j| {
        files[j] = .{ .name = entry.name, .text = entry.text };
    }
    return files;
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn quota(comptime text: []const u8) u32 {
    const branches = 1_000_000 + text.len * 32;
    return @intCast(@min(branches, std.math.maxInt(u32)));
}

const sample =
    \\fixtures for the tests
    \\-- input.json --
    \\{"name":"test"}
    \\-- cert.der --
    \\aGVsbG8g
    \\YmFzZTY0
    \\-- frame --
    \\00 ff 10
    \\-- data.txt --
    \\data:text/plain,this is not metadata
    \\
;

test "sections" {
    const fx = fixtures(sample);
    try std.testing.expectEqualStrings("fixtures for the tests\n", fx.comment);
    try std.testing.expectEqualStrings("{\"name\":\"test\"}\n", fx.get("input.json"));
    try std.testing.expectEqualStrings("aGVsbG8g\nYmFzZTY0\n", fx.get("cert.der"));
    try std.testing.expectEqualSlices(u8, "hello base64", fx.b64("cert.der"));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, 0x10 }, fx.hex("frame"));
    try std.testing.expectEqualStrings(
        "data:text/plain,this is not metadata\n",
        fx.get("data.txt"),
    );
    try std.testing.expectEqual(@as(usize, 4), fx.files.len);
    try std.testing.expect(fx.find("nope") == null);
}

test "a local archive binding works" {
    const fx = fixtures(sample);
    const cert = fx.b64("cert.der");
    try std.testing.expectEqualSlices(u8, "hello base64", cert);
}

test "one embedded blob" {
    const decoded = b64("aGVs\nbG8=");
    try std.testing.expectEqualSlices(u8, "hello", decoded);

    const bytes = hex("00 ff\n10");
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, 0x10 }, bytes);
}

test "embedded archive" {
    const fx = fixtures(@embedFile("testdata/fixtures.txtar"));
    try std.testing.expectEqualStrings("embedded fixture\n", fx.comment);
    try std.testing.expectEqualSlices(u8, "embedded", fx.b64("blob"));
}

test "embedded single blob" {
    try std.testing.expectEqualSlices(
        u8,
        "embedded",
        b64(@embedFile("testdata/blob.b64")),
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0xff, 0x10 },
        hex(@embedFile("testdata/blob.hex")),
    );
}

test "a large archive builds without hitting the eval budget" {
    // Duplicate detection sorts the names, so the comptime cost grows as
    // O(n log n). A real archive (ztls carries 73) runs past the default 1000
    // branches.
    const big = comptime blk: {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = "";
        for (0..100) |i| {
            text = text ++ std.fmt.comptimePrint("-- section{d} --\n00\n", .{i});
        }
        break :blk text;
    };
    const fx = fixtures(big);
    try std.testing.expectEqual(@as(usize, 100), fx.files.len);
    try std.testing.expectEqualStrings("00\n", fx.get("section99"));
}
