# DCPerf benchmark container -- CentOS Stream 9 base.
# Builds a runtime where Meta DCPerf benchmarks (feedsim, tao_bench, ...)
# can install and run end-to-end on hosts that aren't in DCPerf's
# official support list (e.g. Azure Linux). Every dnf package below was
# discovered by iterating through real install/run failures; do not trim
# without re-running the full pipeline.

FROM quay.io/centos/centos:stream9

ENV LANG=C.UTF-8 PIP_DISABLE_PIP_VERSION_CHECK=1

# EPEL + CRB (a.k.a. PowerTools) for the long tail of -devel packages
# pulled in by install_feedsim.sh.
RUN dnf install -y epel-release dnf-plugins-core \
 && dnf config-manager --set-enabled crb \
 && dnf clean all

# Benchpress python deps + interpreter.
RUN dnf install -y \
        git python3-click python3-pyyaml python3-tabulate python3-pip xz-devel \
 && pip3 install --no-cache-dir pandas

# Build toolchain for install_feedsim.sh (cmake/gengetopt/folly/...).
RUN dnf install -y \
        gcc gcc-c++ make wget tar xz which procps-ng

# The benchmark build tree is host-mounted and can survive a container/image
# replacement. Keep its dynamically linked runtime in the image so an install
# probe cannot succeed while LeafNodeRank immediately fails to load.
RUN dnf install -y \
        double-conversion snappy jemalloc glog gflags \
        boost-context boost-filesystem boost-program-options boost-regex \
        libicu libunwind

# DCPerf benchpress runtime expectations:
#   - hw fingerprint at run-start: dmidecode, lshw, lscpu (util-linux), pciutils, numactl
#   - the cpu-mpstat / perf hooks: sysstat, perf, bc
#   - shell helpers many hooks call: net-tools, hostname, sudo, psmisc, iproute
RUN dnf install -y \
        dmidecode lshw pciutils util-linux numactl \
        sysstat net-tools bc hostname sudo psmisc iproute

# Full perf-monitor stack: perf (PMU/sw events) + bpftrace (syscall_ebpf).
# On hypervisors that don't expose PMU these monitors still load -- their
# CSVs just contain `<not supported>` for the affected events.
RUN dnf install -y perf bpftrace

# Override sudo with a transparent passthrough. The container runs as root,
# so `sudo cmd` is equivalent to `cmd`. The CentOS Stream 9 minimal image
# ships placeholder /etc/pam.d/{system,password}-auth that include
# pam_systemd / pam_sss; in a container without logind/sssd the account
# stage fails ("PAM account management error: Authentication service cannot
# retrieve authentication info"), which kills generate_amd_perf_report.py's
# `sudo dmidecode -t 17`. Shimming sudo is cheaper than dragging in
# authselect + a profile and the container is already rootful by design.
RUN printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo \
 && chmod +x /usr/local/bin/sudo

WORKDIR /DCPerf
CMD ["sleep", "infinity"]
