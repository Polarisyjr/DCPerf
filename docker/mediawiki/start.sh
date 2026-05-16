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
}

# Skip cleanup_oss_performance_mediawiki.sh's `systemctl stop mariadb` -- the
# systemctl shim handles it but we're about to restart mariadb anyway. Just
# wipe the install artifacts so install_oss_performance_mediawiki.sh re-runs
# from clean state. /usr/local/bin/siege and /opt/local/hhvm-3.30 survive on
# purpose: siege is cheap to rebuild but the install script short-circuits
# on `command -v siege`, and HHVM is baked into the image.
bench_force_cleanup() {
    docker exec "$BENCH_CONTAINER" bash -c '
        rm -rf /DCPerf/oss-performance \
               /DCPerf/benchmarks/oss_performance_mediawiki \
               /DCPerf/memcached-1.5.12
    '
}
