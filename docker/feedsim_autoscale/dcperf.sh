#!/usr/bin/env bash
# DCPerf docker wrapper for feedsim_autoscale (default config).
#
# Encapsulates the workflow we used to bring feedsim_autoscale up on
# Azure Linux (an unsupported host): a CentOS-9 container with every dep
# preinstalled, the perf-hook patch baked in, and a one-shot bench command
# that runs feedsim_autoscale's default QPS search.
#
# Usage:
#   ./dcperf.sh all              setup + install + bench in one shot (~45 min cold)
#   ./dcperf.sh setup            Build image + start the long-running container
#   ./dcperf.sh install          Install feedsim_autoscale inside container (idempotent)
#   ./dcperf.sh install --force  Wipe partial state and reinstall
#   ./dcperf.sh bench            Run feedsim_autoscale (default QPS search, ~30 min)
#   ./dcperf.sh shell            Drop into a shell inside the container
#   ./dcperf.sh stop             Stop the container (keeps the image)
#   ./dcperf.sh clean            Remove container + image
#
# Results: feedsim CSV under benchmarks/feedsim/, monitor logs under
# benchmark_metrics_<run_id>/, final JSON in the run output (stdout).

set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DCPERF_ROOT="$(cd "$DOCKER_DIR/../.." && pwd)"

IMAGE_NAME="${DCPERF_IMAGE:-dcperf-feedsim_autoscale:centos9}"
CONTAINER_NAME="${DCPERF_CONTAINER:-dcperf-feedsim_autoscale}"

container_running() {
    docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q .
}

container_exists() {
    docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q .
}

require_container() {
    if ! container_running; then
        echo "container ${CONTAINER_NAME} is not running; run './dcperf.sh setup' first" >&2
        exit 1
    fi
}

# Relax host perf gates so in-container perf/bpftrace can see kernel symbols
# and ftrace tracepoints. Hypervisors that don't expose the PMU will still
# return <not supported> for cycles/instructions -- this only fixes the
# software-side restrictions.
relax_perf_paranoid() {
    sudo sysctl -w kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0 >/dev/null
}

