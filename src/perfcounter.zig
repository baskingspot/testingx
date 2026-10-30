//! Per-benchmark hardware counters, read straight from the kernel.
//!
//! Each metric is its own `perf_event_open` counter, enabled for the timed
//! section of one benchmark. There is no sampler and no perf.data: the counts
//! land in the result line as extra units, so benchstat compares them like any
//! other column.
//!
//! The counters are independent rather than one group. A core has a handful
//! of general-purpose counter slots, and a group that cannot be scheduled
//! reads back zeros; independent events multiplex instead, and the kernel
//! reports how much of the window each one ran. A metric that never ran is
//! dropped from the output instead of printing a false zero.
//!
//! Linux only. Elsewhere `open` fails and the caller reports timings alone.
//! The counters are user-space only (`exclude_kernel`), which is what a
//! benchmark measures and what `perf_event_paranoid = 2` still permits.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const is_linux = builtin.os.tag == .linux;

/// Linux file descriptors are `i32`; the alias is spelled out here because
/// `std.posix.fd_t` is a handle type on Windows, where nothing here ever
/// touches a descriptor.
const Fd = if (is_linux) std.posix.fd_t else i32;

/// `PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING`, so a
/// read says whether the counter was multiplexed.
const format_time = 0b11;

/// A group member, in read order. `cycles` leads: instructions per cycle is
/// the derived number worth having.
pub const Metric = enum {
    cycles,
    instructions,
    branches,
    branch_misses,
    cache_references,
    cache_misses,

    pub fn unit(self: Metric) []const u8 {
        return switch (self) {
            .cycles => "cycles/op",
            .instructions => "instructions/op",
            .branches => "branches/op",
            .branch_misses => "branch-misses/op",
            .cache_references => "cache-references/op",
            .cache_misses => "cache-misses/op",
        };
    }

    fn hw(self: Metric) linux.PERF.COUNT.HW {
        return switch (self) {
            .cycles => .CPU_CYCLES,
            .instructions => .INSTRUCTIONS,
            .branches => .BRANCH_INSTRUCTIONS,
            .branch_misses => .BRANCH_MISSES,
            .cache_references => .CACHE_REFERENCES,
            .cache_misses => .CACHE_MISSES,
        };
    }
};

pub const metric_count = @typeInfo(Metric).@"enum".fields.len;

const Read = extern struct {
    value: u64,
    time_enabled: u64,
    time_running: u64,
};

pub const Counters = struct {
    fds: [metric_count]Fd,
    /// True once the kernel has run this counter for at least one window.
    ran: [metric_count]bool,
    /// Counts accumulated by `accumulate`, scaled to the full window.
    totals: [metric_count]u64,

    /// No counter open and nothing counted: every descriptor is -1.
    pub const empty: Counters = .{
        .fds = @splat(-1),
        .ran = @splat(false),
        .totals = @splat(0),
    };

    /// Open one counter per metric. A metric the PMU refuses is dropped, not
    /// fatal: cycles and instructions are the floor.
    pub fn open(self: *Counters) !void {
        if (comptime is_linux) {
            if (self.isOpen()) return;
            errdefer self.close();

            for (std.enums.values(Metric)) |metric| {
                var attr: linux.perf_event_attr = .{
                    .type = .HARDWARE,
                    .config = @intFromEnum(metric.hw()),
                    .read_format = format_time,
                    .flags = .{ .disabled = true, .exclude_kernel = true, .exclude_hv = true },
                };
                self.fds[@intFromEnum(metric)] = std.posix.perf_event_open(
                    &attr,
                    0,
                    -1,
                    -1,
                    linux.PERF.FLAG.FD_CLOEXEC,
                ) catch continue;
            }
            if (!self.isOpen()) return error.NoCounters;
        } else {
            return error.UnsupportedPlatform;
        }
    }

    pub fn close(self: *Counters) void {
        if (comptime is_linux) {
            for (&self.fds) |*fd| {
                if (fd.* >= 0) _ = linux.close(fd.*);
            }
        }
        self.fds = @splat(-1);
        self.ran = @splat(false);
    }

    pub fn enable(self: *Counters) void {
        self.ioctlAll(linux.PERF.EVENT_IOC.ENABLE);
    }

    pub fn disable(self: *Counters) void {
        self.ioctlAll(linux.PERF.EVENT_IOC.DISABLE);
    }

    /// Zero the counts, keeping the descriptors open.
    pub fn reset(self: *Counters) void {
        self.totals = @splat(0);
        self.ran = @splat(false);
        self.ioctlAll(linux.PERF.EVENT_IOC.RESET);
    }

    /// Read every counter and add it to `totals`. Call after `disable`.
    pub fn accumulate(self: *Counters) void {
        if (comptime !is_linux) return;

        for (self.fds, 0..) |fd, index| {
            if (fd < 0) continue;

            var read: Read = undefined;
            const n = std.posix.read(fd, std.mem.asBytes(&read)) catch continue;
            if (n < @sizeOf(Read)) continue;
            if (read.time_running == 0) continue;

            self.ran[index] = true;
            // Multiplexed: the counter ran for part of the window.
            const scaled = if (read.time_running < read.time_enabled)
                read.value * read.time_enabled / read.time_running
            else
                read.value;
            self.totals[index] +|= scaled;
        }
    }

    /// Whether the kernel actually ran this counter; zero would be a lie
    /// otherwise.
    pub fn available(self: *const Counters, metric: Metric) bool {
        return self.ran[@intFromEnum(metric)];
    }

    pub fn count(self: *const Counters, metric: Metric) u64 {
        return self.totals[@intFromEnum(metric)];
    }

    pub fn isOpen(self: *const Counters) bool {
        for (self.fds) |fd| if (fd >= 0) return true;
        return false;
    }

    fn ioctlAll(self: *Counters, request: u32) void {
        if (comptime is_linux) {
            for (self.fds) |fd| {
                if (fd >= 0) _ = linux.ioctl(fd, request, 0);
            }
        }
    }
};

test "units are benchfmt units" {
    for (std.enums.values(Metric)) |metric| {
        const unit = metric.unit();
        try std.testing.expect(unit.len > 0);
        for (unit) |c| try std.testing.expect(!std.ascii.isWhitespace(c));
        try std.testing.expect(std.mem.endsWith(u8, unit, "/op"));
    }
}

test "a timed window reads cycles" {
    if (comptime !is_linux) return error.SkipZigTest;

    var counters: Counters = .empty;
    // No counter opened: no PMU, or perf_event_paranoid says no.
    counters.open() catch return error.SkipZigTest;
    defer counters.close();

    counters.reset();
    counters.enable();
    var sum: u64 = 0;
    for (0..100_000) |i| sum +%= i;
    std.mem.doNotOptimizeAway(sum);
    counters.disable();
    counters.accumulate();

    try std.testing.expect(counters.available(.cycles));
    try std.testing.expect(counters.count(.cycles) > 0);

    // A second window with no work adds nothing to the first.
    const first = counters.count(.cycles);
    counters.reset();
    counters.enable();
    counters.disable();
    counters.accumulate();
    try std.testing.expect(counters.count(.cycles) < first);
}
