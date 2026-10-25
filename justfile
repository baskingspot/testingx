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

[doc("Install zig-out/bin/bench: the stable path --disasm and perf record point at")]
[group("test")]
bench-bin:
    zig build bench-bin

[doc("Self-host check for --disasm and --cycles; counters are skipped where the PMU is absent")]
[group("test")]
bench-inspect:
    #!/usr/bin/env bash
    set -euo pipefail
    just bench-bin
    ./zig-out/bin/bench --disasm PlainContains | grep -q 'filter.benchmarkPlainContains'
    ./zig-out/bin/bench --cycles --benchtime=10x > /dev/null

[doc("Compile for the targets we claim: the runner and the bench exe must build off Linux")]
[group("test")]
cross:
    zig build check -Dtarget=aarch64-macos
    zig build check -Dtarget=x86_64-windows

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

[private]
api:
    docgen --root src/root.zig --title testingx --repo-url https://github.com/baskingspot/testingx --rev main --format json --out docs/data

[doc("Build the site into zig-out/site/testingx/: the guide (Zola, from docs/) and the docgen JSON rendered by the theme's api.html")]
[group("docs")]
doc: api
    baskingspot-docs build testingx

[doc("Edit the site with live reload (http://127.0.0.1:1111)")]
[group("docs")]
guide: api
    baskingspot-docs serve testingx

[doc("Deploy the rendered site to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src build.zig
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md docs/content docs/config.toml wrangler.jsonc .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig
    nix fmt
    oxfmt README.md AGENTS.md docs/content docs/config.toml wrangler.jsonc .github
    just --fmt

[doc("Everything CI runs: the tests and checks, lint, and the docs build")]
[group("ci")]
ci: test lint cross doc
