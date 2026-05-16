#!/bin/bash
# Minimal systemctl shim for containers without systemd. Handles only the
# operations DCPerf's mediawiki install + run scripts call:
#   - systemctl start|restart|stop {mariadb,nginx}
#   - systemctl show {mariadb,mysqld,nginx}  (run.sh parses 'ActiveState=')
# Any other subcommand returns success silently to avoid breaking outer
# scripts that probe systemctl behavior (e.g. `is-enabled`) without strictly
# needing it.

set -u

cmd=${1:-}
[ $# -gt 0 ] && shift
svc=${1:-}
svc=${svc%.service}

# /run is tmpfs in containers; mysql user can't write to its root. The image
# pre-creates /run/mysqld and chowns it to mysql, so park the pid file there.
mariadb_pid_file=/run/mysqld/mariadbd.pid
mariadb_log=/var/log/mariadbd.log

is_running_mariadb() { pgrep -x mariadbd >/dev/null 2>&1; }
is_running_nginx()   { pgrep -x nginx    >/dev/null 2>&1; }

start_mariadb() {
    is_running_mariadb && return 0
    mkdir -p /run/mysqld /var/log
    chown mysql:mysql /run/mysqld 2>/dev/null || true
    # nohup + & + disown: detach from this shell so the install script's
    # next systemctl invocation (which may be from a different subshell)
    # doesn't inadvertently reap or block on the process.
    nohup mariadbd --user=mysql --datadir=/var/lib/mysql \
        --pid-file="$mariadb_pid_file" \
        >"$mariadb_log" 2>&1 &
    disown $! 2>/dev/null || true
    # Wait for the socket to be responsive. Accept both rc=0 (no auth set)
    # and "Access denied" (auth set but server is up) -- both mean crash
    # recovery is done and the server is accepting connections.
    for _ in $(seq 1 60); do
        out=$(mariadb -uroot -e ';' 2>&1 </dev/null)
        rc=$?
        if [ "$rc" -eq 0 ] || echo "$out" | grep -qi 'Access denied'; then
            return 0
        fi
        sleep 1
    done
    echo "systemctl-shim: mariadb failed to come up; see $mariadb_log" >&2
    tail -20 "$mariadb_log" >&2 || true
    return 1
}

stop_mariadb() {
    is_running_mariadb || return 0
    pkill -TERM -x mariadbd 2>/dev/null || true
    for _ in $(seq 1 20); do
        is_running_mariadb || return 0
        sleep 1
    done
    pkill -KILL -x mariadbd 2>/dev/null || true
    return 0
}

start_nginx() {
    is_running_nginx && return 0
    nginx
}

stop_nginx() {
    is_running_nginx || return 0
    nginx -s quit 2>/dev/null || pkill -TERM -x nginx 2>/dev/null || true
    for _ in $(seq 1 10); do
        is_running_nginx || return 0
        sleep 1
    done
    pkill -KILL -x nginx 2>/dev/null || true
    return 0
}

case "$cmd" in
    start)
        case "$svc" in
            mariadb|mariadbd|mysqld) start_mariadb ;;
            nginx) start_nginx ;;
            *) echo "systemctl-shim: unsupported svc '$svc' for start" >&2; exit 1 ;;
        esac
        ;;
    restart)
        case "$svc" in
            mariadb|mariadbd|mysqld) stop_mariadb && start_mariadb ;;
            nginx) stop_nginx && start_nginx ;;
            *) echo "systemctl-shim: unsupported svc '$svc' for restart" >&2; exit 1 ;;
        esac
        ;;
    stop)
        case "$svc" in
            mariadb|mariadbd|mysqld) stop_mariadb ;;
            nginx) stop_nginx ;;
            *) echo "systemctl-shim: unsupported svc '$svc' for stop" >&2; exit 1 ;;
        esac
        ;;
    show)
        # run.sh _systemd_service_status grep-extracts ActiveState=, accepts
        # active|inactive. We don't run mysqld separately; the script checks
        # BOTH mariadb and mysqld and treats EITHER active as OK.
        case "$svc" in
            mariadb|mariadbd)
                is_running_mariadb && echo "ActiveState=active" || echo "ActiveState=inactive"
                ;;
            mysqld)
                echo "ActiveState=inactive"
                ;;
            nginx)
                is_running_nginx && echo "ActiveState=active" || echo "ActiveState=inactive"
                ;;
            *)
                echo "ActiveState=inactive"
                ;;
        esac
        ;;
    daemon-reload|reset-failed|enable|disable|mask|unmask)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
