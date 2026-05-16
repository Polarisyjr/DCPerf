#!/usr/bin/env bash
# Per-bench definition for feedsim. Sourced by ../dcperf.sh.
# Wraps DCPerf's `feedsim_autoscale` job (default QPS search).

BENCH_JOB="feedsim_autoscale"
BENCH_INSTALL_PROBE="/DCPerf/benchmarks/feedsim/src/build/workloads/ranking/LeafNodeRank"
BENCH_RUN_ARGS=()
BENCH_INSTALL_ETA="~7-40 min depending on dnf cache"
BENCH_RUN_ETA="default QPS search, ~30 min"

# Swap feedsim_autoscale's single cpu-mpstat hook for the full `perf` hook
# (the 10-monitor bundle: mpstat / memstat / netstat / cpufreq_* / perfstat
# / topdown / power / ctxsw / syscall_ebpf). Idempotent.
bench_patch_jobs_yml() {
    docker exec -i "$BENCH_CONTAINER" python3 - <<'PYEOF'
import pathlib, re, sys

p = pathlib.Path('/DCPerf/benchpress/config/jobs.yml')
s = p.read_text()

old = """  hooks:
    - hook: cpu-mpstat
      options:
        args:
          - '-u'   # utilization
          - '1'    # second interval
    - hook: copymove
      options:
        is_move: true
        after:
          - 'benchmarks/feedsim/feedsim_results*.txt'
          - 'benchmarks/feedsim/feedsim-multi-inst-*.log'
          - 'benchmarks/feedsim/src/perf.data'"""
new = """  hooks:
    - hook: perf
    - hook: copymove
      options:
        is_move: true
        after:
          - 'benchmarks/feedsim/feedsim_results*.txt'
          - 'benchmarks/feedsim/feedsim-multi-inst-*.log'
          - 'benchmarks/feedsim/src/perf.data'"""

# Only touch the feedsim_autoscale entry, not feedsim_default / _arm.
m = re.search(r'(?ms)^- name: feedsim_autoscale\n.*?(?=^- name:|\Z)', s)
if not m:
    sys.exit('jobs.yml: feedsim_autoscale entry not found')
block = m.group(0)

if old in block:
    new_block = block.replace(old, new, 1)
    p.write_text(s.replace(block, new_block, 1))
    print('jobs.yml: patched cpu-mpstat -> perf for feedsim_autoscale')
elif '- hook: perf' in block:
    print('jobs.yml: already patched (perf hook present)')
else:
    sys.exit('jobs.yml: feedsim_autoscale hooks block does not match either '
             'the upstream layout or the patched layout; edit manually')
PYEOF
}

bench_force_cleanup() {
    docker exec "$BENCH_CONTAINER" bash -c \
        'cd /DCPerf && ./packages/feedsim/cleanup_feedsim.sh 2>/dev/null || true'
}