# Swap feedsim_autoscale's single cpu-mpstat hook for the full `perf` hook
# (the 10-monitor bundle: mpstat / memstat / netstat / cpufreq_* / perfstat
# / topdown / power / ctxsw / syscall_ebpf). Idempotent.
patch_jobs_yml() {
    docker exec -i "$CONTAINER_NAME" python3 - <<'PYEOF'
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
m = re.search(
    r'(?ms)^- name: feedsim_autoscale\n.*?(?=^- name:|\Z)',
    s,
)
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

cmd_build() {
    echo "==> building image ${IMAGE_NAME}"
    docker build -t "${IMAGE_NAME}" "${DOCKER_DIR}"
}

cmd_setup() {
    cmd_build

    if container_exists; then
        if container_running; then
            echo "==> container ${CONTAINER_NAME} already running"
        else
            echo "==> starting existing container ${CONTAINER_NAME}"
            docker start "${CONTAINER_NAME}" >/dev/null
        fi
    else
        echo "==> relaxing host perf gates for in-container profiling"
        relax_perf_paranoid

        echo "==> starting container ${CONTAINER_NAME}"
        # --privileged + caps + debugfs/tracefs mounts + relaxed seccomp/apparmor
        # is the combo that lets perf, bpftrace, and DCPerf's monitors all work
        # from inside the container without further per-tool tweaks.
        # --pid=host is what makes pkill/ps see the host process tree so the
        # monitors can attribute to the right pids; remove it only if you want
        # strict container isolation.
        docker run -d \
            --name "${CONTAINER_NAME}" \
            --privileged \
            --network=host \
            --pid=host \
            --ipc=host \
            --cap-add=SYS_ADMIN --cap-add=PERFMON --cap-add=SYS_PTRACE --cap-add=IPC_LOCK \
            --security-opt seccomp=unconfined \
            --security-opt apparmor=unconfined \
            --ulimit nofile=1048576:1048576 \
            --ulimit memlock=-1:-1 \
            --ulimit nproc=-1:-1 \
            --shm-size=16g \
            -v "${DCPERF_ROOT}":/DCPerf \
            -v /sys/kernel/debug:/sys/kernel/debug \
            -v /sys/kernel/tracing:/sys/kernel/tracing \
            -v /lib/modules:/lib/modules:ro \
            -w /DCPerf \
            "${IMAGE_NAME}" \
            sleep infinity >/dev/null
    fi

    docker ps --filter "name=^${CONTAINER_NAME}$"
}

cmd_install() {
    require_container

    local force=0
    case "${1:-}" in
        --force|--reinstall) force=1 ;;
    esac

    if [ "${force}" = 0 ] && docker exec "${CONTAINER_NAME}" test -x \
            /DCPerf/benchmarks/feedsim/src/build/workloads/ranking/LeafNodeRank 2>/dev/null; then
        echo "==> feedsim_autoscale already installed (LeafNodeRank exists); pass --force to reinstall"
        # Still apply jobs.yml patch in case the binary predates this script.
        patch_jobs_yml
        return 0
    fi

    if [ "${force}" = 1 ]; then
        echo "==> cleaning previous install state"
        docker exec "${CONTAINER_NAME}" bash -c \
            'cd /DCPerf && ./packages/feedsim/cleanup_feedsim.sh 2>/dev/null || true'
    fi

    echo "==> patching jobs.yml (perf hook for feedsim_autoscale)"
    patch_jobs_yml

    echo "==> installing feedsim_autoscale (~7-40 min depending on dnf cache)"
    # Log goes to DOCKER_DIR (user-owned) rather than DCPERF_ROOT to avoid
    # collision with root-owned logs left over from earlier in-container runs.
    local log="${DOCKER_DIR}/install.log"
    : > "${log}"
    # Pass benchpress's own -f when our --force is set: benchpress tracks
    # successful installs in /DCPerf/benchmark_installs.txt and otherwise
    # short-circuits with "already installed" even if cleanup_feedsim.sh
    # has wiped the build directory.
    local bp_force=""
    if [ "${force}" = 1 ]; then
        bp_force="-f"
    fi
    docker exec "${CONTAINER_NAME}" bash -c \
        "cd /DCPerf && ./benchpress_cli.py install ${bp_force} feedsim_autoscale" \
        2>&1 | tee "${log}"

    if docker exec "${CONTAINER_NAME}" test -x \
            /DCPerf/benchmarks/feedsim/src/build/workloads/ranking/LeafNodeRank; then
        echo "==> install OK"
    else
        echo "==> install FAILED; see ${log}" >&2
        exit 1
    fi
}

cmd_bench() {
    require_container
    echo "==> running feedsim_autoscale (default QPS search, ~30 min)"
    docker exec "${CONTAINER_NAME}" bash -c \
        'cd /DCPerf && ./benchpress_cli.py run feedsim_autoscale'
}

cmd_all() {
    # End-to-end: setup -> install -> bench. Each step is idempotent so
    # re-running after a partial failure picks up where it left off.
    cmd_setup
    cmd_install "$@"
    cmd_bench
}

cmd_shell() {
    require_container
    docker exec -it "${CONTAINER_NAME}" bash
}

cmd_stop() {
    if container_exists; then
        docker stop "${CONTAINER_NAME}" >/dev/null
        echo "==> stopped ${CONTAINER_NAME}"
    fi
}

cmd_clean() {
    if container_exists; then
        docker rm -f "${CONTAINER_NAME}" >/dev/null
        echo "==> removed container ${CONTAINER_NAME}"
    fi
    if docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
        docker rmi "${IMAGE_NAME}" >/dev/null
        echo "==> removed image ${IMAGE_NAME}"
    fi
}

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-help}" in
    all)        shift; cmd_all "$@" ;;
    build)      shift; cmd_build "$@" ;;
    setup)      shift; cmd_setup "$@" ;;
    install)    shift; cmd_install "$@" ;;
    bench|run)  shift; cmd_bench ;;
    shell)      shift; cmd_shell ;;
    stop)       shift; cmd_stop ;;
    clean)      shift; cmd_clean ;;
    help|--help|-h)
        usage ;;
    *)
        echo "unknown subcommand: ${1}" >&2
        echo
        usage
        exit 2
        ;;
esac
