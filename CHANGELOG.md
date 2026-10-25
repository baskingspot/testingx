# Changelog

All notable changes to testingx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
