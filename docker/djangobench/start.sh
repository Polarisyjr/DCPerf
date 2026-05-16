#!/usr/bin/env bash
# Per-bench definition for django_workload (-r standalone). Sourced by ../dcperf.sh.
# Wraps DCPerf's `django_workload_default` job in standalone mode so cassandra
# / memcached / uwsgi / siege all run in this single container. Default
# `clientserver` mode would need an external cassandra host.

BENCH_JOB="django_workload_default"
# install_siege.sh declares $SIEGE_INSTALLATION_PREFIX but its ./configure call
# has no --prefix, so siege actually lands at /usr/local/bin/siege (autotools
# default). Probe where it actually lands, not where the variable claims.
BENCH_INSTALL_PROBE="/usr/local/bin/siege"
BENCH_RUN_ARGS=(-r standalone)
BENCH_INSTALL_ETA="downloads cassandra-3.11.10 (~50MB) + pip pkgs + builds siege; ~5-20 min"
BENCH_RUN_ETA="-r standalone, ~35 min: 7 iters x 5 min"

# django_workload_default starts with only the copymove hook. Insert a `perf`
# hook in front so we get the full 10-monitor bundle. Idempotent.
bench_patch_jobs_yml() {
    docker exec -i "$BENCH_CONTAINER" python3 - <<'PYEOF'
import pathlib, re, sys

p = pathlib.Path('/DCPerf/benchpress/config/jobs.yml')
s = p.read_text()

# Only touch the django_workload_default entry (not _arm / _custom).
m = re.search(
    r'(?ms)^- benchmark: django_workload\n  name: django_workload_default\n.*?(?=^- benchmark:|\Z)',
    s,
)
if not m:
    sys.exit('jobs.yml: django_workload_default entry not found')
block = m.group(0)

if '- hook: perf' in block:
    print('jobs.yml: already patched (perf hook present)')
    sys.exit(0)

# Insert `- hook: perf` as the first hook entry. Find the `  hooks:` line and
# add the perf hook before the existing first hook.
new_block, n = re.subn(
    r'(^  hooks:\n)(    - hook: )',
    r'\1    - hook: perf\n\2',
    block,
    count=1,
    flags=re.M,
)
if n == 0:
    sys.exit('jobs.yml: django_workload_default hooks block does not match expected layout')

p.write_text(s.replace(block, new_block, 1))
print('jobs.yml: inserted perf hook into django_workload_default')
PYEOF
}

# Skip cleanup_django_workload.sh -- its `pkill java/memcache/uwsgi` is unsafe
# under --pid=host (would kill matching host processes too). Just wipe the
# build dirs; benchpress install -f will redownload + rebuild.
bench_force_cleanup() {
    docker exec "$BENCH_CONTAINER" bash -c \
        'rm -rf /DCPerf/benchmarks/django_workload /DCPerf/benchmarks/siege'
}
