#!/usr/bin/env bash
# Stage the CDVL ElFuente y4m cuts into DCPerf's expected dataset path.
# Invoke this on the HOST. The dataset dir under benchmarks/ is normally
# root-owned (created by benchpress install inside the container via the bind
# mount), so the host user usually can't write there -- this script therefore
# delegates every write (mkdir/download/extract/move) into the bench container
# when it's running, and only falls back to host-side writes if it isn't.
# So either run `./dcperf.sh videotranscode setup` first (recommended), or make
# DATASET_DIR host-writable and ensure host 7za is installed.
#
# Usage:
#   ./prep_dataset.sh                          # download from DEFAULT_URL + extract
#   ./prep_dataset.sh <NETFLIX_ElFuente_for_SITI_y4m.zip>   # use local zip
#   ./prep_dataset.sh <https://...>            # download from custom URL + extract
#   ./prep_dataset.sh --force [<zip|url>]      # re-extract even if cuts/ populated
#   ./prep_dataset.sh --check                  # just report what's currently staged
#   ./prep_dataset.sh --download-only [<url>]  # download only, do not extract
#
# DEFAULT_URL points at the CDVL "ElFuente Shots for SI/TI, Y4M format,
# 1080p 29.96fps" download. The URL has a per-account GUID baked in but
# returns the zip on GET requests without cookies (confirmed via Range
# probe -- HTTP 206 with valid zip magic). If CDVL invalidates this URL
# later, log in at https://www.cdvl.org/, copy the new wget link from the
# dataset page, and either edit DEFAULT_URL or pass the URL as an arg.
#
# Final layout (relative to DCPerf root):
#   benchmarks/video_transcode_bench/datasets/
#       NETFLIX_ElFuente_for_SITI_y4m.zip   # cached zip (delete after extract)
#       cuts/*.y4m                          # what DCPerf actually consumes

set -Eeuo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DCPERF_ROOT="$(cd "$DOCKER_DIR/../.." && pwd)"
DATASET_DIR="${DCPERF_ROOT}/benchmarks/video_transcode_bench/datasets"
CUTS_DIR="${DATASET_DIR}/cuts"
DEFAULT_URL="https://www.cdvl.org/download/GetFileDownload/3060/b7db722a-0b36-447f-ae23-29bf15dd33d0/"
DEFAULT_ZIP_NAME="NETFLIX_ElFuente_for_SITI_y4m.zip"
# Container used as a fallback when host lacks p7zip. Matches dcperf.sh's
# BENCH_CONTAINER for videotranscode (BENCH_IMAGE convention: "dcperf-<bench>").
BENCH_CONTAINER="dcperf-videotranscode"

# Disk we need: zip ~24 GB, extraction roughly 1:1 (y4m is uncompressed). The
# bench also wants ~5 GB for ffmpeg + libs build under benchmarks/. Headroom.
MIN_FREE_GB=60

