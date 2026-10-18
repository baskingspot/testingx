# Migrate a repo from zig-benchmark to testingx

One-off working reference, 2026-10-18. Not public. Hand this file to the agent
that migrates one repo. The repos that use zig-benchmark are: ztls, z53,
compress, stdx, kafka-zig, kafka-zig-snappy. Exosphere has nothing to migrate.

## What stays the same

- The benchmark body API: `while (try b.loop())`, `b.n`, `b.run("Name", fn)`
  for sub-benchmarks, `b.setBytes`, `b.reportMetric`, `b.reportAllocs`,
  `b.allocator`, `b.keepAlive`, `b.blackBox`, `b.startTimer/stopTimer/resetTimer`.
- The flags: `--benchtime D` or `-t Nx`, `--count/-c`, `--filter/-f`,
  `--benchmem/-m`, `--parallelism/-p`, `--no-env`, `--help`. Justfile recipes
  that pass these keep working.
- The result rows: name, iterations, `ns/op`, `MB/s`, custom metrics. The
  printed rows keep the `Benchmark` prefix, so old captures still line up with
  new ones.

## What changes

### 1. The dependency

In `build.zig.zon`, replace the zig-benchmark entry with testingx. Until
testingx is published, use a path:

```zig
.testingx = .{ .path = "../testingx" },
```

Keep `.lazy = true` where it exists (stdx, compress, z53): only the `bench`
step imports it, so test and lint builds never fetch it.

### 2. The import name

`benchmark` becomes `testingx`. Always the full name, never `tx`.

```zig
const testingx = @import("testingx");
fn benchmarkSum(b: *testingx.B) !void { ... }
```

Two free functions moved onto B: `benchmark.blackBox(x)` becomes
`b.blackBox(x)`.

### 3. The build wiring

`addRunTest` (or a hand-rolled copy of it) becomes `testingx.addBench`. It
builds the benchmark executable as ReleaseFast by default, so the
`-Doptimize=ReleaseFast` reminders disappear from justfiles and docstrings.

```zig
const testingx = @import("testingx"); // at the top of build.zig

// where addRunTest used to be, inside the lazy-import guard:
const run_bench = testingx.addBench(b, .{
    .module = testingx_module, // dep.module("testingx") or your own module
    .root_source_file = b.path("src/bench.zig"), // the suite root
});
if (b.args) |args| run_bench.addArgs(args);
b.step("bench", "Run benchmarks").dependOn(&run_bench.step);
```

Notes:

- `addBench` takes `root_source_file`, not `root_module`. It builds the suite
  module itself and injects the `testingx` import.
- For a `bench-bin` step (install the executable for perf or objdump, the ztls
  pattern), use `testingx.addBenchExe(b, .{...})` and install the returned
  compile step.
- z53 builds ReleaseSafe on purpose for its reference settings: pass
  `.optimize = .ReleaseSafe`. The default is ReleaseFast.

### 4. The suite entrypoint

The `benchmark_root` injection and the recursive comptime discovery are gone.
The suite root is now an ordinary file with a `benchmarkMain` function that
registers what runs. One line per module, zero per function:

```zig
// src/bench.zig, formerly a barrel of imports, now registers them.
const std = @import("std");
const testingx = @import("testingx");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(@import("swiss/bench.zig"));
    try b.addMod(@import("bloom/bench.zig"));
}
```

Rules that differ from zig-benchmark:

- `addMod` looks at top-level declarations only. It never descends into
  nested structs. A barrel of `pub const x = @import(...)` no longer works;
  each module gets one `addMod` line.
- Registration drops the name prefix: `benchmarkSwissSmall` registers as
  `SwissSmall`. The printed rows still start with `Benchmark`; that is the
  text format, not the name.
- Explicit `Spec` lists (the z53 pattern) become `b.add("Name", func)` calls
  in `benchmarkMain`. A comptime loop over variants stays a comptime loop:
  `inline for (capacities) |cap| try b.add(comptime std.fmt.comptimePrint("Cache/capacity={d}", .{cap}), Runner(cap).run);`
