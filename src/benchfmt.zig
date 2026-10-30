//! The Go benchmark file format: https://golang.org/design/14313-benchmark-format
//!
//! A stream is a sequence of lines. Configuration lines set key/value pairs for
//! the results that follow, result lines name a benchmark and its measurements,
//! and everything else (including `#` comments) is ignorable for tooling:
//!
//!     rev: 4f2b1c9
//!     target: aarch64-linux-gnu
//!     BenchmarkSort/Quick  1200  99.18 ns/op  16 B/op  1 allocs/op
//!     # FAIL: BenchmarkBroken
//!
//! The reader and writer mirror golang.org/x/perf/benchfmt: the writer streams
//! records, and the reader parses a byte slice into records plus an accumulated
//! configuration map. Reader records are valid until the next call, and syntax
//! errors are records, not fatal errors.
//!
//! Keys are checked against the ASCII subset of the benchfmt key rule: a key
//! begins with a lowercase letter and contains no whitespace, uppercase letter,
//! or colon. Values are free text without newlines. Result names are the text
//! after the `Benchmark` prefix; the writer adds the prefix, and the reader
//! strips it, matching `benchfmt.Name.Full()`. Unit metadata lines
//! (`Unit <unit> key=value`) are not interpreted; the reader ignores them and
//! the writer never emits them.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const testing = std.testing;

pub const Error = error{
    InvalidConfigKey,
    InvalidConfigValue,
    InvalidCommentText,
    InvalidName,
    InvalidUnit,
    MissingValues,
};

/// One configuration line, or one `--config` entry.
pub const Config = struct {
    key: []const u8,
    value: []const u8,
};

/// One `<value> <unit>` measurement from a result line.
pub const Value = struct {
    value: f64,
    unit: []const u8,
};

/// Writer emits benchfmt lines to `writer`.
pub const Writer = struct {
    writer: *Io.Writer,

    pub fn init(writer: *Io.Writer) Writer {
        return .{ .writer = writer };
    }

    /// Write one configuration line. An empty value is written as `key:`,
    /// which readers interpret as deleting the key.
    pub fn writeConfig(self: *Writer, key: []const u8, value: []const u8) !void {
        if (!isValidConfigKey(key)) return Error.InvalidConfigKey;
        if (mem.findScalar(u8, value, '\n') != null) return Error.InvalidConfigValue;

        if (value.len == 0) {
            try self.writer.print("{s}:\n", .{key});
        } else {
            try self.writer.print("{s}: {s}\n", .{ key, value });
        }
    }

    /// Write one result line. The writer supplies the `Benchmark` prefix and
    /// keeps the columns aligned; any run of whitespace parses as a separator.
    pub fn writeResult(
        self: *Writer,
        name: []const u8,
        iters: u64,
        values: []const Value,
    ) !void {
        if (!isValidName(name)) return Error.InvalidName;
        if (values.len == 0) return Error.MissingValues;
        for (values) |value| {
            if (!isValidUnit(value.unit)) return Error.InvalidUnit;
        }

        try self.writer.print("Benchmark{s}\t{d:>8}", .{ name, iters });
        for (values) |value| {
            try self.writer.writeByte('\t');
            try writeValue(self.writer, value.value, value.unit);
        }
        try self.writer.writeByte('\n');
    }

    /// Write one comment line, e.g. a FAIL or SKIP marker that must stay out
    /// of the result stream.
    pub fn writeComment(self: *Writer, text: []const u8) !void {
        if (mem.findScalar(u8, text, '\n') != null) return Error.InvalidCommentText;
        try self.writer.print("# {s}\n", .{text});
    }

    /// Write one formatted comment line.
    pub fn writeCommentFmt(self: *Writer, comptime format: []const u8, args: anytype) !void {
        try self.writer.writeAll("# ");
        try self.writer.print(format, args);
        try self.writer.writeByte('\n');
    }
};

