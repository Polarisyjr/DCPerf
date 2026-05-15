#!/usr/bin/env bash
# DCPerf docker wrapper for django_workload_default (-r standalone).
#
# Mirrors docker/feedsim_autoscale/dcperf.sh. Differences:
#   - jobs.yml entry has no monitor hook by default, so patch_jobs_yml
#     INSERTS the `perf` hook (vs feedsim where it replaces cpu-mpstat).
#   - install probe is the siege binary (last step of install_django_workload).
#   - --force cleanup wipes benchmarks/django_workload + benchmarks/siege rather
#     than invoking packages/django_workload/cleanup_django_workload.sh, whose
#     `pkill java` / `pkill memcache` is dangerous under --pid=host.
#   - bench uses `-r standalone` so cassandra/memcached/uwsgi/siege all run in
#     this one container (default `clientserver` mode would need an external
#     cassandra host).
#
# Usage:
#   ./dcperf.sh all              setup + install + bench in one shot
#   ./dcperf.sh setup            Build image + start the long-running container
#   ./dcperf.sh install          Install django_workload (idempotent)
#   ./dcperf.sh install --force  Wipe partial state and reinstall
#   ./dcperf.sh bench            Run django_workload_default -r standalone (~35 min)
#   ./dcperf.sh shell            Drop into a shell inside the container
#   ./dcperf.sh stop             Stop the container (keeps the image)
#   ./dcperf.sh clean            Remove container + image

set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DCPERF_ROOT="$(cd "$DOCKER_DIR/../.." && pwd)"

IMAGE_NAME="${DCPERF_IMAGE:-dcperf-django_workload_default:centos9}"
CONTAINER_NAME="${DCPERF_CONTAINER:-dcperf-django_workload_default}"

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
    # Re-apply perf gates on every install/bench/shell entry. setup only
    # relaxes when creating a new container, so a host reboot (which resets
    # the sysctls to hardening defaults) + plain `start` would leave perf/
    # bpftrace silently degraded. Idempotent: no-op when already relaxed.
    relax_perf_paranoid
}

# Relax host perf gates so in-container perf/bpftrace can see kernel symbols.
relax_perf_paranoid() {
    local cur_paranoid cur_kptr
    cur_paranoid=$(sysctl -n kernel.perf_event_paranoid 2>/dev/null || echo 99)
    cur_kptr=$(sysctl -n kernel.kptr_restrict 2>/dev/null || echo 99)
    if [ "${cur_paranoid}" -le 0 ] && [ "${cur_kptr}" -eq 0 ]; then
        echo "    (already relaxed: perf_event_paranoid=${cur_paranoid} kptr_restrict=${cur_kptr})"
        return 0
    fi
    sudo sysctl -w kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0 >/dev/null
}

# django_workload_default starts with only the copymove hook. Insert a `perf`
# hook in front so we get the full 10-monitor bundle. Idempotent.
patch_jobs_yml() {
    docker exec -i "$CONTAINER_NAME" python3 - <<'PYEOF'
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

# Insert `- hook: perf` as the first hook entry. Find the `  hooks:` line
# and add the perf hook before the existing first hook.
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

    # install_siege.sh declares $SIEGE_INSTALLATION_PREFIX but its ./configure
    # call has no --prefix flag, so siege actually lands at /usr/local/bin/siege
    # (autotools default). The workload's run-siege invokes bare `siege` via
    # PATH lookup, so /usr/local/bin works -- but the script's own "already
    # installed" check (which uses the prefix variable) never hits, hence why
    # siege gets rebuilt on every `install -f`. Tracking upstream behavior
    # here: probe where siege actually is, not where the variable claims.
    if [ "${force}" = 0 ] && docker exec "${CONTAINER_NAME}" test -x \
            /usr/local/bin/siege 2>/dev/null; then
        echo "==> django_workload already installed (siege binary exists at /usr/local/bin); pass --force to reinstall"
        patch_jobs_yml
        return 0
    fi

    if [ "${force}" = 1 ]; then
        # Skip cleanup_django_workload.sh -- its `pkill java/memcache/uwsgi`
        # is unsafe under --pid=host. Just wipe build dirs; benchpress install -f
        # will redownload + rebuild.
        echo "==> wiping previous install state (benchmarks/django_workload + benchmarks/siege)"
        docker exec "${CONTAINER_NAME}" bash -c \
            'rm -rf /DCPerf/benchmarks/django_workload /DCPerf/benchmarks/siege'
    fi

    echo "==> patching jobs.yml (perf hook for django_workload_default)"
    patch_jobs_yml

    echo "==> installing django_workload (downloads cassandra-3.11.10 ~50MB + pip pkgs + builds siege; ~5-20 min)"
    local log="${DOCKER_DIR}/install.log"
    : > "${log}"
    local bp_force=""
    if [ "${force}" = 1 ]; then
        bp_force="-f"
    fi
    docker exec "${CONTAINER_NAME}" bash -c \
        "cd /DCPerf && ./benchpress_cli.py install ${bp_force} django_workload_default" \
        2>&1 | tee "${log}"

    if docker exec "${CONTAINER_NAME}" test -x /usr/local/bin/siege; then
        echo "==> install OK"
    else
        echo "==> install FAILED; see ${log}" >&2
        exit 1
    fi
}

cmd_bench() {
    require_container
    echo "==> running django_workload_default -r standalone (~35 min: 7 iters x 5 min)"
    docker exec "${CONTAINER_NAME}" bash -c \
        'cd /DCPerf && ./benchpress_cli.py run django_workload_default -r standalone'
}

cmd_all() {
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
    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
