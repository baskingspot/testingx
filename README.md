<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="testingx" height="48">
  </picture>
</h1>

A plain-text test runner, Go-style benchmarks, and compile-time test fixtures for Zig 0.16.

Zig's built-in test runner draws a progress display and speaks a binary protocol to the build runner, which is why output piped to a file is unreadable and why writing to stdout in a test can deadlock. testingx replaces it with plain text on stderr. The benchmark half follows Go's `testing.B` and prints the Go benchmark format, so `benchstat` compares two runs with no glue. The fixture helpers keep binary test data as base64 or hex text and organize fixtures in txtar archives, all read at compile time. One dependency, no dependencies of its own, Zig 0.16 only.

## What is in it

- [Your first benchmark](https://baskingspot.dev/testingx/#your-first-benchmark): a suite is a file with `pub fn benchmarkMain(b: *testingx.B) !void`. `addBench` builds it as a ReleaseFast executable.
- [Test runner flags](https://baskingspot.dev/testingx/#test-runner-flags): `--format`, `--filter`, `--timeout`, `--count`, `--rerun-fails`, `--shuffle`, and `--slowest`. A wrong filter fails instead of passing silently; `--allow-empty-filter` relaxes that for multi-binary builds.
- [Writing benchmarks](https://baskingspot.dev/testingx/#writing-benchmarks): `b.loop()`, `defer b.keepAlive(sink)`, `b.setBytes`, `b.reportMetric`, and `b.run` for sub-benchmarks. Names use benchfmt parts, so benchstat groups a matrix.
- [Embedded fixtures](https://baskingspot.dev/testingx/#embedded-fixtures): `testingx.b64` and `testingx.hex` decode one embedded file, and `testingx.fixtures` reads a txtar archive by name at compile time.
- [Artifacts](https://baskingspot.dev/testingx/#artifacts): `--artifacts=DIR` gives each test a directory of files worth keeping when it fails, and deletes it when the test passes.
- [For library authors](https://baskingspot.dev/testingx/#for-library-authors): `.lazy = true` plus `if (b.pkg_hash.len != 0) return;` keeps the runner and benchmarks out of a consumer's build.
- [Limits](https://baskingspot.dev/testingx/#limits): what the compiler does not allow, such as parallel tests and subtests.

Not implemented:

- Fuzz mode uses the built-in runner, which speaks the server protocol that `.mode = .simple` skips. Select the runner with a `-Dfuzz` option and leave `.test_runner` null for that build.
- Tests run one at a time. `std.testing` keeps its allocator and I/O in globals, so there is nothing to parallelize safely.
- A skip cannot carry a reason. `error.SkipZigTest` is the whole vocabulary.

## Install

```sh
zig fetch --save https://baskingspot.dev/testingx/v0.2.0.tar.gz
```

Point the test runner at the dependency:

```zig
const testingx = b.dependency("testingx", .{ .target = target });

const tests = b.addTest(.{
    .root_module = mod,
    .test_runner = .{ .path = testingx.path("src/runner.zig"), .mode = .simple },
});
const run_tests = b.addRunArtifact(tests);
run_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
```

Benchmarks take one more step. `testingx.addBench` builds the suite and returns the run step. The [guide](https://baskingspot.dev/testingx/#your-first-benchmark) has the wiring, including the `.imports` list the suite needs.

testingx builds with Zig 0.16 only.

## Documentation

- The [guide](https://baskingspot.dev/testingx/) covers adoption, flags, benchmark authoring, fixtures, and the library-author setup, with examples that compile.
- The [API reference](https://baskingspot.dev/testingx/api/) documents every symbol.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain. `just` lists the recipes, and `just ci` runs the tests, the lint, and the docs build.

## License

MIT. See [`LICENSE`](LICENSE). The logo files in `docs/static/` are baskingspot marks and are not covered by it. See [`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