pub const Name = struct {
    /// The name without the `Benchmark` prefix, e.g. `Sort/Quick-8`.
    full: []const u8,

    /// The base name, without any `/part` or trailing `-N` GOMAXPROCS suffix.
    pub fn base(self: Name) []const u8 {
        if (mem.findScalar(u8, self.full, '/')) |slash| return self.full[0..slash];
        return self.splitGomaxprocs().prefix;
    }

    /// Split off Go's trailing `-N` GOMAXPROCS suffix, if present.
    pub fn splitGomaxprocs(self: Name) Gomaxprocs {
        var i = self.full.len;
        while (i > 0) {
            i -= 1;
            const c = self.full[i];
            if (c == '-' and i < self.full.len - 1) {
                return .{ .prefix = self.full[0..i], .gomaxprocs = self.full[i..] };
            }
            if (c < '0' or c > '9') break;
        }
        return .{ .prefix = self.full, .gomaxprocs = null };
    }

    pub const Gomaxprocs = struct {
        prefix: []const u8,
        gomaxprocs: ?[]const u8,
    };

    /// Split the name into its base and sub-benchmark parts. Each part is one
    /// of `/key=value`, `/positional`, or a trailing `-N` GOMAXPROCS suffix.
    /// `items[0]` is the base; concatenating `items` rebuilds `full`.
    pub fn parts(self: Name, allocator: Allocator) !Parts {
        const split = self.splitGomaxprocs();
        var count: usize = 1;
        for (split.prefix) |c| {
            if (c == '/') count += 1;
        }
        const has_gomaxprocs = split.gomaxprocs != null;
        const items = try allocator.alloc([]const u8, count + @intFromBool(has_gomaxprocs));
        errdefer allocator.free(items);

        var index: usize = 0;
        var previous: usize = 0;
        for (split.prefix, 0..) |c, i| {
            if (c != '/') continue;
            items[index] = split.prefix[previous..i];
            index += 1;
            previous = i;
        }
        items[index] = split.prefix[previous..];
        index += 1;
        if (split.gomaxprocs) |suffix| {
            items[index] = suffix;
            index += 1;
        }

        std.debug.assert(index == items.len);
        return .{ .items = items, .allocator = allocator };
    }

    pub const Parts = struct {
        items: []const []const u8,
        allocator: Allocator,

        pub fn deinit(self: *Parts) void {
            self.allocator.free(self.items);
            self.* = undefined;
        }
    };
};

/// One parsed result line.
pub const Result = struct {
    name: Name,
    iters: u64,
    /// Borrowed from the reader; valid until the next `Reader.next` call.
    values: []const Value,
};

/// A recoverable parse error. Scanning continues after one is returned.
pub const SyntaxError = struct {
    line: usize,
    kind: Kind,

    pub const Kind = enum {
        missing_name,
        missing_iterations,
        invalid_iterations,
        missing_measurements,
        invalid_measurement,
        missing_unit,
    };

    pub fn message(self: SyntaxError) []const u8 {
        return switch (self.kind) {
            .missing_name => "missing benchmark name",
            .missing_iterations => "missing iteration count",
            .invalid_iterations => "invalid iteration count",
            .missing_measurements => "missing measurements",
            .invalid_measurement => "invalid measurement",
            .missing_unit => "missing units",
        };
    }
};

pub const Record = union(enum) {
    config: Config,
    result: Result,
    comment: []const u8,
    syntax_error: SyntaxError,
};

