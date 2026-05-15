# DCPerf benchmark container -- CentOS Stream 9 base, django_workload variant.
# Mirrors docker/feedsim_autoscale/Dockerfile but adds the JDK + memcached +
# screen + autoconf chain that install_django_workload_x86_64_centos9.sh and
# install_siege.sh expect. Pre-installing here lets the install step inside
# the container skip its dnf calls (they become idempotent no-ops).

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
# feedsim run-end report parser bombs without it).
RUN dnf install -y \
        gcc gcc-c++ make wget tar xz which procps-ng \
        dmidecode lshw pciutils util-linux numactl \
        sysstat net-tools bc hostname sudo psmisc iproute jq

# Full perf-monitor stack: perf (PMU/sw events) + bpftrace (syscall_ebpf).
RUN dnf install -y perf bpftrace

# Django-specific deps:
#   - memcached + libmemcached-awesome-devel: pylibmc pip pkg builds against
#     libmemcached headers; memcached itself is run by run.sh.
#   - zlib-devel: pulled in by several pip pkgs and by siege configure.
#   - screen: install_django_workload boots cassandra under `screen -d -m`.
#   - python3-devel: native pip pkgs (numpy, psutil, uwsgi, ...) need headers.
#   - java-1.8.0-openjdk-devel: Cassandra 3.11.10 only supports JDK 8.
#   - autoconf/automake: siege builds from git via ./bootstrap + autoreconf.
#   - nmap-ncat: run.sh's "wait for cassandra / django" probes call `nc -z`;
#     without it, the wait loops spin until their timeouts hit.
RUN dnf install -y \
        memcached libmemcached-awesome-devel zlib-devel screen \
        python3-devel \
        java-1.8.0-openjdk-devel \
        autoconf automake \
        nmap-ncat

# run-memcached defaults to `-u memcache` (no 'd'), but the memcached RPM's
# preinstall script creates a `memcached` user (with 'd'). Without this
# alias, memcached fails immediately ("can't find the user memcache to
# switch to") and uwsgi can't reach the cache.
RUN useradd -r -g memcached -s /sbin/nologin memcache

WORKDIR /DCPerf
CMD ["sleep", "infinity"]
