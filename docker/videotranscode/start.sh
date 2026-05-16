#!/usr/bin/env bash
# Per-bench definition for video_transcode_bench (SVT-AV1 variant).
# Sourced by ../dcperf.sh. Wraps DCPerf's `video_transcode_bench_svt` job.
# The dataset (CDVL ElFuente y4m cuts) must be staged on the host first via
# ./prep_dataset.sh; bench_pre_install verifies it before benchpress install.

BENCH_JOB="video_transcode_bench_svt"
# The install script's last act is symlinking the freshly-built ffmpeg into
# benchmarks/video_transcode_bench/ffmpeg, so a working symlink is the most
# reliable install probe.
BENCH_INSTALL_PROBE="/DCPerf/benchmarks/video_transcode_bench/ffmpeg"
# Default benchpress vars give runtime=medium -> SVT level 6:6 -- decent
# coverage in ~tens of minutes. Override at run time with extra args if you
# want short (level 12:13, fast) or long (level 2:2, hours).
BENCH_RUN_ARGS=()
BENCH_INSTALL_ETA="builds x264+SVT-AV1+aom+vmaf+ffmpeg from source, ~15-30 min"
BENCH_RUN_ETA="runtime=medium (SVT level 6:6), tens of minutes; lower levels take hours"

# Ensure the dataset is staged before install completes. Runs prep_dataset.sh
# in the BACKGROUND so the 24 GB CDVL download overlaps with the ~15-30 min
# ffmpeg compile (no resource conflict: download is network-bound writing to
# datasets/, compile is CPU-bound writing to ffmpeg_sources/+ffmpeg_build/).
# bench_post_install joins the background job before declaring install done.
BENCH_PREP_PID=""

bench_pre_install() {
    local cuts="${DCPERF_ROOT}/benchmarks/video_transcode_bench/datasets/cuts"
    local count=0
    if [ -d "$cuts" ]; then
        count=$(find "$cuts" -maxdepth 1 -name '*.y4m' 2>/dev/null | wc -l)
    fi
    if [ "$count" -gt 0 ]; then
        echo "==> dataset OK: ${count} y4m file(s) in datasets/cuts/"
        return 0
    fi

    local logf="${BENCH_DIR}/prep_dataset.log"
    : > "$logf"
    echo "==> launching prep_dataset.sh in background (parallel with ffmpeg compile)"
    echo "    log: ${logf}"
    # `&` keeps the child in our process group so Ctrl-C from the user kills
    # both branches together. wget -c inside prep_dataset will resume any
    # partial zip from a prior aborted run.
    "${BENCH_DIR}/prep_dataset.sh" > "$logf" 2>&1 &
    BENCH_PREP_PID=$!
    echo "    prep_dataset PID=${BENCH_PREP_PID}; benchpress install will run concurrently"
}

bench_post_install() {
    [ -z "${BENCH_PREP_PID:-}" ] && return 0
    local logf="${BENCH_DIR}/prep_dataset.log"
    # If the child is still alive after the compile, surface a heartbeat
    # every 15s so the user can tell it's making progress (or hung).
    if kill -0 "${BENCH_PREP_PID}" 2>/dev/null; then
        echo "==> ffmpeg compile done; waiting for background prep_dataset (PID ${BENCH_PREP_PID})"
        while kill -0 "${BENCH_PREP_PID}" 2>/dev/null; do
            sleep 15
            # wget's --progress=dot uses \r-terminated lines; strip them.
            local last
            last=$(tail -20 "$logf" 2>/dev/null | tr -d '\r' \
                    | grep -vE '^[[:space:]]*$' | tail -1 | head -c 140)
            [ -n "$last" ] && echo "    [prep_dataset] ${last}"
        done
    else
        echo "==> prep_dataset already finished while compile was running"
    fi
    # Reap, capture exit code without tripping set -e.
    set +e
    wait "${BENCH_PREP_PID}"
    local rc=$?
    set -e
    BENCH_PREP_PID=""
    if [ "$rc" -ne 0 ]; then
        cat >&2 <<EOF

ERROR: prep_dataset failed (rc=$rc). See ${logf}
ffmpeg compile may have completed but the dataset isn't staged, so the
bench run would crash. After fixing the prep failure, rerun:
  ${BENCH_DIR}/prep_dataset.sh
to retry just the dataset (no need to recompile ffmpeg).
EOF
        exit 1
    fi
    echo "==> prep_dataset finished OK"
}

# Replace the default cpu-mpstat hook on video_transcode_bench_svt with the
# full `perf` bundle (mpstat / memstat / netstat / cpufreq_* / perfstat /
# topdown / power / ctxsw / syscall_ebpf). Idempotent.
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
          - 'benchmarks/video_transcode_bench/video_transcode_bench_results.txt'
          - 'benchmarks/video_transcode_bench/perf.data'"""
new = """  hooks:
    - hook: perf
    - hook: copymove
      options:
        is_move: true
        after:
          - 'benchmarks/video_transcode_bench/video_transcode_bench_results.txt'
          - 'benchmarks/video_transcode_bench/perf.data'"""

# Only touch the video_transcode_bench_svt entry (not _aom / _x264).
m = re.search(r'(?ms)^- name: video_transcode_bench_svt\n.*?(?=^- name:|\Z)', s)
if not m:
    sys.exit('jobs.yml: video_transcode_bench_svt entry not found')
block = m.group(0)

if old in block:
    new_block = block.replace(old, new, 1)
    p.write_text(s.replace(block, new_block, 1))
    print('jobs.yml: patched cpu-mpstat -> perf for video_transcode_bench_svt')
elif '- hook: perf' in block:
    print('jobs.yml: already patched (perf hook present)')
else:
    sys.exit('jobs.yml: video_transcode_bench_svt hooks block does not match either '
             'the upstream layout or the patched layout; edit manually')
PYEOF
}

# Wipe the build artifacts but keep datasets/cuts/ -- the y4m corpus is many
# GB and the user explicitly staged it via prep_dataset.sh. cleanup_*.sh
# upstream also preserves cuts/, but we list paths explicitly so a future
# upstream change can't accidentally nuke staged data.
bench_force_cleanup() {
    docker exec "$BENCH_CONTAINER" bash -c '
        cd /DCPerf/benchmarks/video_transcode_bench 2>/dev/null || exit 0
        rm -rf ffmpeg_sources ffmpeg_build resized_clips aom-testing tools \
               ffmpeg generate_commands_all.py run.sh \
               ffmpeg-svt-1p-run-all-paral.sh ffmpeg-aom-2p-run-all-paral.sh \
               ffmpeg-x264-1p-run-all-paral.sh \
               time_enc_*.log video_transcode_bench_results.txt perf.data 2>/dev/null
        true
    '
}
