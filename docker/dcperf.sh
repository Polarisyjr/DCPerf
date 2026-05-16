#!/usr/bin/env bash
# DCPerf docker dispatcher.
#
# Per-bench definitions live in docker/<bench>/start.sh; shared lifecycle
# (image build, container run with privileged flags, perf-gate save/restore,
# install probe, jobs.yml patch invocation, bench run) lives here.
#
# Usage:
#   ./dcperf.sh <bench> <subcmd>      Run a bench-scoped subcommand
#   ./dcperf.sh restore               Restore host perf gates (no bench)
#   ./dcperf.sh help                  Show this help
#
# <bench> (case-insensitive, matches subdir name in docker/):
#   feedsim | djangobench | taobench | mediawiki | videotranscode
#
# <subcmd>:
#   all              setup + install + bench
#   setup            build image + start long-running container
#   install [-f]     install bench inside container (idempotent; -f to wipe)
#   bench | run      run the bench
#   shell            open shell in container
#   stop             stop container (keeps image)
#   clean            remove container + image
#   build            (re)build the image only

set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DCPERF_ROOT="$(cd "$DOCKER_DIR/.." && pwd)"

# Populated by load_bench(). Defaults are derived from the bench name; start.sh
# can override any of them.
BENCH=""
BENCH_DIR=""
BENCH_IMAGE=""
BENCH_CONTAINER=""
BENCH_JOB=""
BENCH_INSTALL_PROBE=""
BENCH_RUN_ARGS=()
BENCH_INSTALL_ETA=""
BENCH_RUN_ETA=""
SAVED_GATES_FILE=""

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Bench loading ---

# Resolve a case-insensitive bench name to docker/<name>/ and source its
# start.sh into our environment. Sets BENCH_* and SAVED_GATES_FILE.
load_bench() {
    local input_lower
    input_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    BENCH_DIR="${DOCKER_DIR}/${input_lower}"
    if [ ! -d "$BENCH_DIR" ]; then
        echo "unknown bench: $1 (no docker/${input_lower}/ directory)" >&2
        exit 2
    fi
    if [ ! -f "$BENCH_DIR/start.sh" ]; then
        echo "bench $1 missing docker/${input_lower}/start.sh" >&2
        exit 2
    fi
    BENCH="$input_lower"
    BENCH_IMAGE="dcperf-${BENCH}:centos9"
    BENCH_CONTAINER="dcperf-${BENCH}"
    BENCH_RUN_ARGS=()
    # Reset callbacks to defaults; start.sh can redefine them.
    bench_patch_jobs_yml() { :; }
    bench_force_cleanup()  { :; }
    bench_pre_install()    { :; }
    # shellcheck source=/dev/null
    source "$BENCH_DIR/start.sh"
    if [ -z "${BENCH_JOB:-}" ]; then
        echo "bench $1 start.sh did not set BENCH_JOB" >&2
        exit 2
    fi
    SAVED_GATES_FILE="/tmp/dcperf-${BENCH_CONTAINER}.perf_gates_orig"
}

# --- Container helpers ---

container_running() {
    docker ps --filter "name=^${BENCH_CONTAINER}$" --format '{{.Names}}' | grep -q .
}

container_exists() {
    docker ps -a --filter "name=^${BENCH_CONTAINER}$" --format '{{.Names}}' | grep -q .
}

require_container() {
    if ! container_running; then
        echo "container ${BENCH_CONTAINER} is not running; run './dcperf.sh ${BENCH} setup' first" >&2
        exit 1
    fi
    # Re-apply perf gates on every install/bench/shell entry. setup only relaxes
    # when creating a new container, so a host reboot (which resets the sysctls
    # to hardening defaults) + plain `start` would leave perf/bpftrace silently
    # degraded. Idempotent: no-op when already relaxed.
    relax_perf_paranoid
}

# --- Perf gate management (save → relax → restore) ---

