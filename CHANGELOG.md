# Changelog

All notable changes to testingx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
