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
# NOTE: django standalone runs client (siege ~1.2*nproc threads) + server (uwsgi
# nproc procs) + cassandra all in one container, oversubscribing every core;
# with no headroom the Azure guest-agent heartbeat starves and the host watchdog
# hard-resets the VM a few minutes in. Reserve host cores from the caller, e.g.
#   DCPERF_RESERVE_CORES=8 ./dcperf.sh djangobench all
# dcperf.sh then pins the container to the remaining cores via docker update.
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
    # uwsgi.ini may already be deployed here (short-circuit path); fix it now.
    # Fresh installs deploy it during benchpress install -> bench_post_install.
    _fix_uwsgi_ipv6
}

# uwsgi.ini ships `hostname = [::]:8000` -> `http-socket = [::]:8000` (IPv6).
# On IPv6-off hosts uwsgi dies at startup with "socket(): Address family not
# supported by protocol", and run.sh then hangs forever in its
# `while ! nc -z localhost 8000` readiness loop (cassandra up, no uwsgi/siege).
# Rebind to IPv4 0.0.0.0 in the deployed uwsgi.ini. Mirrors
# docker/mediawiki/start.sh's _strip_nginx_ipv6: the upstream template stays
# pristine; this re-applies in-container each run. Idempotent; skips if the
# file isn't laid down yet.
_fix_uwsgi_ipv6() {
    local ini=/DCPerf/benchmarks/django_workload/django-workload/django-workload/uwsgi.ini
    docker exec "$BENCH_CONTAINER" test -f "$ini" 2>/dev/null || return 0
    docker exec "$BENCH_CONTAINER" sed -i 's/\[::\]:8000/0.0.0.0:8000/' "$ini"
    echo "uwsgi.ini: ensured IPv4 bind 0.0.0.0:8000 (host has IPv6 off)"
}

# Fresh installs deploy uwsgi.ini during benchpress install, after
# bench_patch_jobs_yml has already run -- so re-apply the IPv4 bind once it exists.
bench_post_install() {
    _fix_uwsgi_ipv6
}

# Skip cleanup_django_workload.sh -- its `pkill java/memcache/uwsgi` is unsafe
# under --pid=host (would kill matching host processes too). Just wipe the
# build dirs; benchpress install -f will redownload + rebuild.
bench_force_cleanup() {
    docker exec "$BENCH_CONTAINER" bash -c \
        'rm -rf /DCPerf/benchmarks/django_workload /DCPerf/benchmarks/siege'
}