# Snapshot the host's current perf gates, then relax them so in-container
# perf/bpftrace can see kernel symbols and tracepoints. Idempotent: skips if
# already relaxed.
relax_perf_paranoid() {
    local cur_paranoid cur_kptr
    cur_paranoid=$(sysctl -n kernel.perf_event_paranoid 2>/dev/null || echo 99)
    cur_kptr=$(sysctl -n kernel.kptr_restrict 2>/dev/null || echo 99)
    if [ "${cur_paranoid}" -le 0 ] && [ "${cur_kptr}" -eq 0 ]; then
        echo "    (already relaxed: perf_event_paranoid=${cur_paranoid} kptr_restrict=${cur_kptr})"
        return 0
    fi
    save_perf_gates "${cur_paranoid}" "${cur_kptr}"
    sudo sysctl -w kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0 >/dev/null
}

# Snapshot once per session: skipped if a snapshot file already exists,
# otherwise the next relax (which sees the relaxed values) would overwrite the
# true originals.
save_perf_gates() {
    [ -e "${SAVED_GATES_FILE}" ] && return 0
    printf 'perf_event_paranoid=%s\nkptr_restrict=%s\n' "$1" "$2" \
        > "${SAVED_GATES_FILE}"
}

# Restore from snapshot and remove it. With SAVED_GATES_FILE set (normal path,
# triggered by cmd_bench's EXIT trap), restore the per-bench snapshot. Without
# a bench loaded (./dcperf.sh restore), scan /tmp for any leftover snapshots
# from other benches and restore each.
restore_perf_gates() {
    if [ -n "${SAVED_GATES_FILE:-}" ]; then
        _restore_one "${SAVED_GATES_FILE}"
        return 0
    fi
    local f found=0
    for f in /tmp/dcperf-*.perf_gates_orig; do
        [ -e "$f" ] || continue
        _restore_one "$f"
        found=1
    done
    [ "$found" = 0 ] && echo "    (no perf-gate snapshots to restore)"
    return 0
}

_restore_one() {
    local f="$1"
    [ -e "$f" ] || return 0
    local orig_paranoid orig_kptr
    orig_paranoid=$(awk -F= '/^perf_event_paranoid=/{print $2}' "$f")
    orig_kptr=$(awk -F= '/^kptr_restrict=/{print $2}' "$f")
    if [ -n "${orig_paranoid}" ] && [ -n "${orig_kptr}" ]; then
        sudo sysctl -w kernel.perf_event_paranoid="${orig_paranoid}" \
                       kernel.kptr_restrict="${orig_kptr}" >/dev/null
        echo "==> restored perf gates from $(basename "$f"): perf_event_paranoid=${orig_paranoid} kptr_restrict=${orig_kptr}"
    fi
    rm -f "$f"
}

# --- Subcommands ---

cmd_build() {
    echo "==> building image ${BENCH_IMAGE}"
    docker build -t "${BENCH_IMAGE}" "${BENCH_DIR}"
}

cmd_setup() {
    cmd_build

    if container_exists; then
        if container_running; then
            echo "==> container ${BENCH_CONTAINER} already running"
        else
            echo "==> starting existing container ${BENCH_CONTAINER}"
            docker start "${BENCH_CONTAINER}" >/dev/null
        fi
    else
        echo "==> relaxing host perf gates for in-container profiling"
        relax_perf_paranoid

        echo "==> starting container ${BENCH_CONTAINER}"
        # --privileged + caps + debugfs/tracefs mounts + relaxed seccomp/apparmor
        # is the combo that lets perf, bpftrace, and DCPerf's monitors all work
        # from inside the container without per-tool tweaks. --pid=host gives
        # monitors visibility into host pids; remove only if you want strict
        # container isolation (and accept that pkill/ps in bench scripts will
        # see only container processes).
        docker run -d \
            --name "${BENCH_CONTAINER}" \
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
            "${BENCH_IMAGE}" \
            sleep infinity >/dev/null
    fi

    docker ps --filter "name=^${BENCH_CONTAINER}$"
}

