#!/usr/bin/env bash
# Local-only smoke test for prep_dataset.sh's container-side staging plumbing.
# Downloads nothing. Proves: host can't write the root-owned datasets dir, but
# the stage_run/spath mechanism (container mode) can, and finalize_extract moves
# a dummy .y4m into the root-owned cuts/ correctly.
set -Eeuo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DCPERF_ROOT="$(cd "$DOCKER_DIR/../.." && pwd)"
DATASET_DIR="${DCPERF_ROOT}/benchmarks/video_transcode_bench/datasets"
CUTS_DIR="${DATASET_DIR}/cuts"
BENCH_CONTAINER="dcperf-videotranscode"
MIN_FREE_GB=60

# --- copies of the helpers under test (kept in sync with prep_dataset.sh) ---
STAGE_MODE=""
pick_stage_mode() {
    [ -n "$STAGE_MODE" ] && return 0
    if docker exec "$BENCH_CONTAINER" true >/dev/null 2>&1; then
        STAGE_MODE=container
    else
        STAGE_MODE=host
    fi
}
spath() {
    if [ "$STAGE_MODE" = container ]; then
        printf '%s' "${1/#$DCPERF_ROOT/\/DCPerf}"
    else
        printf '%s' "$1"
    fi
}
stage_run() {
    if [ "$STAGE_MODE" = container ]; then
        docker exec "$BENCH_CONTAINER" "$@"
    else
        "$@"
    fi
}
finalize_extract() {
    local tmp="$1" cuts="$2" force="$3"
    stage_run bash -c '
        set -e
        cuts="$1"; tmp="$2"; force="$3"
        mkdir -p "$cuts"
        if [ "$force" = 1 ]; then
            find "$cuts" -maxdepth 1 -name "*.y4m" -delete 2>/dev/null || true
        fi
        moved=0
        while IFS= read -r -d "" f; do
            mv -n "$f" "$cuts/" && moved=$((moved + 1)) || true
        done < <(find "$tmp" -name "*.y4m" -print0)
        rm -rf "$tmp"
        echo "MOVED=$moved"
    ' _ "$(spath "$cuts")" "$(spath "$tmp")" "$force" \
        | awk -F= '/^MOVED=/ {print $2}'
}

echo "1) host-side write into root-owned ${DATASET_DIR} (expected: FAIL)"
if mkdir -p "${DATASET_DIR}/.hosttest.$$" 2>/dev/null; then
    echo "   UNEXPECTED: host write succeeded (dir not root-owned?); cleaning up"
    rmdir "${DATASET_DIR}/.hosttest.$$"
else
    echo "   OK: host got Permission denied (this is the bug the fix routes around)"
fi

pick_stage_mode
echo "2) pick_stage_mode -> STAGE_MODE=${STAGE_MODE}"
[ "$STAGE_MODE" = container ] || { echo "   container not running; start it with dcperf.sh setup"; exit 1; }

echo "3) stage_run mkdir + df into the root-owned dir (the old failure point)"
tmp="${DATASET_DIR}/.extract.test$$"
stage_run mkdir -p "$(spath "$tmp")"
avail_kb=$(stage_run df -P "$(spath "$tmp")" | awk 'NR==2 {print $4}')
echo "   OK: mkdir succeeded; df sees $(( avail_kb / 1024 / 1024 )) GB free (need >= ${MIN_FREE_GB})"

echo "4) drop a dummy frame.y4m into tmp (as root, in container) ..."
stage_run bash -c "echo dummy > '$(spath "$tmp")/frame.y4m'"

echo "5) finalize_extract moves it into root-owned cuts/ ..."
moved=$(finalize_extract "$tmp" "$CUTS_DIR" 0)
echo "   moved=${moved}"
[ "${moved:-0}" -eq 1 ] || { echo "   FAIL: expected 1 moved"; exit 1; }

echo "6) verify host can READ the staged file, then clean up the dummy"
ls -l "${CUTS_DIR}/frame.y4m"
stage_run rm -f "$(spath "${CUTS_DIR}/frame.y4m")"
echo
echo "ALL PLUMBING CHECKS PASSED (no download performed)"
