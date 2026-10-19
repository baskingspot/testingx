//! Compile-time txtar parsing.
//!
//! The grammar matches mattrobenolt/txtar: a comment, then `-- name --`
//! markers with section text between them. This module reads only. The
//! standalone txtar library owns writing, formatting, and streaming.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

pub const File = struct {
    /// The marker name, trimmed.
    name: []const u8,
    /// Section text. A final line without a newline gains one, as in txtar.
    text: []const u8,
};

pub fn Parse(comptime n: usize) type {
    return struct {
        comment: []const u8,
        files: [n]File,
    };
}

pub fn parse(comptime text: []const u8) Parse(count(text)) {
    @setEvalBranchQuota(comptime quota(text));
    return .{
        .comment = commentText(text),
        .files = buildFiles(text),
    };
}

pub fn count(comptime text: []const u8) usize {
    @setEvalBranchQuota(comptime quota(text));
    var n: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const end = lineEnd(text, pos);
        if (markerName(text[pos..end]) != null) n += 1;
        pos = nextPos(text, end);
    }
    return n;
}

/// The marker name for a line, or null when the line is content.
pub fn markerName(line: []const u8) ?[]const u8 {
    const trimmed = mem.trimEnd(u8, line, "\r");
    if (!mem.startsWith(u8, trimmed, "-- ")) return null;
    if (!mem.endsWith(u8, trimmed, " --")) return null;
    const name = mem.trim(u8, trimmed[3 .. trimmed.len - 3], &std.ascii.whitespace);
    if (name.len == 0) return null;
    return name;
}

fn buildFiles(comptime text: []const u8) [count(text)]File {
    @setEvalBranchQuota(comptime quota(text));
    var files: [count(text)]File = undefined;
    var index: usize = 0;
    var pos: usize = 0;
    var pending: ?[]const u8 = null;
    var start: usize = 0;
    while (pos < text.len) {
        const end = lineEnd(text, pos);
        if (markerName(text[pos..end])) |name| {
            if (pending) |prev| {
                files[index] = .{ .name = prev, .text = withNewline(text[start..pos]) };
                index += 1;
            }
            pending = name;
            start = nextPos(text, end);
        }
        pos = nextPos(text, end);
    }
    if (pending) |prev| {
        files[index] = .{ .name = prev, .text = withNewline(text[start..]) };
    }
    return files;
}

fn commentText(comptime text: []const u8) []const u8 {
    @setEvalBranchQuota(comptime quota(text));
    var pos: usize = 0;
    while (pos < text.len) {
        const end = lineEnd(text, pos);
        if (markerName(text[pos..end]) != null) return withNewline(text[0..pos]);
        pos = nextPos(text, end);
    }
    return withNewline(text);
}

fn withNewline(comptime text: []const u8) []const u8 {
    if (text.len == 0 or text[text.len - 1] == '\n') return text;
    return struct {
        const s = text ++ "\n";
    }.s;
}

fn lineEnd(text: []const u8, pos: usize) usize {
    return mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
}

fn nextPos(text: []const u8, end: usize) usize {
    return if (end < text.len) end + 1 else text.len;
}

fn quota(comptime text: []const u8) u32 {
    const branches = 100_000 + text.len * 32;
    return @intCast(@min(branches, std.math.maxInt(u32)));
}

test "comment and files" {
    const p = comptime parse("hello\n-- a.txt --\nworld\n-- b --\nx");
    try testing.expectEqualStrings("hello\n", p.comment);
    try testing.expectEqual(@as(usize, 2), p.files.len);
    try testing.expectEqualStrings("a.txt", p.files[0].name);
    try testing.expectEqualStrings("world\n", p.files[0].text);
    try testing.expectEqualStrings("x\n", p.files[1].text);
}

test "empty archive and comment only" {
    const e = comptime parse("");
    try testing.expectEqual(@as(usize, 0), e.files.len);
    try testing.expectEqualStrings("", e.comment);

    const c = comptime parse("just a comment");
    try testing.expectEqual(@as(usize, 0), c.files.len);
    try testing.expectEqualStrings("just a comment\n", c.comment);
}

test "empty section stays empty" {
    const p = comptime parse("-- a --\n-- b --\nx");
    try testing.expectEqualStrings("", p.files[0].text);
    try testing.expectEqualStrings("x\n", p.files[1].text);
}

test "a marker needs both delimiters" {
    const p = comptime parse("-- a --\nhello\n-- not a marker\nworld\n");
    try testing.expectEqual(@as(usize, 1), p.files.len);
    try testing.expectEqualStrings("hello\n-- not a marker\nworld\n", p.files[0].text);
}

test "crlf marker lines" {
    const p = comptime parse("-- a --\r\nhello\r\n");
    try testing.expectEqualStrings("a", p.files[0].name);
    try testing.expectEqualStrings("hello\r\n", p.files[0].text);
}
