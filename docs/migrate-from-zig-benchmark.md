# Migrate a repo from zig-benchmark to testingx

One-off working reference, 2026-10-18. Not public. Hand this file to the agent
that migrates one repo. The repos that use zig-benchmark are: ztls, z53,
compress, stdx, kafka-zig, kafka-zig-snappy. Exosphere has nothing to migrate.
The runner half below also covers ztest consumers (ztls, exosphere, and any
repo with a custom `--test_runner`).

## The test runner (ztest consumers)

`.test_runner` wiring is unchanged: point it at
`testingx.path("src/runner.zig")` with `.mode = .simple`, and keep
`run_tests.has_side_effects = true`. The changes are the flags and the names:

- Environment variables become flags, passed after `zig build test --`:
  `ZTEST_FILTER` becomes `--filter=P`, `ZTEST_FAIL_FAST` becomes `--fail-fast`,
  `ZTEST_PLAIN` becomes `--plain`, and `ZTEST_VERBOSE` becomes
  `--format=verbose` (`--format=testname` gives one line per test). The old
  `--verbose` and `--no-verbose` flags are gone. `--seed=N` stays.
- The default output is quiet without a TTY and dots on one. Quiet prints
  nothing for a passing test, so CI logs show failures and the summary. The
  four formats are `quiet`, `dots`, `testname`, and `verbose`; `--plain`
  turns colors off and no longer selects a format.
- `--timeout=D` stops a stuck run after D (`500ms`, `30s`, `10m`; default
  `10m`; `off` or `0` disables). The message names the test that was running.
- `--count=N` runs the whole suite N times and adds up the summary totals.
- `--rerun-fails=N` retries failed tests up to N total attempts. A test that
  passes on a retry is flaky: it does not fail the exit code, and the summary
  gains `, F flaky` plus a `testingx: flaky:` line naming it. Reruns happen
  inside each `--count` iteration.
- `--shuffle=on|off|N` shuffles test order. `on` uses the run seed, `N` is a
  fixed seed, and `off` keeps declaration order. The seed in the summary
  reproduces the order for `on`.
- `--slowest=N` prints the N slowest tests after the summary.
- Watch mode is not a runner feature. `zig build test --watch` already exists
  in Zig itself.
- `--filter` now speaks the benchmark grammar, not substring: plain text
  still means contains, `^` and `$` anchor, `*` matches any bytes, and commas
  separate alternatives (`--filter=leak,fuzz`). An exact name is
  `^<fully-qualified name>$`. Filters match the fully-qualified name
  (module path plus test name).
- A filter that matches nothing now fails the run with exit 1 ("no tests
  matched filter"). ztest exited 0, which is why z53 pins
  `ztest: Running 3 tests...` with a grep in its Nix check; that workaround
  can go. A test binary with no tests at all also fails now.
- The summary and status lines start with `testingx:` instead of `ztest:`.
  Scripts that grep the summary line must update the prefix
  (`grep -Eq '^testingx: [0-9]+ passed, 0 failed,'`).
- `ZTEST_EXPECT_SEED` (used by ztest's fixture check) becomes
  `TESTINGX_EXPECT_SEED`.
- Pass the build's seed through so reproduction works:
  `run_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}))`.
- The summary line keeps its shape:
  `testingx: N passed, M failed, K skipped (of T total) in Xms (seed: 0x...)`.
  Flaky runs add `, F flaky` and a `testingx: flaky:` line. The status line
  (`ALL TESTS PASSED` or `TESTS FAILED`) and the exit codes are unchanged.

## What stays the same

- The benchmark body API: `while (try b.loop())`, `b.n`, `b.run("Name", fn)`
  for sub-benchmarks, `b.setBytes`, `b.reportMetric`, `b.reportAllocs`,
  `b.allocator`, `b.keepAlive`, `b.blackBox`, `b.startTimer/stopTimer/resetTimer`.
- The flags: `--benchtime D` or `-t Nx`, `--count/-c`, `--filter/-f`,
  `--benchmem/-m`, `--parallelism/-p`, `--no-env`, `--help`. Justfile recipes
  that pass these keep working.

  Filters match the printed name and the registered name, so
  `^BenchmarkSwissSmall$` and `^SwissSmall$` both select the same benchmark.
  A filter that matches nothing prints only the header and exits 0; the
  benchmark path does not have the runner's no-match failure.

- The result rows: name, iterations, `ns/op`, `MB/s`, custom metrics. The
  printed rows keep the `Benchmark` prefix, so old captures still line up with
  new ones.

## What changes

### 1. The dependency

In `build.zig.zon`, replace the zig-benchmark entry with testingx. For a
local trial, use a path:

```zig
.testingx = .{ .path = "../testingx" },
```

A path works only on the machine that has the checkout; see the Gotchas for
how it fails. To land a migration, pin a git URL at a commit that has
`BenchOptions.imports` (step 3).

`.lazy = true` is not enough on its own. It stops a fetch until a build
script asks for the package, but a consumer's build runs your build.zig,
and that script asks on every evaluation. Then the consumer fetches the
dependency too. Pair lazy with a guard that stops after the exported
modules when the script runs as a dependency:

```zig
// ... declare and install the public modules, then:
if (b.pkg_hash.len != 0) return;
```

ztls does this. stdx, compress, and z53 do not, so a consumer's build
fetches their benchmark and test packages today. With the guard, the same
consumer build succeeds even when the dependency is unreachable.

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
    // The suite files `@import` the package under test; the suite module is
    // built for them, so its imports are not inherited from anywhere.
    .imports = &.{.{ .name = "mylib", .module = lib_module }},
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

const swiss = @import("swiss/bench.zig");
const bloom = @import("bloom/bench.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(swiss);
    try b.addMod(bloom);
}
```

Top-level consts, not inline `@import`: ziglint has a rule against inline
`@import` (Z028, off by default), and the const form reads better
regardless.

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
- The testingx repo is public, so a pinned git URL is available now; pin
  only a commit that has `BenchOptions.imports`. A path dependency is
  local-only in a harsher way than it looks: with `../testingx` missing,
  `lazyImport` is a build-script compile error (`dependency 'testingx' does
not have a build.zig`), so `zig build test` dies before any step runs.
  `.lazy = true` does not soften that.

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
- stdx: the barrel becomes five `addMod` lines. The printed names do not
  change: `benchmarkSwissSmall` registers as `SwissSmall` and prints as
  `BenchmarkSwissSmall`, so old captures line up without a `b.add` list.
- kafka-zig and kafka-zig-snappy: toolchain bump first, then migrate the
  snappy lane. Fix the stale docstring while there.