cmd_install() {
    require_container

    local force=0
    case "${1:-}" in
        --force|--reinstall) force=1 ;;
    esac

    if [ "${force}" = 0 ] && [ -n "${BENCH_INSTALL_PROBE}" ] && \
       docker exec "${BENCH_CONTAINER}" test -x "${BENCH_INSTALL_PROBE}" 2>/dev/null; then
        echo "==> ${BENCH} already installed (${BENCH_INSTALL_PROBE} exists); pass --force to reinstall"
        # Still apply jobs.yml patch in case the binary predates this script.
        bench_patch_jobs_yml
        return 0
    fi

    if [ "${force}" = 1 ]; then
        echo "==> cleaning previous install state"
        bench_force_cleanup
    fi

    echo "==> patching jobs.yml"
    bench_patch_jobs_yml

    # bench-specific precheck (e.g. videotranscode dataset staging). Default
    # is a no-op; benches that need host-side prep override it in start.sh.
    bench_pre_install

    echo "==> installing ${BENCH_JOB}${BENCH_INSTALL_ETA:+ (${BENCH_INSTALL_ETA})}"
    # Log goes to BENCH_DIR (user-owned) rather than DCPERF_ROOT to avoid
    # collision with root-owned logs left over from earlier in-container runs.
    local log="${BENCH_DIR}/install.log"
    : > "${log}"
    # Pass benchpress's own -f when our --force is set: benchpress tracks
    # successful installs in /DCPerf/benchmark_installs.txt and otherwise
    # short-circuits with "already installed" even after our cleanup wiped the
    # build directory.
    local bp_force=""
    [ "${force}" = 1 ] && bp_force="-f"
    docker exec "${BENCH_CONTAINER}" bash -c \
        "cd /DCPerf && ./benchpress_cli.py install ${bp_force} ${BENCH_JOB}" \
        2>&1 | tee "${log}"

    if [ -n "${BENCH_INSTALL_PROBE}" ] && \
       docker exec "${BENCH_CONTAINER}" test -x "${BENCH_INSTALL_PROBE}"; then
        echo "==> install OK"
    else
        echo "==> install FAILED; see ${log}" >&2
        exit 1
    fi
}

cmd_bench() {
    require_container
    # Restore on any exit path (success, benchpress failure, Ctrl-C). Trap is
    # process-global so it survives cmd_bench's return and fires when the
    # script itself exits, which is also what we want for cmd_all.
    trap restore_perf_gates EXIT
    echo "==> running ${BENCH_JOB}${BENCH_RUN_ETA:+ (${BENCH_RUN_ETA})}"
    docker exec "${BENCH_CONTAINER}" bash -c \
        "cd /DCPerf && ./benchpress_cli.py run ${BENCH_JOB} ${BENCH_RUN_ARGS[*]:-}"
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
    docker exec -it "${BENCH_CONTAINER}" bash
}

cmd_stop() {
    if container_exists; then
        docker stop "${BENCH_CONTAINER}" >/dev/null
        echo "==> stopped ${BENCH_CONTAINER}"
    fi
}

cmd_clean() {
    if container_exists; then
        docker rm -f "${BENCH_CONTAINER}" >/dev/null
        echo "==> removed container ${BENCH_CONTAINER}"
    fi
    if docker image inspect "${BENCH_IMAGE}" >/dev/null 2>&1; then
        docker rmi "${BENCH_IMAGE}" >/dev/null
        echo "==> removed image ${BENCH_IMAGE}"
    fi
}

# --- Dispatch ---

# Bench-less subcommands first.
case "${1:-help}" in
    restore)
        SAVED_GATES_FILE=""    # signal _restore_one to scan all snapshots
        restore_perf_gates
        exit 0
        ;;
    help|--help|-h|"")
        usage
        exit 0
        ;;
esac

load_bench "$1"
shift

case "${1:-help}" in
    all)        shift; cmd_all "$@" ;;
    build)      shift; cmd_build ;;
    setup)      shift; cmd_setup ;;
    install)    shift; cmd_install "$@" ;;
    bench|run)  shift; cmd_bench ;;
    shell)      shift; cmd_shell ;;
    stop)       shift; cmd_stop ;;
    clean)      shift; cmd_clean ;;
    help|--help|-h)
        usage ;;
    *)
        echo "unknown subcommand: ${1:-}" >&2
        echo
        usage
        exit 2
        ;;
esac
