#!/usr/bin/env bash
# Per-bench definition for oss_performance_mediawiki_mlp. Sourced by ../dcperf.sh.
# Wraps DCPerf's MLP-tuned mediawiki job (the official DCPerf headline variant
# for this benchmark: auto-scaled HHVM fleet, +MLP profile, wrk load generator).

BENCH_JOB="oss_performance_mediawiki_mlp"
# wrk is the LAST binary built by install_oss_performance_mediawiki.sh's bench
# tree (composer install runs after, but with `|| true` so its exit status
# can't be trusted as a probe). wrk landing at this exact path also confirms
# the BENCHPRESS_ROOT layout the run.sh expects.
BENCH_INSTALL_PROBE="/DCPerf/benchmarks/oss_performance_mediawiki/wrk/wrk"
BENCH_RUN_ARGS=()
BENCH_INSTALL_ETA="builds wrk + memcached + composer install of MediaWiki; ~10-25 min"
BENCH_RUN_ETA="auto-scaled HHVM, wrk 10m client-duration, total ~15-20 min"

bench_install_ready() {
    docker exec "$BENCH_CONTAINER" bash -c '
        test -x /DCPerf/benchmarks/oss_performance_mediawiki/wrk/wrk &&
        test -x /usr/local/memcached/bin/memcached &&
        test -x /usr/local/bin/siege &&
        test -x /usr/local/hphpi/legacy/bin/hhvm &&
        test -f /DCPerf/oss-performance/perf.php
    ' 2>/dev/null
}

# Inject the `perf` hook (10-monitor bundle: mpstat / memstat / netstat /
# cpufreq_* / perfstat / topdown / power / ctxsw / syscall_ebpf) ahead of the
# default copymove hook for the _mlp variant. Idempotent. Same surgical edit
# pattern as docker/djangobench/start.sh.
bench_patch_jobs_yml() {
    docker exec -i "$BENCH_CONTAINER" python3 - <<'PYEOF'
import pathlib, re, sys

p = pathlib.Path('/DCPerf/benchpress/config/jobs.yml')
s = p.read_text()

# Only touch the oss_performance_mediawiki_mlp entry, not the plain
# oss_performance_mediawiki / _mlp_no_jit / _mem variants.
m = re.search(
    r'(?ms)^- benchmark: oss_performance_mediawiki\n  name: oss_performance_mediawiki_mlp\n.*?(?=^- benchmark:|\Z)',
    s,
)
if not m:
    sys.exit('jobs.yml: oss_performance_mediawiki_mlp entry not found')
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
    sys.exit('jobs.yml: oss_performance_mediawiki_mlp hooks block does not match expected layout')

p.write_text(s.replace(block, new_block, 1))
print('jobs.yml: inserted perf hook into oss_performance_mediawiki_mlp')
PYEOF
    # oss-performance may already be installed here (short-circuit path); if so,
    # fix its nginx template now. On a fresh install it doesn't exist yet --
    # bench_post_install handles that case after the install creates it.
    _strip_nginx_ipv6
}

# nginx.conf.in (installed from 0001-oss-performance-scalable-hhvm.diff) listens
# on `[::]` (IPv6) for both the HTTP and admin ports. On hosts with IPv6
# disabled (no /proc/net/if_inet6) nginx aborts at startup with
#   socket() [::]:<port> failed (97: Address family not supported by protocol)
# which fails the whole mediawiki run before any request is served. Drop the
# IPv6 listen lines; the paired IPv4 `listen <port>` lines right below them keep
# the bench working. Idempotent: the delete is a no-op once the lines are gone,
# and it silently skips if oss-performance isn't laid down yet.
_strip_nginx_ipv6() {
    local nginx_in=/DCPerf/oss-performance/conf/nginx/nginx.conf.in
    docker exec "$BENCH_CONTAINER" test -f "$nginx_in" 2>/dev/null || return 0
    docker exec "$BENCH_CONTAINER" sed -i '/^[[:space:]]*listen[[:space:]]\[::\]:/d' "$nginx_in"
    echo "nginx.conf.in: ensured no IPv6 'listen [::]' lines (host has IPv6 off)"
}

# Fresh installs create oss-performance/ during benchpress install, after
# bench_patch_jobs_yml has already run -- so strip the IPv6 listen lines here,
# once the template actually exists.
bench_post_install() {
    _strip_nginx_ipv6
}

# Skip cleanup_oss_performance_mediawiki.sh's `systemctl stop mariadb` -- the
# systemctl shim handles it but we're about to restart mariadb anyway. Just
# wipe the install artifacts so install_oss_performance_mediawiki.sh re-runs
# from clean state. Siege and memcached are rebuilt into the current container;
# HHVM survives because it is baked into the image.
bench_force_cleanup() {
    docker exec "$BENCH_CONTAINER" bash -c '
        rm -rf /DCPerf/oss-performance \
               /DCPerf/siege \
               /DCPerf/benchmarks/oss_performance_mediawiki \
               /DCPerf/memcached-1.5.12
    '
}
