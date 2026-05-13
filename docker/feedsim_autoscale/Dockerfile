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

WORKDIR /DCPerf
CMD ["sleep", "infinity"]
