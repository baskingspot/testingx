+++
title = "testingx"
+++

A test runner that replaces the built-in one, benchmarks that sit beside your tests, and fixtures that stay text in the repo and become bytes at compile time.

The test runner writes plain text to stderr. A terminal gets colored dots; a pipe or a CI log gets one line per failure and nothing for passes, which is what `go test` prints. The benchmark side follows Go's `testing.B`: a benchmark is a function that loops, and the output is the Go benchmark format, so `benchstat` compares two runs without any glue. The fixture side reads `@embedFile` bytes: base64 and hex blobs decode at comptime, and a txtar archive becomes a name-indexed set of sections.

All of it is one dependency and needs Zig 0.16.

- [Your first benchmark](#your-first-benchmark): write a suite, wire the executable, compare two runs.
- [Test runner flags](#test-runner-flags): formats, filtering, timeouts, flake hunting.
- [Writing benchmarks](#writing-benchmarks): the loop, sub-benchmarks, names, and output.
- [Embedded fixtures](#embedded-fixtures): base64 and hex blobs, and txtar archives, read at comptime.
- [Artifacts](#artifacts): `--artifacts=DIR` gives each test a directory for the files worth keeping when it fails.
- [For library authors](#for-library-authors): keep the runner and benchmarks out of your consumers' builds.
- [Limits](#limits): what the language does not allow this runner to do.

The [API reference](api/) documents every symbol.

# Getting started

## Install

```sh
zig fetch --save https://baskingspot.dev/testingx/v0.3.0.tar.gz
```

## Wire it into build.zig

Point `.test_runner` at the runner inside the dependency and turn off caching for the run step:

```zig
const testingx = b.dependency("testingx", .{ .target = target });

const tests = b.addTest(.{
    .root_module = mod,
    .test_runner = .{ .path = testingx.path("src/runner.zig"), .mode = .simple },
});
const run_tests = b.addRunArtifact(tests);
run_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
```

`mode = .simple` is what skips the binary protocol the built-in runner uses. That protocol is also why writing to stdout in a test could deadlock; with the simple mode, it cannot.

The simple mode also means the run step declares no outputs, so Zig treats it as side-effecting and runs it on every build. `has_side_effects` is not needed here. It matters for the built-in runner's step, which is cacheable: with a fixed seed, an unchanged build can skip the run.

The runner file stays in the dependency. Do not import it from your code: a `test_runner` source compiles as its own module, and a file cannot belong to two modules.

Passing the build's seed through means a failing randomized test prints the seed that reproduces it. The summary always ends with `(seed: 0x...)`.

## What you get

Without a terminal, passing tests print nothing. A failure prints a block:

```text
--- FAIL: intentional failure (0.00ms)
    error.TestUnexpectedResult
    tests/fixtures.zig:20:5: 0x... in test.intentional failure (fixtures)
        try testing.expect(1 == 2);
        ^
testingx: 1 passed, 1 failed, 1 skipped (of 3 total) in 110ms (seed: 0x0)
TESTS FAILED
```

On a terminal you get dots, one per test: `.` pass, `F` fail, `S` skip, `L` leak.

The summary line is stable, and scripts may parse it:

```text
testingx: N passed, M failed, K skipped (of T total) in Xms (seed: 0x...)
ALL TESTS PASSED
```

Leaks and error logs add clauses to the count: `, 1 leaked`, `, 2 error logs`, `, 1 flaky`.

A test that leaks memory fails. A test that emits an `error` level log fails, even when it returns success. Both match the built-in runner.

# Your first benchmark

## Write the suite

The suite root is a normal file with a `benchmarkMain` function. It registers what runs. `addMod` takes a module and registers every `pub fn benchmarkX(b: *testingx.B) !void` at its top level; `add` registers one function under a name you choose.

```zig
const testingx = @import("testingx");

const sort_bench = @import("sort_bench.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(sort_bench);
    try b.add("Parser/Baseline", benchmarkParserBaseline);
}

fn benchmarkParserBaseline(b: *testingx.B) !void {
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) sink +|= parse(input);
}
```

Put the import in a top-level `const`. An inline `@import` inside `benchmarkMain` reads worse and trips ziglint's Z028 when that rule is on.

`addMod` looks at top-level declarations only. It never descends into nested structs, so each file gets one line. Nested benchmarks are `b.run` calls inside a running benchmark.

## Wire the executable

`addBench` builds a ReleaseFast executable around your suite and returns the run step:

```zig
const testingx = @import("testingx");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const tx = b.dependency("testingx", .{ .target = target });

    // ... define mylib_mod, the module the benchmarks measure:

    const run_bench = testingx.addBench(b, .{
        .module = tx.module("testingx"),
        .root_source_file = b.path("bench/bench.zig"),
        .imports = &.{.{ .name = "mylib", .module = mylib_mod }},
    });
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run benchmarks").dependOn(&run_bench.step);
}
```

The `.imports` field is how the suite reaches your code. The suite module is created for it, so it inherits nothing from the rest of the build; list every module the suite files import.

ReleaseFast is the default because Debug numbers are noise. Pass `.optimize = .ReleaseSafe` when a check depends on safety, and `.target` to cross-build.

For a profiling binary (`perf`, `objdump`), call `addBenchExe` instead and install the returned compile step.

## Run it

```sh
zig build bench
```

```text
target: aarch64-linux-gnu
cpu: neoverse_v3
mode: ReleaseFast
BenchmarkParser/Baseline	1000	244.0 ns/op
```

`--benchtime` takes a duration or a fixed count: `--benchtime=250ms`, `--benchtime=100x`. `--filter` selects by name, with the same grammar as the test runner. `--benchmem` adds `B/op` and `allocs/op`. `--cycles` adds `cycles/op`, `instructions/op`, `ipc`, and the cache and branch counts the CPU will grant (Linux, user space). `--jsonl` prints one JSON object per record instead of text.

Three variables exist for CI policy, and a command-line flag wins: `TESTINGX_BENCH_FILTER` is `--filter`, `TESTINGX_BENCH_JSONL` (`1` or `true`) is `--jsonl`, and `TESTINGX_BENCH_CYCLES` is `--cycles`.

Two captures compare with `benchstat`:

```sh
zig build bench -- --benchmem --count=10 --benchtime=100ms > run1.txt
zig build bench -- --benchmem --count=10 --benchtime=100ms > run2.txt
benchstat run1.txt run2.txt
```

Keep captures on the same machine. Numbers from a laptop and a CI runner are different units.

# Test runner flags

Pass flags after `--`:

```sh
zig build test -- --format=testname --filter=^fixtures.test.skip demonstration$
```

| Flag                   | Default                        | Effect                                                                         |
| ---------------------- | ------------------------------ | ------------------------------------------------------------------------------ |
| `--format=NAME`        | dots on a TTY, quiet otherwise | `quiet`, `dots`, `testname`, `verbose`                                         |
| `--filter=P`           | none                           | Run tests whose name matches P. A filter that matches nothing fails the run.   |
| `--skip=P`             | none                           | Drop tests whose name matches P, after `--filter` has selected                 |
| `--list`               | off                            | Print the selected test names to stdout and run nothing                        |
| `--artifacts=DIR`      | off                            | Give each test `DIR/<name>/` for files worth keeping when it fails             |
| `--allow-empty-filter` | off                            | A filter that matches nothing prints a zero summary and passes                 |
| `--seed=N`             | build seed                     | Random seed, printed in the summary                                            |
| `--timeout=D`          | `10m`                          | Stop after D (`500ms`, `10m`); `off` disables. Names the test it was stuck in. |
| `--count=N`            | 1                              | Run the whole suite N times                                                    |
| `--rerun-fails=N`      | off                            | Retry failed tests up to N attempts; a retry that passes is reported as flaky  |
| `--shuffle=on\|off\|N` | off                            | Shuffle order. `on` uses the run seed; N is a fixed seed.                      |
| `--slowest=N`          | off                            | List the N slowest tests after the summary                                     |
| `--plain`              | off                            | No ANSI colors                                                                 |
| `--fail-fast`          | off                            | Stop at the first failure                                                      |

## Environment

A few settings also come from the environment, so a shared CI workflow can change them without editing the repository. A command-line flag wins over the variable.

| Variable                      | Same as                                  |
| ----------------------------- | ---------------------------------------- |
| `TESTINGX_FORMAT`             | `--format`                               |
| `TESTINGX_FILTER`             | `--filter`                               |
| `TESTINGX_SKIP`               | `--skip`                                 |
| `TESTINGX_ARTIFACTS`          | `--artifacts`                            |
| `TESTINGX_TIMEOUT`            | `--timeout`                              |
| `TESTINGX_FAIL_FAST`          | `--fail-fast` (`1` or `true`)            |
| `TESTINGX_ALLOW_EMPTY_FILTER` | `--allow-empty-filter` (`1` or `true`)   |
| `NO_COLOR`                    | `--plain`, when set to a non-empty value |

`--list` prints the fully qualified names, which are the strings the filters match, so the output feeds back into `--filter` for a single test. It exits 0 even when the selection is empty.

`--skip` is the mirror of `--filter`: the filter chooses, then the skip removes. A skip that leaves nothing to run passes, because the exclusion was deliberate.

`--allow-empty-filter` exists for a build with more than one test binary. Pass the same flags to every binary, and the binaries with no matching test print a zero summary and exit 0 instead of failing. The default stays strict: a typo in a single-binary run still fails.

## Formats

`quiet` prints nothing for passes and a block for failures, which is the default without a terminal. `dots` prints one character per test and is the default on a terminal. `testname` prints a line per test with icons:

```text
✔ basic arithmetic passes (0.00ms)
∅ skip demonstration (0.00ms)
✖ intentional failure (0.00ms)
```

`verbose` prints Go's `-v` shape:

```text
=== RUN basic arithmetic passes
--- PASS: basic arithmetic passes (0.00ms)
--- SKIP: skip demonstration (0.00ms)
```

`std.log` is the way to log from a test. A line belongs to the test that emitted it: the runner holds it and prints it indented under the result when the test fails, so a passing run stays quiet and a failure carries its own context.

```text
--- FAIL: intentional failure (0.00ms)
    [default] (info): about to fail
    error.TestUnexpectedResult
```

`verbose` prints those lines for passing tests too. `std.log.err` fails the test, as it always has, and `debug` stays with the runner's own diagnostics. Outside a test, log lines print when they happen.

## Filters

Plain text matches anywhere in the name. `^` anchors the start, `$` anchors the end, `*` matches any bytes, and commas separate alternatives.

Filters match the fully-qualified test name, which includes the module path: `fixtures.test.skip demonstration`. The unanchored form does not care. With anchors, use the full name.

## Flake hunting

`--rerun-fails=N` reruns only the failures. A test that passes on a retry is reported as flaky and does not fail the exit code:

```text
testingx: 0 passed, 0 failed, 0 skipped, 1 flaky (of 1 total) in 114ms (seed: 0x0)
testingx: flaky: flaky demonstration
ALL TESTS PASSED
```

`--count=N` reruns everything, for a test that fails once in twenty runs. `--shuffle` finds order dependence: run with `--shuffle=on`, and when a failure appears, rerun with `--shuffle=<seed>` from the summary. `--timeout` names the test that hung, which beats killing the process and guessing.

# Writing benchmarks

## The loop

A benchmark is a function that takes `*testingx.B`. `b.loop()` runs the body the right number of times; keep the result alive with `defer b.keepAlive(sink)` so the optimizer cannot delete the work.

```zig
fn benchmarkHash(b: *testingx.B) !void {
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) sink +%= hash(input);
    b.setBytes(@intCast(input.len)); // adds MB/s to the row
}
```

`b.n` is available for a hand-written loop (`while (i < b.n) : (i += 1)`) when the body cannot use `b.loop()`. `b.allocator` counts allocations. Every allocation through it shows up in `B/op` and `allocs/op` when `--benchmem` is on. `b.reportMetric(value, "unit")` adds a custom column. `b.reportCounters()` turns counters on for that one benchmark, the per-benchmark form of `--cycles`. `b.io` is a per-benchmark `Io.Threaded`, for file or clock work.

Setup that should not be measured goes before the loop, or inside `b.resetTimer()` / `b.stopTimer()` / `b.startTimer()` when it interleaves.

## Sub-benchmarks

`b.run(name, fn)` runs a benchmark inside the current one, the way Go's `b.Run` does. Names join with `/`:

```zig
pub fn benchmarkDecode(b: *testingx.B) !void {
    inline for (.{ "digits", "twain" }) |suite| {
        _ = try b.run("text=" ++ suite, Decode(suite).run);
    }
}
```

Use `key=value` parts for labeled matrices and plain parts for sizes or cases. `benchstat` groups by these parts, so `Decode/text=digits` compares across runs and `Decode/text=twain` stays separate.

Names drop the `benchmark` prefix when they register: `benchmarkDecode` is `Decode`, and the row prints `BenchmarkDecode`. Filters accept either spelling.

## Output

Text output is the Go benchmark format. Configuration lines come first, then one result line per run:

```text
target: aarch64-linux-gnu
cpu: neoverse_v3
mode: ReleaseFast
BenchmarkDecode/text=digits	1000	154125 ns/op	64.88 MB/s
```

`--config key=value` adds your own lines, repeatable, for anything the environment lines miss (a git revision, a governor setting). The environment lines are suppressed by `--no-env`.

A failed or skipped benchmark is a comment, not a result, so the result stream stays parseable:

```text
# FAIL: BenchmarkBroken
# SKIP: BenchmarkSlow
```

`--jsonl` replaces the text with one JSON object per line, a configuration object first and then one per benchmark. Failed and skipped benchmarks are objects there.

## In CI

Do not gate on benchmark numbers from CI machines. Run the benchmarks to prove they still execute:

```sh
zig build bench -- --benchtime=8x --count=1 --no-env
```

That runs every benchmark eight times and fails if any of them fails. Gate on the exit code.

# Embedded fixtures

Two helpers keep binary test data out of version control without a runtime file load.

For one file, decode an embedded blob at comptime:

```zig
const cert_der = testingx.b64(@embedFile("cert.der.b64"));
const frame = testingx.hex(@embedFile("frame.hex"));
```

For several, embed a txtar archive and read sections by name:

```zig
const fx = testingx.fixtures(@embedFile("fixtures.txtar"));

pub const server_cert_der = fx.b64("server_cert_der");
pub const rsa_pss_key_pem = fx.get("rsa_pss_key_pem");
```

The archive holds plain text sections. The encoding is chosen in Zig, not declared in the archive:

```text
ztls certificate fixtures.
-- server_cert_der --
MIIBlzCCATygAwIBAgIUPpCfJzgbUglYnrYT0qoD85WC/9Ew...
-- rsa_pss_key_pem --
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCO0v0Z...
```

`get` returns the section text as txtar stores it. A non-empty section ends with a newline. `b64` and `hex` ignore whitespace and decode at comptime, so wrapped base64 works.

The value is the archive, and its type is generated from the embedded bytes. `files` is `[]const Fixture`, where each entry is `{ name, text }`. `comment` is the archive comment. The decoders resolve to compile-time constants, so there is no parse at startup and no allocator. `fx.files` lists every section in archive order, and `fx.find(name)` returns a `Fixture` at runtime when the name is not a literal. A name that is not in the archive is a compile error in `get`, `b64`, and `hex`. So is a duplicate marker name.

The decoders take a comptime name. A runtime loop can use `find` to read raw section text, but it cannot decode a section whose name is only known at runtime.

`@embedFile` resolves a path relative to the source file that contains it. The helpers take the embedded bytes rather than a path, so the `@embedFile(...)` call stays in your file. There is no runtime file access.

Write the encoded text with the usual tools. Whitespace is ignored when decoding, so wrapping is safe:

```sh
base64 -w 76 cert.der > cert.der.b64   # GNU
base64 -i cert.der > cert.der.b64      # macOS
xxd -p frame.bin > frame.hex
```

The `.b64` and `.hex` suffixes are a convention for humans; the helpers only see the text. One blob does not need an archive, and an archive of plain text sections does not need either decoder.

# Artifacts

A test can leave files behind for the person reading a failure. `--artifacts=DIR` gives every test a directory at `DIR/<test name>/`, created when the test asks for it:

```zig
const archive = try testingx.txtar.format(testing.allocator, "roundtrip", &.{
    .{ .name = "input", .text = input },
    .{ .name = "output", .text = output },
});
defer testing.allocator.free(archive);
try testingx.writeArtifact(testing.allocator, "roundtrip.txtar", archive);
```

The runner keeps the directory when the test fails and names it under the failure:

```text
--- FAIL: roundtrip (0.00ms)
    artifacts: zig-out/artifacts/parser.test.roundtrip
```

A passing test's directory is deleted, so the tree holds only failures from the last run. Without `--artifacts`, `artifactDir` returns null and `writeArtifact` writes nothing, so the same test runs unchanged anywhere.

`txtar.format` writes what `fixtures()` reads. An artifact worth keeping becomes a fixture by copying it into the test's archive file and rebuilding; the fixture stays text in the repository.

# For library authors

A library's consumers should not download the test runner or the benchmark tooling. Two pieces make that true.

Mark the dependency lazy in `build.zig.zon`:

```zig
.testingx = .{ .url = "git+https://github.com/baskingspot/testingx#<commit>", .hash = "...", .lazy = true },
```

Then put a guard between the part of the build that ships and the part that exists to develop it:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const lib_mod = b.addModule("mylib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    b.installArtifact(b.addLibrary(.{
        .name = "mylib",
        .root_module = lib_mod,
        .linkage = .static,
    }));

    // Everything below is for this repo only: tests, benchmarks, and the
    // tools they need. Consumers of the package never reach it.
    if (b.pkg_hash.len != 0) return;

    const testingx = b.dependency("testingx", .{ .target = target });
    // ... test and bench steps
}
```

`b.pkg_hash` is empty when the script runs as the root package and non-empty when it runs as someone else's dependency. The early return keeps the development graph out of their build: no runner, no benchmarks, no test step.

The guard is a boundary marker, not a header line. Put it after the last declaration a consumer needs. Too early and consumers lose a module or an installed artifact, with an error about a missing module. Too late and the dev dependencies stay on their fetch path. A library with no test or bench steps has nothing to guard, so it does not need the line at all.

Lazy alone is not enough. A consumer's build runs your `build.zig`, and if the script asks for the dependency on every evaluation, their build fetches it. The guard is what stops that.

The bench step needs both lazy pieces when the dependency is lazy: the build.zig type comes from `lazyImport`, and the module comes from `lazyDependency`.

```zig
if (b.lazyImport(@This(), "testingx")) |testingx| {
    const tx_dep = b.lazyDependency("testingx", .{}) orelse unreachable;
    const run_bench = testingx.addBench(b, .{
        .module = tx_dep.module("testingx"),
        .root_source_file = b.path("bench/bench.zig"),
        .imports = &.{.{ .name = "mylib", .module = mod }},
    });
    b.step("bench", "Run benchmarks").dependOn(&run_bench.step);
}
```

A path dependency in a lazy slot fails harder than it looks: when the directory is missing, the build script cannot compile, so every `zig build` fails before any step runs. Pin a git URL for anything shared.

# Limits

Zig's compiler fixes what a test runner can do. Tests are `fn () anyerror!void` collected into `builtin.test_functions`, one process, no parameters.

- Tests run one at a time. There is no parallel test execution, because every test shares the globals in `std.testing`.
- There are no subtests and no way to attach a reason to a skip. `error.SkipZigTest` is the whole vocabulary.
- Fuzz mode needs the built-in runner, which speaks the server protocol. Use a `-Dfuzz` option and pass `null` for `.test_runner` when it is set.
- Filters match the fully-qualified name, not the short name in the output.
- Benchmarks are not tests. `zig build test` never runs them; they need their own step and a ReleaseFast build.

Watch mode is not a runner feature. `zig build test --watch` is the build system's, and it works with this runner.
