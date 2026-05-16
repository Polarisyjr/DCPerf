# DCPerf benchmark container -- CentOS Stream 9 base, video_transcode_bench variant.
# Same baseline as docker/feedsim and docker/djangobench, plus the ffmpeg
# build chain (cmake/meson/nasm/clang) that install_video_transcode_bench.sh
# uses to compile x264, SVT-AV1, libaom, vmaf, and ffmpeg n7.0.1 from source.
# Dataset (CDVL ElFuente y4m cuts) is NOT baked in; prep it on the host with
# ./prep_dataset.sh before running install -- see start.sh's bench_pre_install.

FROM quay.io/centos/centos:stream9

ENV LANG=C.UTF-8 PIP_DISABLE_PIP_VERSION_CHECK=1

# EPEL + CRB for the long tail of -devel packages.
RUN dnf install -y epel-release dnf-plugins-core \
 && dnf config-manager --set-enabled crb \
 && dnf clean all

# Benchpress python deps + interpreter.
RUN dnf install -y \
        git python3-click python3-pyyaml python3-tabulate python3-pip xz-devel \
 && pip3 install --no-cache-dir pandas

# General build toolchain + benchpress runtime expectations + jq (the
# benchpress run-end report parser bombs without it).
RUN dnf install -y \
        gcc gcc-c++ make wget tar xz which procps-ng \
        dmidecode lshw pciutils util-linux numactl \
        sysstat net-tools bc hostname sudo psmisc iproute jq

# Full perf-monitor stack: perf (PMU/sw events) + bpftrace (syscall_ebpf).
RUN dnf install -y perf bpftrace

# video_transcode_bench-specific deps -- mirrors the apt list in
# install_video_transcode_bench.sh, with CentOS package names:
#   - cmake / meson / ninja-build: x264 / SVT-AV1 / libaom / vmaf build systems.
#   - nasm: x264 / aom asm.
#   - clang: install script forces clang for ffmpeg + encoders (CC=clang).
#   - autoconf / automake / flex / bison / patch / pkg-config: ffmpeg + libs.
#   - python3-devel: meson + vmaf python bindings.
#   - parallel: GNU parallel; aom-testing's run scripts pipeline through it.
#   - p7zip + p7zip-plugins: README-mandated decompressor for the CDVL
#     ElFuente zip (its non-standard header trips unzip but 7za tolerates it).
#     Installed in the container too so we can re-extract from inside if the
#     host doesn't have 7za. Plugins package provides the 7z codec.
#   - time: install script + run.sh both call /usr/bin/time -v for memory stats.
RUN dnf install -y \
        cmake meson ninja-build nasm clang \
        autoconf automake flex bison patch pkg-config \
        python3-devel \
        parallel p7zip p7zip-plugins \
        time

# install_video_transcode_bench.sh sprinkles `sudo dnf install` for its system
# deps -- and centos:stream9's minimal PAM config breaks sudo even for root
# ("PAM account management error: Authentication service cannot retrieve
# authentication info"). All those deps are already installed above and we
# run as root anyway, so shadow /usr/bin/sudo with a pass-through wrapper at
# /usr/local/bin/sudo (PATH-precedence). Doesn't affect feedsim/django since
# their install scripts don't call sudo.
RUN cat > /usr/local/bin/sudo <<'EOF' \
 && chmod +x /usr/local/bin/sudo
#!/bin/sh
# Pass-through sudo wrapper -- strips common flags then execs the command.
# We're already root, so auth is moot. Handles `sudo cmd ...`, `sudo -n cmd`,
# `sudo -E cmd`, `sudo -u user cmd`. Falls through on unknown flags.
while [ $# -gt 0 ]; do
    case "$1" in
        -[bEHnPSiv]) shift ;;
        --non-interactive|--preserve-env|--background) shift ;;
        -u|--user) shift; shift ;;
        --user=*) shift ;;
        --) shift; break ;;
        -*) break ;;
        *) break ;;
    esac
done
exec "$@"
EOF

WORKDIR /DCPerf
CMD ["sleep", "infinity"]
