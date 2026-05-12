#!/usr/bin/env bash
# Short-run tao_bench_standalone with the `perf` hook attached. Intended
# for validating the perf-monitor pipeline end-to-end — in particular
# the ctxsw and syscall_ebpf monitors and their post_process derivation
# of *.derived.csv — without paying for the default 20-minute warmup.
#
# Usage:
#   sudo ./quick_test.sh                # warmup=10s test=30s
#   sudo ./quick_test.sh 5 20           # warmup=5s  test=20s
#
# Needs root because:
#   - perf requires CAP_PERFMON (or kernel.perf_event_paranoid<=2)
#   - bpftrace (used by syscall_ebpf) requires root unconditionally
#
# Output (under DCPerf/):
#   benchmark_metrics_<uuid>/
#     perf-stat.csv, ctxsw.csv, ctxsw.derived.csv,
#     syscall-ebpf.csv, syscall-ebpf.derived.csv,
#     amd-zen5-perf-collector-*.csv (or topdown-intel.sys.csv), etc.

set -euo pipefail

WARMUP=${1:-10}
TEST=${2:-30}

cd "$(dirname "$(readlink -f "$0")")"

if [ "$EUID" -ne 0 ]; then
    echo "error: must run as root (perf + bpftrace need it)." >&2
    echo "  try: sudo $0 $*" >&2
    exit 1
fi

# benchpress_cli.py imports `tabulate` (and a few others) that are
# usually pip-installed --user, not system-wide. Resolve the invoking
# user's site-packages and prepend it to PYTHONPATH so root can import.
USER_NAME=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
PYVER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
USER_SITE="$USER_HOME/.local/lib/python$PYVER/site-packages"
if [ -d "$USER_SITE" ]; then
    export PYTHONPATH="$USER_SITE${PYTHONPATH:+:$PYTHONPATH}"
fi

echo "warmup=${WARMUP}s test=${TEST}s  (≈$((WARMUP + TEST + 20))s total)"
echo "PYTHONPATH=${PYTHONPATH:-}"
echo

./benchpress_cli.py run tao_bench_standalone \
    -i "{\"warmup_time\": $WARMUP, \"test_time\": $TEST}" \
    -k perf

# Surface where the per-monitor artifacts landed.
LATEST=$(ls -1dt benchmark_metrics_*/ 2>/dev/null \
    | grep -Ev 'benchmark_metrics_tao_bench_standalone' \
    | head -n1 || true)
if [ -n "$LATEST" ]; then
    echo
    echo "Artifacts in ${LATEST}"
    ls -1 "$LATEST" | grep -E '\.(csv|log)$' | sort | sed 's/^/  /'
fi
