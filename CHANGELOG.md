# Changelog

All notable changes to testingx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `testingx.fuzzBytes` adapts `std.testing.fuzz` to a byte-slice target:
  `fuzzBytes(context, max_len, testOne, options)` fills a `max_len` stack
  buffer and passes the slice to `testOne`. `max_len` is required and
  comptime; there is no default bound. A corpus entry is the bytes the target
  receives: `.corpus = &.{"hello"}` replays `hello`, because the adapter writes
  the length that `Smith.slice` reads. Do not prefix seed files by hand. An
  entry longer than `max_len` reaches the target as its first `max_len` bytes.
  An input the fuzzer saved is already framed, so unwrap a crash file before
  adding it to `.corpus`.

### Fixed

- Benchmarks built with `addBench` and `addBenchExe` install
  `testingx.benchPanic`. A panic prints `PANIC in benchmark "<name>": <message>`
  with a stack trace and exits 1, with no `SIGABRT` or core file. A custom
  benchmark `main` can bind `pub const panic = testingx.benchPanic;`.
- `--disasm` resolves the symbol in a benchmark executable that links libc.
  `std.debug.getModuleName` reports `MissingDebugInfo` for the main program
  when the loader names it with an empty string, so the lookup now falls back
  to the running executable. If your benchmarks call C code, `link_libc = true`
  no longer costs you disassembly.

## [0.5.0] - 2026-11-16

### Removed

- Zig 0.16 support: `minimum_zig_version` is `0.17.0`, and
  `run.addPassthruArgs()` replaces `if (b.args) |args| run.addArgs(args)` for
  forwarding flags after `--`. Build with Zig 0.17 or newer.

## [0.4.0] - 2026-11-02

### Changed

- testingx builds with Zig 0.16 and 0.17. `minimum_zig_version` stays
  `0.16.0`, and CI tests both versions.
- The runner picks a random seed when `--seed` is not given and prints it in
  the summary. The build no longer passes `b.graph.random_seed`, which Zig
  0.17 removed.
- In `build.zig`, forward the flags after `--` with `run.addPassthruArgs()`
  on Zig 0.17. On Zig 0.16, use `if (b.args) |args| run.addArgs(args)`.

## [0.3.0] - 2026-10-31

### Changed

- Public struct fields are now required, so a bare `.{}` or a partial literal no
  longer compiles for value types: `bench.SliceArgs` builds from
  `SliceArgs.init`, `bench.Result` from `Result.zero`, `bench.Pb` from
  `Pb.init`, `perfcounter.Counters` from `Counters.empty`, and
  `benchfmt.Reader` from `Reader.init`; `bench.B` and `bench.CountingAllocator`
  are built only through their `init` constructors. `bench.Options` keeps its
  field defaults: pass a partial literal, or `.{}`, to `Options.parse` and
  `B.init`.

## [0.2.0] - 2026-10-25

### Added

- `--artifacts=DIR` gives each test a directory for files worth keeping on
  failure (`TESTINGX_ARTIFACTS` sets it). `testingx.writeArtifact` writes into
  it, the runner keeps the directory only when the test fails and prints the
  path, and `testingx.txtar.format` writes the same archive format
  `fixtures()` reads, so an artifact can become a fixture.

- `std.log` lines from a test are captured and printed under that test's
  result. A failed test shows its log, `verbose` shows logs for passes too, and
  a quiet run stays quiet. Error logs still fail the test.

- `--skip=P` removes tests from the `--filter` selection, and
  `TESTINGX_SKIP` sets it from the environment. A skip that leaves nothing to
  run passes. `--list` prints the selected fully qualified names to stdout and
  runs nothing, so CI can shard on the output.

- `--disasm PATTERN` prints the linker symbol, its address range, and the
  disassembly of each matching benchmark, with source lines and addresses
  stripped so two builds diff. `--cycles` adds `cycles/op`, `instructions/op`,
  `branches/op`, and `ipc` from hardware counters (Linux, user space), and
  `TESTINGX_BENCH_CYCLES` makes it the local default. `B.reportCounters()` is
  the per-benchmark form, the way `B.reportAllocs()` is for allocations. `zig
build bench-bin` installs the binary both flags point at.

- `--allow-empty-filter` and `TESTINGX_ALLOW_EMPTY_FILTER` make a filter that
  matches no tests print a zero summary and exit 0, so a build can forward one
  filter to every test binary. The default still fails.

## [0.1.1] - 2026-10-19

### Added

- A test runner for Zig 0.16 that writes plain text to stderr, with `--format`,
  `--filter`, `--timeout`, `--count`, `--rerun-fails`, `--shuffle`, and
  `--slowest`.
- Go-style benchmarks: `b.loop()`, `b.setBytes`, `b.reportMetric`, and
  sub-benchmarks through `b.run`, printed in the Go benchmark format so
  `benchstat` compares two runs.
- Compile-time fixtures: `testingx.b64` and `testingx.hex` decode one embedded
  file, and `testingx.fixtures` reads a txtar archive by name.
- A lazy mode (`.lazy = true` with the package-hash guard) so a consumer's build
  never fetches the runner or the benchmarks.
