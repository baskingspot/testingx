//! Fixture for the benchmark panic handler: panics exit 1 with a stack trace
//! instead of raising SIGABRT.

const testingx = @import("testingx");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.add("Panic", benchmarkPanic);
    try b.add("Sub", benchmarkSub);
}

fn benchmarkPanic(_: *testingx.B) !void {
    @panic("intentional panic");
}

fn benchmarkSub(b: *testingx.B) !void {
    _ = try b.run("Child", benchmarkSubChild);
}

fn benchmarkSubChild(_: *testingx.B) !void {
    @panic("sub panic");
}
