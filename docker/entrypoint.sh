#!/usr/bin/env bash
# Entrypoint of the TrinityCore image.
#
#   worldserver [args]   start the worldserver (default)
#   login [args]         start the branch's login server: bnetserver, or authserver on 3.3.5
#   bnetserver|authserver [args]
#   extract              extract the server data from a client mounted at /client into /data
#   anything else        run as given (bash, mapextractor, ...)
#
# Config comes from $TC_CONF_DIR/*.conf, overridden by TC_* environment variables
# (TrinityCore maps `LoginREST.ExternalAddress` to TC_LOGIN_REST_EXTERNAL_ADDRESS) and by
# any *.conf file mounted into $TC_CONF_DIR/<server>.conf.d/.
set -euo pipefail

log() { echo "[tc-entrypoint] $*" >&2; }

# Connection strings are TrinityCore's "host;port;user;password;database".
db_name() {
    local name
    IFS=';' read -r _ _ _ _ name _ <<<"$1"
    echo "$name"
}

# sql <connection> <query> [--in-db]: one query, on the server or inside the named database.
sql() {
    local host port user pass name
    IFS=';' read -r host port user pass name _ <<<"$1"
    if [ "${3:-}" != "--in-db" ]; then
        name=
    fi
    MYSQL_PWD="$pass" mysql -h"$host" -P"$port" -u"$user" --batch --skip-column-names -e "$2" $name
}

wait_for_mysql() {
    local info=$1 tries=0
    until sql "$info" 'SELECT 1' >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -ge 60 ]; then
            log "MySQL behind '${info%%;*}' still unreachable after 2 minutes"
            exit 1
        fi
        sleep 2
    done
}

table_count() {
    sql "$1" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$(db_name "$1")'" 2>/dev/null || echo 0
}

# The worldserver fills an empty world (and hotfixes) database from the TDB release files in its
# working directory. The image carries them compressed; unpack them only when they are needed and
# drop them again once the databases are filled.
prepare_world() {
    [ -n "${TC_WORLD_DATABASE_INFO:-}" ] || return 0
    wait_for_mysql "$TC_WORLD_DATABASE_INFO"

    local infos=("$TC_WORLD_DATABASE_INFO") needed=0
    if grep -q '^HotfixDatabaseInfo' "$TC_CONF_DIR/worldserver.conf" && [ -n "${TC_HOTFIX_DATABASE_INFO:-}" ]; then
        infos+=("$TC_HOTFIX_DATABASE_INFO")
    fi
    for info in "${infos[@]}"; do
        if [ "$(table_count "$info")" -eq 0 ]; then
            needed=1
        fi
    done

    if [ "$needed" -eq 1 ]; then
        if ! ls TDB_full_*.sql >/dev/null 2>&1; then
            log "unpacking $(basename /opt/tdb/*.7z) for the first database fill"
            # Debian's 7zip package installs `7z`, Ubuntu's only `7zz`.
            local sevenzip
            sevenzip=$(command -v 7z || command -v 7zz)
            "$sevenzip" x -y /opt/tdb/*.7z >/dev/null
        fi
    else
        rm -f TDB_full_*.sql
    fi
}

# The login server reads the realm list the worldserver creates, so it waits for it, then points
# the realm at the address clients should use.
prepare_login() {
    [ -n "${TC_LOGIN_DATABASE_INFO:-}" ] || return 0
    wait_for_mysql "$TC_LOGIN_DATABASE_INFO"

    local waited=0
    until [ "$(sql "$TC_LOGIN_DATABASE_INFO" 'SELECT COUNT(*) FROM realmlist' --in-db 2>/dev/null || echo 0)" -gt 0 ]; do
        if [ "$waited" -eq 0 ]; then
            log "waiting for the worldserver to create the auth database"
        fi
        waited=1
        sleep 5
    done

    if [ -n "${REALM_ADDRESS:-}" ]; then
        local id=${REALM_ID:-1}
        sql "$TC_LOGIN_DATABASE_INFO" "UPDATE realmlist SET
                address = '${REALM_ADDRESS}',
                localAddress = '${REALM_LOCAL_ADDRESS:-$REALM_ADDRESS}',
                port = ${REALM_PORT:-8085}${REALM_NAME:+, name = '$REALM_NAME'}
            WHERE id = ${id}" --in-db
        log "realm ${id} -> ${REALM_ADDRESS}:${REALM_PORT:-8085}"
        export TC_LOGIN_REST_EXTERNAL_ADDRESS=${TC_LOGIN_REST_EXTERNAL_ADDRESS:-$REALM_ADDRESS}
        export TC_LOGIN_REST_LOCAL_ADDRESS=${TC_LOGIN_REST_LOCAL_ADDRESS:-${REALM_LOCAL_ADDRESS:-$REALM_ADDRESS}}
    fi
}

extract() {
    local client=/client vmap_input
    if [ ! -d "$client/Data" ]; then
        log "mount the client install (the folder that holds Data/) at $client"
        exit 1
    fi
    cd /data

    # 3.3.5 reads MPQ archives from Data/; the CASC branches open <client>/Data themselves.
    if [ "$TC_BRANCH" = "3.3.5" ]; then
        vmap_input="$client/Data"
    else
        vmap_input="$client"
    fi

    mapextractor -i "$client" -o /data
    # The extractors exit 0 even when they could not open the client.
    if [ -z "$(ls -A /data/maps 2>/dev/null)" ]; then
        log "mapextractor wrote no maps, see its output above"
        exit 1
    fi
    if [ "${EXTRACT_VMAPS:-1}" = "1" ]; then
        vmap4extractor -l -d "$vmap_input"
        mkdir -p vmaps
        vmap4assembler Buildings vmaps
        rm -rf Buildings
    fi
    if [ "${EXTRACT_MMAPS:-0}" = "1" ]; then
        mmaps_generator --threads "${EXTRACT_THREADS:-$(nproc)}"
    fi
    log "done: $(du -sh /data | cut -f1) in /data"
}

# Without a terminal the servers' stdout is block-buffered and `docker logs` lags far behind.
run_server() {
    if [ -t 1 ]; then
        exec "$@"
    fi
    exec stdbuf -oL -eL "$@"
}

command=${1:-worldserver}
[ "$#" -gt 0 ] && shift

case "$command" in
    worldserver)
        prepare_world
        # Without a terminal the console reads end-of-file at once, which shuts the server down.
        if [ ! -t 0 ]; then
            export TC_CONSOLE_ENABLE=0
        fi
        # The worldserver truncates its packet log on start; `World-%Y%m%d-%H%M%S.pkt` keeps one per start.
        if [ -n "${TC_PACKET_LOG_FILE:-}" ]; then
            TC_PACKET_LOG_FILE=$(date -u +"$TC_PACKET_LOG_FILE")
            export TC_PACKET_LOG_FILE
            log "packet log: /logs/$TC_PACKET_LOG_FILE"
        fi
        run_server worldserver "$@"
        ;;
    login)
        prepare_login
        if command -v bnetserver >/dev/null; then
            run_server bnetserver "$@"
        fi
        run_server authserver "$@"
        ;;
    bnetserver|authserver)
        prepare_login
        run_server "$command" "$@"
        ;;
    extract)
        extract
        ;;
    *)
        exec "$command" "$@"
        ;;
esac
