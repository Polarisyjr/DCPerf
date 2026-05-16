#!/usr/bin/env bash
# Per-bench definition for tao_bench_standalone. Sourced by ../dcperf.sh.
# Wraps DCPerf's standalone variant (server + clients on the same machine,
# server NIC=lo). On a 256-LCPU / 690-GiB host the upstream defaults
# (memsize=0 -> 75% of system memory ≈ 517 GB, warmup=5 * memsize ≈ 43 min)
# are wasteful for an initial validation run, so bench_patch_jobs_yml below
# rewrites the memsize var default to 128 GB (warmup clamps to the 1200 s
# minimum, total bench ≈ 32 min).

BENCH_JOB="tao_bench_standalone"
# tao_bench_client is the LAST binary copied into BENCHPRESS_ROOT/benchmarks/
# tao_bench/ by install_tao_bench_x86_64.sh (L169 of the upstream script,
# after the memtier_benchmark build). tao_bench_server is built earlier
# from the patched memcached tree; both must exist to run the bench, but
# the client landing means the install actually ran to completion.
BENCH_INSTALL_PROBE="/DCPerf/benchmarks/tao_bench/tao_bench_client"
BENCH_RUN_ARGS=()
BENCH_INSTALL_ETA="builds OpenSSL 3.3.2 + libevent + folly (huge) + memcached + memtier_benchmark from source; ~25-50 min"
# Upstream default: memsize=0 -> 75% of system memory; on a 690 GiB host
# that's ~517 GB which bloats warmup to ~43 min. Pass `-i '{"memsize":N}'`
# to override at run time, e.g.:
#   ./docker/dcperf.sh taobench bench -i '{"memsize":128}'
#   ./docker/dcperf.sh taobench bench -i '{"memsize":256,"test_time":540}'
BENCH_RUN_ETA="upstream defaults; on this host ~55 min total (warmup ~43 min + test 12 min). Override memsize with -i '{\"memsize\":N}'."

# Inject the `perf` hook bundle ahead of the default copymove hook for the
# tao_bench_standalone entry (same 10-monitor bundle feedsim_autoscale /
# django / mediawiki / videotranscode use). Idempotent.
bench_patch_jobs_yml() {
    docker exec -i "$BENCH_CONTAINER" python3 - <<'PYEOF'
import pathlib, re, sys

p = pathlib.Path('/DCPerf/benchpress/config/jobs.yml')
s = p.read_text()

# Only touch the tao_bench_standalone entry (not the 64g/custom/autoscale/v2_beta
# variants under the same `benchmark:` field).
m = re.search(
    r'(?ms)^- benchmark: tao_bench_standalone\n  name: tao_bench_standalone\n.*?(?=^- benchmark:|\Z)',
    s,
)
if not m:
    sys.exit('jobs.yml: tao_bench_standalone entry not found')
block = m.group(0)

if '- hook: perf' in block:
    print('jobs.yml: already patched (perf hook present)')
    sys.exit(0)

new_block, n = re.subn(
    r'(^  hooks:\n)(    - hook: )',
    r'\1    - hook: perf\n\2',
    block,
    count=1,
    flags=re.M,
)
if n == 0:
    sys.exit('jobs.yml: tao_bench_standalone hooks block does not match expected layout')

p.write_text(s.replace(block, new_block, 1))
print('jobs.yml: inserted perf hook into tao_bench_standalone')
PYEOF
}

# Upstream cleanup_tao_bench.sh just rm -rf's benchmarks/tao_bench. Same
# behavior here. The build dir (folly subtree, OpenSSL build-deps, etc.)
# is fully self-contained under that path, so wiping it forces a clean
# rebuild without touching other state.
bench_force_cleanup() {
    docker exec "$BENCH_CONTAINER" bash -c \
        'rm -rf /DCPerf/benchmarks/tao_bench'
}

# Pre-stage zlib-1.3.1 into folly's getdeps download cache. As of late 2025
# zlib.net no longer serves /zlib-1.3.1.tar.gz at the root (only the current
# version is there; older versions moved to /fossils/). Folly's bundled
# manifest still points to the root URL, so getdeps fails with a 404 in the
# middle of the build. We fetch from github.com/madler/zlib's release
# assets (SHA256-identical to fossils) and drop the tarball at the exact
# path getdeps would write it to; the SHA256 check inside getdeps still
# runs and would reject a corrupted file.
bench_pre_install() {
    docker exec "$BENCH_CONTAINER" bash -c '
        set -eu
        cache=/DCPerf/benchmarks/tao_bench/build-folly/downloads
        target=$cache/zlib-zlib-1.3.1.tar.gz
        mkdir -p "$cache"
        if [ -s "$target" ]; then
            echo "    (zlib-1.3.1 already staged at $target)"
            exit 0
        fi
        echo "==> pre-staging zlib-1.3.1 for folly getdeps"
        curl -fsSL --retry 3 \
            -o "$target" \
            "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
        echo "    sha256: $(sha256sum "$target" | cut -d" " -f1)"
    '
}
