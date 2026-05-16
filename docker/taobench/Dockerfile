# DCPerf benchmark container -- CentOS Stream 9 base, tao_bench variant.
# Mirrors docker/feedsim/Dockerfile but layers in folly's build deps so
# install_tao_bench_x86_64.sh can compile openssl + libevent + folly +
# memcached + memtier_benchmark from source. No HHVM / no DB / no systemd
# needed -- tao_bench server and client are both standalone binaries.

FROM quay.io/centos/centos:stream9

ENV LANG=C.UTF-8 PIP_DISABLE_PIP_VERSION_CHECK=1

# EPEL + CRB for the long tail of -devel packages folly's getdeps and
# install_tao_bench_x86_64.sh pull in (gflags-devel-2.2.2 lives in EPEL,
# double-conversion-devel and libsodium-devel live in CRB).
RUN dnf install -y epel-release dnf-plugins-core \
 && dnf config-manager --set-enabled crb \
 && dnf clean all

# Benchpress python deps + interpreter (mirrors feedsim/djangobench layers).
# Pin numpy < 2: folly v2024.06.24.00 bundles a Boost.Python build whose
# numpy bindings use `PyArray_Descr::elsize` directly. That field was made
# private in numpy 2.0, so the boost build (triggered by folly's getdeps)
# fails with "no member named 'elsize'". README's troubleshooting section
# documents this. Pandas otherwise pulls numpy 2.x as a dep, so we install
# the pinned numpy before pandas to keep the resolver from upgrading.
RUN dnf install -y \
        git python3-click python3-pyyaml python3-tabulate python3-pip xz-devel \
 && pip3 install --no-cache-dir 'numpy<2' \
 && pip3 install --no-cache-dir pandas

# General build toolchain + benchpress runtime expectations + jq.
RUN dnf install -y \
        gcc gcc-c++ make wget tar xz which procps-ng \
        dmidecode lshw pciutils util-linux numactl \
        sysstat net-tools bc hostname sudo psmisc iproute jq

# Full perf-monitor stack: perf (PMU/sw events) + bpftrace (syscall_ebpf).
RUN dnf install -y perf bpftrace

# Tao_bench specific deps (mirrors install_tao_bench_x86_64.sh L41-47 dnf
# block exactly). gflags-devel-2.2.2 is version-pinned upstream; CentOS
# Stream 9 ships 2.2.2-9.el9 which matches. glog-devel-0.3.5-15.el9 is the
# version the installer hardcodes for el9.
#   - cmake/iperf3/autoconf/automake/libtool/perl/patch: build chain
#   - libevent-devel: linked at memcached configure time
#   - openssl + openssl-devel: server TLS (--enable-tls is default for
#     tao_bench_server). The installer ALSO rebuilds openssl 3.3.2 from
#     source under benchmarks/tao_bench/build-deps/; the system openssl
#     here covers tools and configure-time probes.
#   - zlib/bzip2/xz/lz4/zstd/snappy-devel: folly compression deps
#   - libaio/libunwind/double-conversion/libsodium/fmt/pcre-devel:
#     folly direct deps
#   - python3-devel: folly's python bindings during getdeps build
RUN dnf install -y \
        cmake iperf3 autoconf automake libtool perl patch \
        libevent-devel openssl openssl-devel \
        zlib-devel bzip2-devel xz-devel lz4-devel libzstd-devel \
        snappy-devel libaio-devel libunwind-devel \
        double-conversion-devel libsodium-devel \
        gflags-devel-2.2.2 fmt-devel pcre-devel \
        python3-devel glog-devel-0.3.5-15.el9

# Override sudo with a transparent passthrough. install_tao_bench_x86_64.sh
# uses `sudo` for {ln,rm,dnf install} -- in a rootful container these are
# already root, and real sudo on this base image fails PAM (no logind/sssd).
# Same shim used by docker/{feedsim,djangobench,mediawiki}/Dockerfile.
RUN printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo \
 && chmod +x /usr/local/bin/sudo

# Disable git's "dubious ownership" rejection container-wide. /DCPerf is
# bind-mounted from a host-owned path (uid != root), and folly's getdeps
# runs `git apply` from within the extracted source tree -- git walks
# upward looking for a .git, finds /DCPerf/.git, sees the host-owned
# directory and refuses to operate. Marking all paths safe is fine here
# because the container is already isolated and rootful.
RUN git config --system --add safe.directory '*'

# Numactl probes /sys/devices/system/node/online to discover NUMA. With
# --pid=host the container sees host's numa topology; bind_cpu=1 and
# bind_mem=1 (defaults) on a multi-socket host therefore work as upstream
# intends. No further config needed in the image.

# Raise file descriptor limit baked into the image: a high-core
# tao_bench_standalone run easily opens >100K connections (each client
# thread × clients_per_thread). Dispatcher passes --ulimit nofile=1048576
# but having the shell-level limit set too avoids the sub-shell drop-down.
RUN printf '%s\n' \
    'root soft nofile 1048576' \
    'root hard nofile 1048576' \
    '* soft nofile 1048576' \
    '* hard nofile 1048576' \
    > /etc/security/limits.d/99-taobench.conf

WORKDIR /DCPerf
CMD ["sleep", "infinity"]