usage() {
    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

current_count() {
    [ -d "$CUTS_DIR" ] || { echo 0; return; }
    find "$CUTS_DIR" -maxdepth 1 -name '*.y4m' 2>/dev/null | wc -l
}

current_size_human() {
    [ -d "$CUTS_DIR" ] || { echo 0; return; }
    du -sh "$CUTS_DIR" 2>/dev/null | awk '{print $1}'
}

cmd_check() {
    local n
    n=$(current_count)
    if [ "$n" -gt 0 ]; then
        echo "==> ${n} y4m file(s) in ${CUTS_DIR} (total $(current_size_human))"
        find "$CUTS_DIR" -maxdepth 1 -name '*.y4m' -printf '    %f  %s bytes\n' \
            | sort
    else
        echo "==> dataset NOT staged (no y4m in ${CUTS_DIR})"
    fi
}

# --- Staging side: host vs container ----------------------------------------
# The dataset dir under benchmarks/ is normally root-owned -- benchpress
# install creates benchmarks/video_transcode_bench/ inside the container
# through the /DCPerf bind mount, so the host user can't mkdir/wget/extract
# into datasets/. Run every write-side step (mkdir, free-space check, download,
# extract, move) wherever it can actually write. Prefer the container: it's
# root on the same bind mount and its Dockerfile bakes in wget + curl + p7zip.
# Fall back to the host only when the container isn't running (then the host
# itself needs write access to DATASET_DIR and its own 7za).
STAGE_MODE=""
pick_stage_mode() {
    [ -n "$STAGE_MODE" ] && return 0
    if docker exec "$BENCH_CONTAINER" true >/dev/null 2>&1; then
        STAGE_MODE=container
        echo "    (staging inside ${BENCH_CONTAINER}: writes land as root on the bind mount)"
    else
        STAGE_MODE=host
        echo "    (container ${BENCH_CONTAINER} not running; staging on host --"
        echo "     needs write access to ${DATASET_DIR} and a host 7za)"
    fi
}

# spath <hostpath>: translate a host path under DCPERF_ROOT to the path the
# staging side sees (/DCPerf-rooted in container mode, unchanged on host).
spath() {
    if [ "$STAGE_MODE" = container ]; then
        printf '%s' "${1/#$DCPERF_ROOT/\/DCPerf}"
    else
        printf '%s' "$1"
    fi
}

# stage_run <argv...>: run a command on the staging side. argv form (not a
# bash -c string) so callers don't fight quoting; pass paths through spath.
stage_run() {
    if [ "$STAGE_MODE" = container ]; then
        docker exec "$BENCH_CONTAINER" "$@"
    else
        "$@"
    fi
}

# Extract $zip into $outdir with 7za on the staging side. The CDVL zip's
# non-standard header makes 7za print a warning and exit 1; that's harmless, so
# callers tolerate exit 1 and only treat >=2 as a hard failure. Exit 127 means
# no 7za on the staging side.
sevenz_x() {
    local zip="$1" outdir="$2"
    if ! stage_run bash -c 'command -v 7za >/dev/null 2>&1'; then
        cat >&2 <<EOF
ERROR: 7za not available on the staging side (STAGE_MODE=${STAGE_MODE}).
The CDVL zip has a non-standard header; unzip rejects it but 7za tolerates it.
Easiest fix: start the bench container (its Dockerfile bakes in p7zip), re-run:
      ${DOCKER_DIR}/../dcperf.sh videotranscode setup
      ${BASH_SOURCE[0]}
Or install on the host:  sudo dnf install -y p7zip p7zip-plugins
EOF
        return 127
    fi
    stage_run 7za x -y -o"$(spath "$outdir")" "$(spath "$zip")"
}

# Move every *.y4m anywhere under $tmp into $cuts, then rm -rf $tmp -- all on
# the staging side, so the side that owns the freshly-extracted files (root in
# container mode) is also the one that mv/rm's them. If $force=1, wipe any
# pre-existing y4m in $cuts first. Echoes the number of files moved.
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

check_free_space() {
    local target="$1" avail_kb avail_gb
    stage_run mkdir -p "$(spath "$target")"
    avail_kb=$(stage_run df -P "$(spath "$target")" | awk 'NR==2 {print $4}')
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [ "$avail_gb" -lt "$MIN_FREE_GB" ]; then
        echo "ERROR: only ${avail_gb} GB free at ${target}, need >= ${MIN_FREE_GB} GB" >&2
        echo "       (zip ~24 GB + extracted y4m ~24 GB + build dir headroom)" >&2
        exit 1
    fi
    echo "    ${avail_gb} GB free at ${target} (need >= ${MIN_FREE_GB} GB)"
}

# Download $url to $out. Always defers to wget -c (or curl -C -) -- they
# already short-circuit when the local file matches the server's Content-
# Length, so partial files resume and complete files cost only one HEAD.
# Don't try to guess completeness from local size+magic; that's what caused
# a 4.8 GB partial to be mistaken for a finished 24 GB download.
download_zip() {
    local url="$1" out="$2" out_s
    out_s="$(spath "$out")"
    stage_run mkdir -p "$(spath "$(dirname "$out")")"
    check_free_space "$(dirname "$out")"

    echo "==> fetching $url"
    echo "    -> $out (wget -c resumes if partial)"
    # Tolerate a non-zero exit from the downloader (|| true): a dead CDVL link
    # 404s, and under `set -e` that would abort here before the size/magic
    # checks below can print the actionable "link may have expired" guidance.
    if stage_run bash -c 'command -v wget >/dev/null 2>&1'; then
        stage_run wget -c --tries=3 --read-timeout=60 -O "$out_s" "$url" || true
    elif stage_run bash -c 'command -v curl >/dev/null 2>&1'; then
        stage_run curl -L --fail --retry 3 --retry-delay 5 -C - -o "$out_s" "$url" || true
    else
        echo "ERROR: neither wget nor curl available on the staging side" >&2
        exit 1
    fi

    # Post-download sanity. Login-page redirects are typically <100 KB HTML;
    # the real zip is ~24 GB. Anything under 1 GB is suspect. stat returns 0
    # for a missing file, which trips the same guard.
    local size magic
    size=$(stage_run stat -c %s "$out_s" 2>/dev/null || echo 0)
    if [ "$size" -lt 1073741824 ]; then
        echo "ERROR: downloaded file is suspiciously small (<1 GB); CDVL link may have expired." >&2
        echo "       Get a fresh link from https://www.cdvl.org/ (search for" >&2
        echo "       'ElFuente Shots for SI/TI') and pass it as the first arg." >&2
        exit 1
    fi
    magic=$(stage_run bash -c "head -c 2 '$out_s' | tr -d '\0'" || true)
    if [ "$magic" != "PK" ]; then
        echo "ERROR: downloaded file is not a zip (magic '$magic'). Likely a login redirect." >&2
        exit 1
    fi
    echo "==> have zip: $(stage_run du -h "$out_s" | cut -f1)"
}

cmd_stage() {
    local force="$1" zip_or_url="$2"
    pick_stage_mode

    local zip
    if [ -z "$zip_or_url" ]; then
        # Default: download from baked-in CDVL URL into datasets/
        zip="${DATASET_DIR}/${DEFAULT_ZIP_NAME}"
        download_zip "$DEFAULT_URL" "$zip"
    elif [[ "$zip_or_url" =~ ^https?:// ]]; then
        zip="${DATASET_DIR}/${DEFAULT_ZIP_NAME}"
        download_zip "$zip_or_url" "$zip"
    else
        zip="$zip_or_url"
        if [ ! -f "$zip" ]; then
            echo "ERROR: zip not found: $zip" >&2
            exit 1
        fi
        # File-magic sanity for caller-supplied zips: rules out "wget got the
        # login page and saved HTML as .zip".
        local magic
        magic=$(head -c 2 "$zip" | tr -d '\0' || true)
        if [ "$magic" != "PK" ]; then
            echo "ERROR: $zip is not a zip archive (magic bytes: '$magic')" >&2
            echo "       If you wget'd it from CDVL without cookies, you likely" >&2
            echo "       got an HTML page instead. Re-download or rerun this" >&2
            echo "       script with no args to use the baked-in URL." >&2
            exit 1
        fi
    fi

    local existing
    existing=$(current_count)
    if [ "$existing" -gt 0 ] && [ "$force" = 0 ]; then
        echo "==> ${existing} y4m file(s) already in ${CUTS_DIR}; skipping extract"
        echo "    (pass --force to re-extract)"
        cmd_check
        return 0
    fi

    echo "==> staging dataset from $(basename "$zip") ($(stage_run du -h "$(spath "$zip")" | cut -f1))"
    check_free_space "$CUTS_DIR"

    # Extract to a sibling tmp dir, then move y4m files into cuts/. Keeps the
    # zip's frames_y4m/ wrapper out of cuts/ -- DCPerf's run.sh enumerates the
    # top-level cuts/ only, so nested dirs would be invisible.
    local tmp
    tmp="${DATASET_DIR}/.extract.$$"
    stage_run mkdir -p "$(spath "$tmp")"
    # README warns the zip header is malformed; 7za prints a warning but
    # extracts contents fine. Tolerate exit code 1 (warning), bail on >=2.
    set +e
    sevenz_x "$zip" "$tmp"
    local rc=$?
    set -e
    if [ "$rc" -ge 2 ]; then
        stage_run rm -rf "$(spath "$tmp")"
        echo "ERROR: 7za failed with exit $rc; aborting" >&2
        exit 1
    fi

    local moved
    moved=$(finalize_extract "$tmp" "$CUTS_DIR" "$force")
    if [ -z "$moved" ] || [ "$moved" -eq 0 ]; then
        echo "ERROR: zip extracted but no .y4m files found inside; check zip contents" >&2
        exit 1
    fi
    echo "==> staged ${moved} y4m file(s) into ${CUTS_DIR}"
    echo "    (zip cached at $zip; rm it once you're sure you won't need to re-extract)"
    cmd_check
}

# --- Dispatch ---
force=0
download_only=0
while :; do
    case "${1:-}" in
        -h|--help|help)
            usage; exit 0 ;;
        --check|check)
            cmd_check; exit 0 ;;
        --force|-f)
            force=1; shift ;;
        --download-only)
            download_only=1; shift ;;
        *)
            break ;;
    esac
done

if [ "$download_only" = 1 ]; then
    pick_stage_mode
    url="${1:-$DEFAULT_URL}"
    download_zip "$url" "${DATASET_DIR}/${DEFAULT_ZIP_NAME}"
    exit 0
fi

cmd_stage "$force" "${1:-}"