/// Reader parses a benchfmt stream held in memory.
pub const Reader = struct {
    allocator: Allocator,
    input: []const u8,
    offset: usize,
    line: usize,
    /// Configuration accumulated from every config line read so far.
    config: ConfigMap,
    values: std.ArrayList(Value),

    pub const ConfigMap = std.array_hash_map.String([]const u8);

    pub fn init(allocator: Allocator, input: []const u8) Reader {
        return .{
            .allocator = allocator,
            .input = input,
            .offset = 0,
            .line = 0,
            .config = .empty,
            .values = .empty,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.config.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    /// Return the next record, or null at end of input. Syntax errors are
    /// returned as records; parsing resumes on the next line.
    pub fn next(self: *Reader) !?Record {
        while (self.readLine()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '#') return .{ .comment = commentText(line) };
            if (mem.startsWith(u8, line, "Benchmark")) {
                if (try self.parseResult(line)) |record| return record;
                continue;
            }
            if (parseConfigLine(line)) |config| {
                if (config.value.len == 0) {
                    _ = self.config.orderedRemove(config.key);
                } else {
                    try self.config.put(self.allocator, config.key, config.value);
                }
                return .{ .config = config };
            }
        }
        return null;
    }

    fn readLine(self: *Reader) ?[]const u8 {
        if (self.offset >= self.input.len) return null;

        const start = self.offset;
        const newline = mem.findScalar(u8, self.input[start..], '\n');
        const end = if (newline) |i| start + i else self.input.len;
        self.offset = if (newline != null) end + 1 else end;
        self.line += 1;

        const line = self.input[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
        return line;
    }

    fn parseResult(self: *Reader, line: []const u8) !?Record {
        var rest = line["Benchmark".len..];
        const name_field_len = rest.len;
        const name = splitField(&rest);

        // `go test -v` prints the benchmark name alone when a benchmark
        // starts; benchfmt ignores that line, and so do we.
        if (rest.len == 0 and name.len == name_field_len) return null;
        if (name.len == 0) return self.syntaxError(.missing_name);

        const iters_field = splitField(&rest);
        if (iters_field.len == 0) return self.syntaxError(.missing_iterations);
        const iters = std.fmt.parseInt(u64, iters_field, 10) catch
            return self.syntaxError(.invalid_iterations);

        self.values.clearRetainingCapacity();
        while (true) {
            const value_field = splitField(&rest);
            if (value_field.len == 0) {
                if (self.values.items.len > 0) break;
                return self.syntaxError(.missing_measurements);
            }
            const value = std.fmt.parseFloat(f64, value_field) catch
                return self.syntaxError(.invalid_measurement);
            const unit_field = splitField(&rest);
            if (unit_field.len == 0) return self.syntaxError(.missing_unit);
            try self.values.append(self.allocator, .{ .value = value, .unit = unit_field });
        }

        return .{ .result = .{
            .name = .{ .full = name },
            .iters = iters,
            .values = self.values.items,
        } };
    }

    fn syntaxError(self: *Reader, kind: SyntaxError.Kind) Record {
        return .{ .syntax_error = .{ .line = self.line, .kind = kind } };
    }
};

pub fn isValidConfigKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!std.ascii.isLower(key[0])) return false;
    for (key) |c| {
        if (std.ascii.isUpper(c) or std.ascii.isWhitespace(c) or c == ':') return false;
    }
    return true;
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

fn isValidUnit(unit: []const u8) bool {
    if (unit.len == 0) return false;
    for (unit) |c| {
        if (std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

fn commentText(line: []const u8) []const u8 {
    const text = line[1..];
    if (text.len > 0 and text[0] == ' ') return text[1..];
    return text;
}

/// Parse a configuration line, or return null when the line is not one.
/// Malformed lines are ignored, as the format specifies for other lines.
fn parseConfigLine(line: []const u8) ?Config {
    if (line.len == 0 or !std.ascii.isLower(line[0])) return null;

    const colon = mem.findScalar(u8, line, ':') orelse return null;
    const key = line[0..colon];
    if (!isValidConfigKey(key)) return null;

    var value = line[colon + 1 ..];
    if (value.len == 0) return .{ .key = key, .value = "" };
    if (value[0] != ' ' and value[0] != '\t') return null;
    while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) value = value[1..];
    return .{ .key = key, .value = value };
}

/// Consume one whitespace-separated field from the front of `text`.
fn splitField(text: *[]const u8) []const u8 {
    const input = text.*;
    var end: usize = 0;
    while (end < input.len and !std.ascii.isWhitespace(input[end])) end += 1;
    const field = input[0..end];

    var start = end;
    while (start < input.len and std.ascii.isWhitespace(input[start])) start += 1;
    text.* = input[start..];
    return field;
}

fn writeValue(writer: *Io.Writer, value: f64, unit: []const u8) !void {
    // Match the Go testing package: allocation counts are integers.
    if (mem.eql(u8, unit, "B/op") or mem.eql(u8, unit, "allocs/op")) {
        return writer.print("{d:>8.0} {s}", .{ value, unit });
    }
    if (mem.eql(u8, unit, "MB/s")) {
        return writer.print("{d:>7.2} {s}", .{ value, unit });
    }
    return prettyValue(writer, value, unit);
}

fn prettyValue(writer: *Io.Writer, x: f64, unit: []const u8) !void {
    const y = @abs(x);
    if (y == 0 or y >= 999.95) return writer.print("{d:>10.0} {s}", .{ x, unit });
    if (y >= 99.995) return writer.print("{d:>12.1} {s}", .{ x, unit });
    if (y >= 9.9995) return writer.print("{d:>13.2} {s}", .{ x, unit });
    if (y >= 0.99995) return writer.print("{d:>14.3} {s}", .{ x, unit });
    if (y >= 0.099995) return writer.print("{d:>15.4} {s}", .{ x, unit });
    if (y >= 0.0099995) return writer.print("{d:>16.5} {s}", .{ x, unit });
    if (y >= 0.00099995) return writer.print("{d:>17.6} {s}", .{ x, unit });
    return writer.print("{d:>18.7} {s}", .{ x, unit });
}

const spec_example =
    \\commit: 7cd9055
    \\commit-time: 2016-02-11T13:25:45-0500
    \\goos: darwin
    \\goarch: amd64
    \\cpu: Intel(R) Core(TM) i7-4980HQ CPU @ 2.80GHz
    \\cpu-count: 8
    \\
    \\BenchmarkDecode/text=digits/level=speed/size=1e4-8 100 154125 ns/op 64.88 MB/s
    \\BenchmarkDecode/text=digits/level=speed/size=1e5-8 10 1367632 ns/op 73.12 MB/s
    \\BenchmarkEncode 1 13879794 ns/op
    \\# a comment
    \\PASS
;

test "reader parses the spec example into config and results" {
    var reader: Reader = .init(testing.allocator, spec_example);
    defer reader.deinit();

    const expected_config = [_]Config{
        .{ .key = "commit", .value = "7cd9055" },
        .{ .key = "commit-time", .value = "2016-02-11T13:25:45-0500" },
        .{ .key = "goos", .value = "darwin" },
        .{ .key = "goarch", .value = "amd64" },
        .{ .key = "cpu", .value = "Intel(R) Core(TM) i7-4980HQ CPU @ 2.80GHz" },
        .{ .key = "cpu-count", .value = "8" },
    };
    for (expected_config) |expected| {
        const record = (try reader.next()).?;
        try testing.expectEqual(Record.config, std.meta.activeTag(record));
        try testing.expectEqualStrings(expected.key, record.config.key);
        try testing.expectEqualStrings(expected.value, record.config.value);
    }
    try testing.expectEqualStrings("darwin", reader.config.get("goos").?);
    try testing.expectEqual(@as(usize, 6), reader.config.count());

    const first = (try reader.next()).?;
    try testing.expectEqual(Record.result, std.meta.activeTag(first));
    try testing.expectEqualStrings(
        "Decode/text=digits/level=speed/size=1e4-8",
        first.result.name.full,
    );
    try testing.expectEqualStrings("Decode", first.result.name.base());
    try testing.expectEqual(@as(u64, 100), first.result.iters);
    try testing.expectEqual(@as(usize, 2), first.result.values.len);
    try testing.expectEqualStrings("ns/op", first.result.values[0].unit);
    try testing.expectEqual(@as(f64, 154125), first.result.values[0].value);
    try testing.expectEqualStrings("MB/s", first.result.values[1].unit);
    try testing.expectEqual(@as(f64, 64.88), first.result.values[1].value);

    const second = (try reader.next()).?;
    try testing.expectEqual(Record.result, std.meta.activeTag(second));
    try testing.expectEqual(@as(u64, 10), second.result.iters);
    try testing.expectEqual(@as(usize, 2), second.result.values.len);

    const third = (try reader.next()).?;
    try testing.expectEqual(Record.result, std.meta.activeTag(third));
    try testing.expectEqualStrings("Encode", third.result.name.full);
    try testing.expectEqual(@as(u64, 1), third.result.iters);
    try testing.expectEqual(@as(usize, 1), third.result.values.len);

    const comment = (try reader.next()).?;
    try testing.expectEqual(Record.comment, std.meta.activeTag(comment));
    try testing.expectEqualStrings("a comment", comment.comment);

    // `PASS` is neither a config line nor a result; the format ignores it.
    try testing.expectEqual(@as(?Record, null), try reader.next());
}

test "name parts follow benchfmt base and gomaxprocs semantics" {
    const decode: Name = .{ .full = "Decode/text=digits/level=speed/size=1e4-8" };
    try testing.expectEqualStrings("Decode", decode.base());
    const split = decode.splitGomaxprocs();
    try testing.expectEqualStrings("Decode/text=digits/level=speed/size=1e4", split.prefix);
    try testing.expectEqualStrings("-8", split.gomaxprocs.?);

    var parts = try decode.parts(testing.allocator);
    defer parts.deinit();
    const expected = [_][]const u8{
        "Decode",
        "/text=digits",
        "/level=speed",
        "/size=1e4",
        "-8",
    };
    try testing.expectEqual(@as(usize, expected.len), parts.items.len);
    for (expected, parts.items) |want, got| try testing.expectEqualStrings(want, got);

    const plain: Name = .{ .full = "Sort" };
    try testing.expectEqualStrings("Sort", plain.base());
    var plain_parts = try plain.parts(testing.allocator);
    defer plain_parts.deinit();
    try testing.expectEqual(@as(usize, 1), plain_parts.items.len);
    try testing.expectEqualStrings("Sort", plain_parts.items[0]);

    const positional: Name = .{ .full = "Encode/1e4-8" };
    try testing.expectEqualStrings("Encode", positional.base());
    var positional_parts = try positional.parts(testing.allocator);
    defer positional_parts.deinit();
    const positional_expected = [_][]const u8{ "Encode", "/1e4", "-8" };
    try testing.expectEqual(@as(usize, positional_expected.len), positional_parts.items.len);
    for (positional_expected, positional_parts.items) |want, got| {
        try testing.expectEqualStrings(want, got);
    }

    // A dash that is not a trailing gomaxprocs suffix stays in the base.
    const dashed: Name = .{ .full = "Timer/now-pair" };
    try testing.expectEqualStrings("Timer", dashed.base());
    try testing.expectEqual(@as(?[]const u8, null), dashed.splitGomaxprocs().gomaxprocs);
}

test "reader reports syntax errors and keeps scanning" {
    const input =
        \\BenchmarkMissingIters
        \\BenchmarkBadIters abc
        \\BenchmarkMissingMeasurements 100
        \\BenchmarkBadMeasurement 100 abc
        \\BenchmarkMissingUnit 100 1
        \\BenchmarkMissingUnit2 100 1 ns/op 2
        \\BenchmarkOk 100 1 ns/op 2 B/op
    ;

    var reader: Reader = .init(testing.allocator, input);
    defer reader.deinit();

    const expected_kinds = [_]SyntaxError.Kind{
        .invalid_iterations,
        .missing_measurements,
        .invalid_measurement,
        .missing_unit,
        .missing_unit,
    };
    for (expected_kinds, 0..) |kind, i| {
        const record = (try reader.next()).?;
        try testing.expectEqual(Record.syntax_error, std.meta.activeTag(record));
        try testing.expectEqual(kind, record.syntax_error.kind);
        try testing.expectEqual(i + 2, record.syntax_error.line);
        try testing.expect(record.syntax_error.message().len > 0);
    }

    const last = (try reader.next()).?;
    try testing.expectEqual(Record.result, std.meta.activeTag(last));
    try testing.expectEqualStrings("Ok", last.result.name.full);
    try testing.expectEqual(@as(usize, 2), last.result.values.len);
    try testing.expectEqual(@as(?Record, null), try reader.next());
}

test "reader deletes a config key with an empty value" {
    const input =
        \\rev: one
        \\rev:
        \\# still scanning
    ;
    var reader: Reader = .init(testing.allocator, input);
    defer reader.deinit();

    const first = (try reader.next()).?;
    try testing.expectEqualStrings("one", first.config.value);
    try testing.expectEqualStrings("one", reader.config.get("rev").?);

    const second = (try reader.next()).?;
    try testing.expectEqualStrings("", second.config.value);
    try testing.expectEqual(@as(?[]const u8, null), reader.config.get("rev"));

    const third = (try reader.next()).?;
    try testing.expectEqualStrings("still scanning", third.comment);
}

test "writer emits config, result, and comment lines" {
    var buffer: [1024]u8 = undefined;
    var io_writer: Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&io_writer);

    try writer.writeConfig("goos", "darwin");
    try writer.writeConfig("cpu", "test cpu");
    try writer.writeConfig("empty", "");
    try writer.writeResult("Sort/Quick", 1200, &.{
        .{ .value = 99.18, .unit = "ns/op" },
        .{ .value = 16, .unit = "B/op" },
        .{ .value = 1, .unit = "allocs/op" },
    });
    try writer.writeComment("FAIL: Sort/Broken");

    try testing.expectEqualStrings(
        "goos: darwin\n" ++
            "cpu: test cpu\n" ++
            "empty:\n" ++
            "BenchmarkSort/Quick\t    1200\t        99.18 ns/op\t      16 B/op" ++
            "\t       1 allocs/op\n" ++
            "# FAIL: Sort/Broken\n",
        io_writer.buffered(),
    );
}

test "writer rejects lines that would break the format" {
    var buffer: [256]u8 = undefined;
    var io_writer: Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&io_writer);

    try testing.expectError(Error.InvalidConfigKey, writer.writeConfig("CPU", "x"));
    try testing.expectError(Error.InvalidConfigKey, writer.writeConfig("", "x"));
    try testing.expectError(Error.InvalidConfigKey, writer.writeConfig("has space", "x"));
    try testing.expectError(Error.InvalidConfigValue, writer.writeConfig("key", "two\nlines"));
    try testing.expectError(Error.InvalidCommentText, writer.writeComment("two\nlines"));
    try testing.expectError(Error.InvalidName, writer.writeResult("bad name", 1, &.{
        .{ .value = 1, .unit = "ns/op" },
    }));
    try testing.expectError(Error.InvalidUnit, writer.writeResult("Name", 1, &.{
        .{ .value = 1, .unit = "ns op" },
    }));
    try testing.expectError(Error.MissingValues, writer.writeResult("Name", 1, &.{}));
}

test "writer output reads back as the same records" {
    var buffer: [4096]u8 = undefined;
    var io_writer: Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&io_writer);

    try writer.writeConfig("rev", "abc123");
    try writer.writeConfig("shape", "smoke");
    try writer.writeResult("Sort/Quick", 1000, &.{
        .{ .value = 120.5, .unit = "ns/op" },
        .{ .value = 64.5, .unit = "MB/s" },
        .{ .value = 16, .unit = "B/op" },
        .{ .value = 1, .unit = "allocs/op" },
        .{ .value = 0.125, .unit = "widgets/op" },
    });
    try writer.writeResult("Hash/length=16", 250, &.{
        .{ .value = 3.25, .unit = "ns/op" },
    });
    try writer.writeComment("FAIL: Broken");
    try writer.writeComment("SKIP: Slow");
    try writer.writeResult("Last", 5, &.{.{ .value = 1, .unit = "ns/op" }});

    var reader: Reader = .init(testing.allocator, io_writer.buffered());
    defer reader.deinit();

    const first = (try reader.next()).?;
    try testing.expectEqualStrings("rev", first.config.key);
    try testing.expectEqualStrings("abc123", first.config.value);

    const second = (try reader.next()).?;
    try testing.expectEqualStrings("shape", second.config.key);
    try testing.expectEqualStrings("smoke", second.config.value);

    const quick = (try reader.next()).?;
    try testing.expectEqualStrings("Sort/Quick", quick.result.name.full);
    try testing.expectEqual(@as(u64, 1000), quick.result.iters);
    const expected_quick = [_]Value{
        .{ .value = 120.5, .unit = "ns/op" },
        .{ .value = 64.5, .unit = "MB/s" },
        .{ .value = 16, .unit = "B/op" },
        .{ .value = 1, .unit = "allocs/op" },
        .{ .value = 0.125, .unit = "widgets/op" },
    };
    try testing.expectEqual(@as(usize, expected_quick.len), quick.result.values.len);
    for (expected_quick, quick.result.values) |want, got| {
        try testing.expectEqual(want.value, got.value);
        try testing.expectEqualStrings(want.unit, got.unit);
    }

    const hash = (try reader.next()).?;
    try testing.expectEqualStrings("Hash/length=16", hash.result.name.full);
    try testing.expectEqual(@as(u64, 250), hash.result.iters);
    try testing.expectEqual(@as(f64, 3.25), hash.result.values[0].value);

    const fail = (try reader.next()).?;
    try testing.expectEqualStrings("FAIL: Broken", fail.comment);

    const skip = (try reader.next()).?;
    try testing.expectEqualStrings("SKIP: Slow", skip.comment);

    const last = (try reader.next()).?;
    try testing.expectEqualStrings("Last", last.result.name.full);
    try testing.expectEqualStrings("abc123", reader.config.get("rev").?);
    try testing.expectEqual(@as(?Record, null), try reader.next());
}
