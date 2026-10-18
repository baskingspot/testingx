# Output format

`zig build bench` prints results in the Go benchmark format, [benchfmt][spec].
It is plain text: people read it, and tools like `benchstat` compare it with no
setup. `src/benchfmt.zig` is the code that reads and writes this format.

[spec]: https://golang.org/design/14313-benchmark-format

```text
rev: test
target: aarch64-linux-gnu
cpu: neoverse_v3
mode: ReleaseFast
BenchmarkPlainContains  1000  244.0 ns/op  16 B/op  1 allocs/op
# FAIL: BenchmarkBroken
```

There are three kinds of lines:

- Settings lines are `key: value`. They describe the runs that follow.
  `--config K=V` adds your own and can be repeated. The environment header
  (`target`, `cpu`, `mode`) comes after your entries; `--no-env` hides it.
- Result lines are a name, a count of iterations, and one or more value-and-
  unit pairs like `244.0 ns/op`. The writer puts `Benchmark` in front of every
  name because the format requires it, and it lines up the columns. Tools split
  fields on any run of whitespace. The usual units are `ns/op`, `MB/s` (when
  the benchmark calls `b.setBytes`), and `B/op` plus `allocs/op` (with
  `--benchmem` or `b.reportAllocs`). `b.reportMetric` adds your own units.
- Comment lines start with `#` and tools skip them. A benchmark that fails or
  is skipped becomes a comment, not a result, so every result line is a real
  measurement: `# FAIL: Name` and `# SKIP: Name`.

`benchstat` reads this output as-is. It shows names without the `Benchmark`
prefix.

## Naming sub-benchmarks

`b.run` joins the parent and child name with `/`. Two shapes, both understood
by tools:

- Labels for matrices: `b.run("level=speed", ...)` produces
  `Decode/level=speed`.
- Plain values: `b.run("1e4", ...)` produces `Decode/1e4`.

## JSON lines

`--jsonl` prints one JSON object per line instead of text:

```json
{"config":{"target":"aarch64-linux-gnu","cpu":"neoverse_v3","mode":"ReleaseFast"}}
{"name":"PlainContains","status":"ok","iters":1000,"values":[{"value":244,"unit":"ns/op"}]}
{"name":"Broken","status":"failed"}
{"name":"Slow","status":"skipped"}
```

The first object holds the settings. Each one after that is a benchmark: its
name, what happened to it, how many iterations it ran, and its values. Failed
and skipped benchmarks are objects too. Names here have no `Benchmark`
prefix. Text stays the default.

## Running benchmarks in CI

Numbers from CI machines are noise. To check that benchmarks still run, use a
small fixed count instead of timings:

```sh
zig build bench -- --benchtime=8x --count=1 --no-env
```

It fails if any benchmark fails. Do not run full-length benchmarks in CI.
