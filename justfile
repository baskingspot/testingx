# testingx: A test runner that replaces the built-in one, and benchmarks that sit beside your tests. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests")]
[group("test")]
test:
    zig build test --summary all

# Run a fuzz step under a wall-clock timeout and fail when Zig 0.17.1 swallows
# a fuzzing error or crash into exit 0 (#9, #11).
[private]
fuzz-run STEP LIMIT TIMEOUT:
    #!/usr/bin/env bash
    set -uo pipefail
    log=$(mktemp)
    trap 'rm -f "${log}"' EXIT
    timeout --kill-after=5s "{{ TIMEOUT }}" zig build "{{ STEP }}" --fuzz="{{ LIMIT }}" 2>&1 | tee "${log}"
    status=${PIPESTATUS[0]}
    if [[ ${status} -eq 124 ]]; then
        echo "fuzz-run: timed out after {{ TIMEOUT }} (a test may have returned before std.testing.fuzz)" >&2
        exit 124
    fi
    if [[ ${status} -ne 0 ]]; then
        exit "${status}"
    fi
    if grep -Eq 'failed with error\.|terminated with signal|input saved to ' "${log}"; then
        echo "fuzz-run: fuzzer reported a failure (zig build exited 0)" >&2
        exit 1
    fi
    if ! grep -q '======= FUZZING REPORT =======' "${log}"; then
        echo "fuzz-run: missing fuzzing report" >&2
        exit 1
    fi

[doc("Fuzz fuzzBytes with the built-in runner, for example `just fuzz 100K`. Fails on fuzzer errors or timeout (#9, #11)")]
[group("test")]
fuzz LIMIT="10M" TIMEOUT="5m":
    just fuzz-run fuzz "{{ LIMIT }}" "{{ TIMEOUT }}"

[doc("Expected-fail mutation probe: passes when fuzz-run exits nonzero on error.CorpusDidNotContainThisInput. Not part of ci")]
[group("test")]
fuzz-probe:
    #!/usr/bin/env bash
    set -uo pipefail
    output=$(just fuzz-run fuzz-probe 200K 2m 2>&1)
    status=$?
    printf '%s\n' "$output"
    if [[ ${status} -ne 0 ]] && printf '%s' "$output" | grep -q "failed with error.CorpusDidNotContainThisInput"; then
        echo "fuzz-probe: expected mutation failure caught (exit ${status})"
    else
        echo "fuzz-probe: expected nonzero exit with error.CorpusDidNotContainThisInput (got exit ${status})" >&2
        exit 1
    fi

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

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, the ast-grep rules, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint-0-17
    baskingspot-lint src
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

[doc("The gate: unit tests, fixtures, and the cross builds")]
[group("ci")]
check: test cross

[doc("Everything CI runs: the gate, lint, and the docs build")]
[group("ci")]
ci: check lint doc
