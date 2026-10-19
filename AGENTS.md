# AGENTS.md

Working notes for AI coding agents in baskingspot/testingx.

## What this is

A test runner that replaces the built-in one, and benchmarks that sit beside your tests. Both halves are one dependency.

## Layout

- `src/runner.zig` is the test runner, referenced as a `.test_runner` path. It compiles as its own module and cannot import any other file in this repo, so anything it needs is copied into it. The filter grammar is copied from `src/filter.zig`, and the fixture checks in `build.zig` pin both copies.
- `src/bench.zig` is the benchmark engine: registration (`add`, `addMod`), execution (`finish`), and sub-benchmarks (`run`). A spawned `B` is filled in place and owns a by-value `Io.Threaded` and `CountingAllocator`. Never copy a spawned `B`.
- `src/benchfmt.zig` is the Go benchmark format codec. Text output is the contract. A result line must start with `Benchmark`, which is format grammar: the writer adds it and the reader strips it. JSONL uses the registered names without the prefix. FAIL and SKIP are comments in text mode.
- `src/fixtures.zig` reads embedded test data: `fixtures(@embedFile(...))` returns a comptime archive value with `get`, `b64`, `hex`, `files`, and `find`, and `b64`/`hex` decode a single embedded blob. `src/txtar.zig` is the comptime-only parser behind it. It follows mattrobenolt/txtar's marker rules and reads only; it never formats.
- `src/root.zig` is the public surface. It also holds a test block that forces every module's tests to be analyzed. Without it, `zig build test` compiles the modules and runs zero tests.
- `src/bench_main.zig`, with `addBench` and `addBenchExe` in `build.zig`, builds a suite into a ReleaseFast executable.
- `benchmarks/` is the self-host suite. `tests/` holds runner fixtures with intentional failures, a panic, a timeout, and a flaky test.
- `docs/` is a Zola site on the baskingspot theme. The guide is `docs/content/_index.md`. `docs/migrate-from-zig-benchmark.md` is an internal handoff document and is not published.

## Environment

Zig 0.16 only. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig, `ziglint`, the docs tools, and `benchstat`, and nothing comes from the system PATH. The justfile is the command interface: `just test`, `just bench`, `just bench-e2e`, `just doc`, `just lint`, `just ci`. Run `just fmt` before you commit.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran.
- Format with `zig fmt` and lint with `ziglint`. `just fmt` and `just lint` run both. `.ziglint.zon` covers `build.zig`, `src`, `benchmarks`, and `tests`; keep those paths.
- This repo's GitHub settings come from `baskingspot/.github`, with `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## Output contracts

Change these only together with the fixture checks in `build.zig`, which assert exact stderr and exit codes:

- The test summary line is `testingx: N passed, M failed, K skipped (of T total) in Xms (seed: 0x...)`, then `ALL TESTS PASSED` or `TESTS FAILED`.
- The default test format is dots on a terminal and quiet otherwise. Quiet prints nothing for a passing test.
- Benchmark rows are benchfmt: `BenchmarkName<TAB>iters<TAB>value unit`.
- A filter that matches nothing fails the run. Test filters match the fully-qualified name; benchmark filters match the printed name and the registered name.

## Traps

- Do not import `src/runner.zig` from another file, and do not import another file from it. The second fails with `file exists in modules 'root' and 'root'`.
- Do not add `has_side_effects` to test runs. In `.mode = .simple` the step declares no outputs, and Zig already reruns it.
- Environment variables set a default and flags win: `TESTINGX_FORMAT`, `TESTINGX_FILTER`, `TESTINGX_TIMEOUT`, `TESTINGX_FAIL_FAST`, `NO_COLOR`, plus `TESTINGX_BENCH_FILTER` and `TESTINGX_BENCH_JSONL` for benchmarks. The fixture checks strip them from the ambient environment.
- The docs build is part of `just ci` and fails on an unlabeled code fence.
- `@embedFile` resolves a path against the file that contains the builtin, not the caller of an inline function. The fixture helpers take embedded bytes for that reason; do not add a path-taking wrapper that calls `@embedFile` from this repo.

## Docs

- The guide is written for people adopting the library, not for contributors. Keep it that way.
- The site deploys from CI after Terraform in `baskingspot/site` registers the Worker. Do not deploy by hand.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
