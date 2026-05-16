# DCPerf benchmark container -- CentOS Stream 9 base, mediawiki variant.
# Mirrors docker/djangobench/Dockerfile but layers in HHVM 3.30 (the only
# HHVM version that still runs PHP, required by oss-performance-mediawiki)
# plus mariadb/nginx/memcached build deps + a systemctl shim so the install
# and run scripts' `systemctl {start,restart,show} mariadb` calls work in a
# non-systemd container.

FROM quay.io/centos/centos:stream9

ENV LANG=C.UTF-8 PIP_DISABLE_PIP_VERSION_CHECK=1

# EPEL + CRB for the long tail of -devel packages (libmemcached-awesome-devel,
# php-devel headers HHVM does NOT need but composer extensions do, etc.).
RUN dnf install -y epel-release dnf-plugins-core \
 && dnf config-manager --set-enabled crb \
 && dnf clean all

# Benchpress python deps + interpreter (mirrors feedsim/djangobench layers).
RUN dnf install -y \
        git python3-click python3-pyyaml python3-tabulate python3-pip xz-devel \
 && pip3 install --no-cache-dir pandas

# General build toolchain + benchpress runtime expectations + jq (perf-monitor
# report parsers bomb without jq).
RUN dnf install -y \
        gcc gcc-c++ make wget tar xz which procps-ng \
        dmidecode lshw pciutils util-linux numactl \
        sysstat net-tools bc hostname sudo psmisc iproute jq

# Full perf-monitor stack: perf (PMU/sw events) + bpftrace (syscall_ebpf).
RUN dnf install -y perf bpftrace

# Mediawiki-specific deps:
#   - mariadb-server: the DB tier; install_oss_performance_mediawiki.sh
#     installs the SQL fixture into it.
#   - nginx: front of the HHVM scale-out fleet.
#   - php-cli + php-common + php-devel: composer needs a working CLI php
#     (NOT hhvm) to bootstrap; CentOS 9 ships PHP 8 where json is built-in
#     core, so we don't need the (no longer existing) php-json package.
#   - libevent-devel: required by memcached 1.5.12 source build.
#   - zlib-devel: pulled in by siege configure + wrk build.
#   - autoconf/automake/libtool: siege + memcached both build from git.
#   - openssl-devel: wrk's TLS support + memcached SASL.
#   - unzip: composer unpacks zipballs.
RUN dnf install -y \
        mariadb-server \
        nginx \
        php-cli php-common php-devel php-mbstring php-xml \
        libevent-devel \
        zlib-devel \
        autoconf automake libtool \
        openssl-devel \
        unzip

# --- HHVM 3.30 ---
# pour-hhvm.sh inside the tarball detects platform, dnf-installs the runtime
# deps (libgflags, libicu60, etc.), drops binaries into /opt/local/hhvm-3.30/,
# and creates symlinks at /usr/local/bin/hhvm + /usr/local/hphpi/legacy/bin/hhvm.
# We bake it into the image so the runtime install probe finds hhvm at the
# path install_oss_performance_mediawiki.sh expects (line 11).
ARG HHVM_URL=https://github.com/facebookresearch/DCPerf/releases/download/hhvm/hhvm-3.30-multplatform-binary.tar.xz
# Last `test -x` validates the symlinks pour-hhvm.sh promised; if pour fails
# silently (it has been known to on minor distro version drift) the build
# fails here rather than at runtime install probe.
RUN set -eux; \
    curl -fsSL -o /tmp/hhvm.tar.xz "$HHVM_URL"; \
    mkdir -p /tmp/hhvm-stage; \
    tar -Jxf /tmp/hhvm.tar.xz -C /tmp/hhvm-stage; \
    cd /tmp/hhvm-stage/hhvm; \
    yes | ./pour-hhvm.sh; \
    test -x /usr/local/hphpi/legacy/bin/hhvm; \
    cd /; \
    rm -rf /tmp/hhvm-stage /tmp/hhvm.tar.xz

# pour-hhvm.sh doesn't extend ld.so.conf; HHVM crashes loading libicudata.so.60
# without LD_LIBRARY_PATH. README L43-47 documents this. Set it container-wide
# so both `hhvm --version` and benchmark runs find the shared objects.
ENV LD_LIBRARY_PATH=/opt/local/hhvm-3.30/lib

# --- MariaDB datadir init ---
# mariadbd needs an initialized datadir before it'll start. We do it once at
# image build so the systemctl shim's first `start mariadb` doesn't have to.
#
# Note: we explicitly do NOT pre-set the root password. mariadb-install-db
# creates root@localhost with the unix_socket auth plugin, which authenticates
# based on the connecting process's UID and ignores the password column. So
# install_oss_performance_mediawiki.sh's first probe
# (`mysql -uroot --password=password -e ';'`) succeeds via socket auth even
# though the password is "wrong", and set -e doesn't trip. The script's
# grant_privileges.sql later switches root@localhost to real password auth.
RUN set -eux; \
    mkdir -p /var/lib/mysql /run/mysqld; \
    chown -R mysql:mysql /var/lib/mysql /run/mysqld; \
    runuser -u mysql -- mariadb-install-db --datadir=/var/lib/mysql >/dev/null

# --- sudo + systemctl shims ---
# sudo: same passthrough used by djangobench/feedsim (container is rootful).
RUN printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo \
 && chmod +x /usr/local/bin/sudo

# systemctl: shim that translates {start,restart,stop,show} for mariadb +
# nginx into direct process control. install_oss_performance_mediawiki.sh
# and packages/mediawiki/run.sh both call systemctl directly.
COPY systemctl_shim.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl

# Raise file descriptor limit baked into the image (README troubleshooting
# section: "Too many open files" on accept4 under high client_threads). The
# dispatcher already passes --ulimit nofile=1048576:1048576 but having the
# shell-level limit set too avoids the sub-shell drop-down.
RUN printf '%s\n' \
    'root soft nofile 1048576' \
    'root hard nofile 1048576' \
    '* soft nofile 1048576' \
    '* hard nofile 1048576' \
    > /etc/security/limits.d/99-mediawiki.conf

WORKDIR /DCPerf
CMD ["sleep", "infinity"]
