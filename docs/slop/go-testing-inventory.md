# Go testing: the API, and the gaps in testingx

Inventory taken 2026-10-25 against `pkg.go.dev/testing` and `go doc` for Go
1.26.9. The purpose is to find features worth taking, not to match Go method
for method. Go's package is a test runtime. testingx is a runner plus a
benchmark engine, and Zig fixes part of the shape.

## What Go ships

Package functions: `AllocsPerRun`, `Short`, `Verbose`, `Testing`, `Init`,
`Main`, `RunTests`, `RunBenchmarks`, `RunExamples`, `RegisterCover`,
`CoverMode`, `Coverage`.

Types: `T`, `B`, `F`, `M`, `PB`, `TB`, `BenchmarkResult`, plus the `Internal*`
types that exist only for `go test`.

`T` and `TB` methods: `ArtifactDir`, `Attr`, `Chdir`, `Cleanup`, `Context`,
`Deadline`, `Error`, `Errorf`, `Fail`, `FailNow`, `Failed`, `Fatal`, `Fatalf`,
`Helper`, `Log`, `Logf`, `Name`, `Output`, `Parallel`, `Run`, `Setenv`, `Skip`,
`SkipNow`, `Skipf`, `Skipped`, `TempDir`.

`B` methods: everything in `TB`, plus `Elapsed`, `Loop`, `ReportAllocs`,
`ReportMetric`, `ResetTimer`, `Run`, `RunParallel`, `SetBytes`,
`SetParallelism`, `StartTimer`, `StopTimer`.

`F` methods: the `TB` set, plus `Add` and `Fuzz`. `M` has `Run`. `PB` has
`Next`.

Test binary flags: `-artifacts`, `-bench`, `-benchtime`, `-count`, `-cover`,
`-covermode`, `-coverpkg`, `-cpu`, `-failfast`, `-fullpath`, `-fuzz`,
`-fuzztime`, `-fuzzminimizetime`, `-json`, `-list`, `-outputdir`, `-parallel`,
`-run`, `-short`, `-shuffle`, `-skip`, `-timeout`, `-v`, `-vet`, `-benchmem`,
`-blockprofile`, `-blockprofilerate`, `-coverprofile`, `-cpuprofile`,
`-memprofile`, `-memprofilerate`, `-mutexprofile`, `-mutexprofilefraction`,
`-trace`.

## What testingx has

Runner flags: `--seed`, `--filter`, `--allow-empty-filter`, `--format`
(`quiet`, `dots`, `testname`, `verbose`), `--timeout`, `--count`,
`--rerun-fails`, `--shuffle`, `--slowest`, `--plain`, `--fail-fast`, with
environment equivalents for most.

Bench surface: `add`, `addMod`, `run`, `loop`, `n`, `runParallel` with `Pb.next`,
`setParallelism`, `setBytes`, `reportAllocs`, `reportCounters`, `reportMetric`,
`resetTimer`, `startTimer`, `stopTimer`, `elapsed`, `keepAlive`, `fail`, `skip`,
`name`, `allocator`, `io`. Bench flags: `--benchtime`, `--filter`, `--count`,
`--benchmem`, `--parallelism`, `--config`, `--jsonl`, `--cycles`, `--disasm`,
plus the `bench-bin` install step.

## Gaps worth closing

| Idea | Go behavior | Cost | Why it earns a place |
| --- | --- | --- | --- |
| `--list` | `-list` prints matching test names and exits without running | small | CI sharding and editor integration both need the name list. It reuses the filter and the collected `builtin.test_functions`. |
| `--skip=P` | `-skip` removes matches from the run | small | The filter grammar exists. A selection needs both halves: run this, and not that. |
| `b.log(fmt, args)` | `b.Log` writes to the test log | small | Emit `# name: text` comments, which benchfmt tools ignore. Today a benchmark cannot explain itself without corrupting the result stream. |
| `allocsPerRun(n, f)` | `AllocsPerRun` averages allocations over calls | small | Answers "does this function allocate" in a test. The counting allocator already exists. |
| `--parallelism=1,2,4` | `-cpu` runs each benchmark once per value and suffixes the name | medium | Go suffixes every name with GOMAXPROCS. Without a suffix, two parallelism settings cannot sit in one benchstat file. |
| `--json` | `-json` emits one JSON object per event | medium | Defer until a consumer exists. The bench side already has `--jsonl`. |
| `--artifacts` | `-artifacts` saves files on failure, `T.ArtifactDir` | medium | Useful for golden files and crash dumps. No consumer yet. |
| `-cpuprofile` family | Writes pprof profiles from inside the test binary | large | The Zig answer is `perf`, and `--disasm` already covers the codegen question. Do not build a profiler into the runner. |

## Gaps that do not apply

- `t.Parallel`, `t.Run`, subtests: Zig tests are `fn () anyerror!void` with no
  parameter, so there is no value to hang the methods on. The guide's Limits
  section states this.
- `t.TempDir`, `t.Setenv`, `t.Chdir`, `t.Cleanup`, `t.Context`, `t.Output`,
  `t.Helper`, `t.Attr`: the same reason. `defer` covers cleanup, and `std.testing`
  owns the assertion API.
- `B.Cleanup`: `defer` runs after the sub-benchmarks return, which is the
  ordering Go gives.
- Fuzzing (`F`, `-fuzz`): the built-in runner speaks the fuzz server protocol.
  A replacement runner cannot.
- Coverage (`-cover*`): the compiler instruments, not the runner.
- `-short`: the flag is useless without `testing.Short()`, and the test API is
  `std.testing`, which we do not own.
- `B.Loop` keep-alive: Go prevents the optimizer from removing a `B.Loop` body
  and keeps the loop variables alive. Zig needs the explicit `b.keepAlive`
  pattern. This stays documented rather than fixed.

## Deliberate differences

- Filters use the benchmark grammar: contains, `^`, `$`, `*`, comma. Go uses
  regular expressions. A regex engine is a dependency, and the grammar covers
  name selection.
- The runner is quiet on a pipe. Go prints one line per test with `-v` only.
- Benchmarks are a separate executable and a separate build step. Go compiles
  benchmarks into the test binary.
