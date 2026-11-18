//! A bench suite that needs libc, for the build check that `--disasm` resolves
//! a symbol in a dynamically linked executable. Benchmarks that call C code are
//! the reason a consumer sets `link_libc`, and they are the case that failed:
//! see issue #5.

const std = @import("std");
const testingx = @import("testingx");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.add("Libc/getpid", benchmarkGetpid);
}

fn benchmarkGetpid(b: *testingx.B) !void {
    var sink: std.c.pid_t = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        sink +%= std.c.getpid();
    }
}