- `b.run` inside `benchmarkMain` is an error now. Registration is `add` and
  `addMod`. `b.run` belongs inside a running benchmark, unchanged.

### 5. I/O

`b.timer.io` is gone. The field is `b.io`, and each benchmark gets a fresh one.
Replace `bench.timer.io` and `bb.timer.io` reads (corpus files, clocks) with
`b.io`.

### 6. The header

zig-benchmark printed `zig_os`, `zig_arch`, `zig_abi`, `zig_cpu`, `zig_mode`
lines. testingx prints:

```
target: aarch64-linux-gnu
cpu: neoverse_v3
mode: ReleaseFast
```

Update any capture or normalization script that keyed on the `zig_*` names
(ztls `bench-analyze.sh`).

## Verification

Run these in order. Each one must succeed.

1. `zig build test --summary all`: unit tests still pass.
2. `zig build bench -- --benchtime=8x --count=1 --no-env`, the smoke run:
   every benchmark executes, none fail. Adopt this as a `bench-smoke` recipe
   while here.
3. `zig build bench -- --benchtime=250ms --filter=<one name>`: one real
   measurement row looks right: name, iterations, `ns/op`, custom metrics.
4. `ziglint` and the repo's lint recipe.
5. Remove the old dependency from `build.zig.zon`, delete the old wiring, and
   fix stale docstrings (kafka-zig's Justfile points at the wrong step; see
   the per-repo notes).

## Gotchas

- kafka-zig and kafka-zig-snappy pin the Zig 0.15-era revision. Upgrade the
  toolchain first, then migrate. Their hand-rolled `src/bench.zig` binary
  (mock-broker throughput) is not zig-benchmark; leave it alone. Only the
  `snappy-bench` lane migrates.
- compress's fleet JSONL harness does not use zig-benchmark. Migrate only the
  six `src/<codec>/bench.zig` roots. The Python harness and `bench-results/`
  stay as they are.
- stdx's manual thread benchmarks are fine. Nobody uses `runParallel`; the
  slot_ring benchmarks keep their hand-spawned threads.
- Do not run full benchmarks in CI. Numbers from CI machines are noise. The
  smoke run (step 2) is the only benchmark-shaped thing that belongs in a
  gate.
- testingx is not published yet. The path dependency works only for repos
  that can reach it on disk. Do not point zon files at a git URL that does
  not exist.

## Per-repo notes

- ztls: three bench roots (`src/bench.zig` barrel, `bench/evp.zig`,
  `bench/bio.zig`) and a hand-rolled copy of the generated main that forces
  ReleaseFast. All of that collapses into three `addBench` calls. `bench-bin`
  and the `-bin` pairs become `addBenchExe`. Update `scripts/bench-analyze.sh`
  for the new header. The Rust rustls harness stays; it prints our row format
  on purpose.
- z53: the explicit Spec lists in `tests/benchmark.zig` and the capacity
  harness in `tests/benchmark_cache.zig` become `b.add` registration. Keep
  `.optimize = .ReleaseSafe`. Keep the mode-arg protocol (smoke, baseline,
  wire, route, and the rest); `benchmarkMain` can parse its own first argument
  the same way. `emit_environment = false` becomes `--no-env`.
- compress: six codec roots on one `bench` step. Either six `addBench` calls
  on one step, or one suite root that `addMod`s all six. Keep the lazy-import
  guard.
- stdx: the barrel becomes `addMod` lines. The module-prefixed names
  (`BenchmarkSwissSmall`) no longer need the prefix because the module carries
  the context, but keeping the old names with `b.add` is the safer choice for
  comparing old and new rows.
- kafka-zig and kafka-zig-snappy: toolchain bump first, then migrate the
  snappy lane. Fix the stale docstring while there.
