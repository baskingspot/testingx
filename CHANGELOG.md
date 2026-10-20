# Changelog

All notable changes to testingx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
