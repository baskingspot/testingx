//! Benchmarks for the benchmark filter grammar.

const testingx = @import("testingx");

const names = [_][]const u8{
    "Sort/Quick",
    "Sort/Std",
    "Hash/Ints",
    "Hash/Strings",
    "Parser/Baseline",
    "Parser/SIMD",
};

pub fn benchmarkPlainContains(b: *testingx.B) !void {
    var hits: usize = 0;
    defer b.keepAlive(hits);
    while (try b.loop()) {
        for (names) |name| {
            if (testingx.filter.matches("Sort", name)) hits +|= 1;
        }
    }
}

pub fn benchmarkGlobAnchored(b: *testingx.B) !void {
    var hits: usize = 0;
    defer b.keepAlive(hits);
    while (try b.loop()) {
        for (names) |name| {
            if (testingx.filter.matches("^Parser/.*d$", name)) hits +|= 1;
        }
    }
}

pub fn benchmarkCommaList(b: *testingx.B) !void {
    var hits: usize = 0;
    defer b.keepAlive(hits);
    while (try b.loop()) {
        for (names) |name| {
            if (testingx.filter.matchesAny("Sort/Quick, ^Hash", name)) hits +|= 1;
        }
    }
}
