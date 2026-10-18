# testingx: A test runner that replaces the built-in one, and benchmarks that sit beside your tests. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests")]
[group("test")]
test:
    zig build test --summary all

[doc("Run benchmarks (ReleaseFast); args pass to the binary: just bench --benchtime=250ms --benchmem")]
[group("test")]
bench *ARGS:
    @zig build bench -- {{ ARGS }}

[doc("Benchfmt end-to-end: two bench runs into files, benchstat parses and compares them")]
[group("test")]
bench-e2e:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' EXIT
    just bench --benchmem --count=10 --benchtime=100ms > "${tmp}/run1.txt"
    just bench --benchmem --count=10 --benchtime=100ms > "${tmp}/run2.txt"
    benchstat "${tmp}/run1.txt" "${tmp}/run2.txt"

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src build.zig
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig
    nix fmt
    oxfmt README.md AGENTS.md .github
    just --fmt

[doc("Everything CI runs")]
[group("ci")]
ci: test lint
