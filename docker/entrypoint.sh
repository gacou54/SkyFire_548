#!/usr/bin/env bash
#
# This file is part of Project SkyFire https://www.projectskyfire.org.
# See COPYRIGHT file for Copyright information
#
# Container entrypoint for worldserver / authserver.
#
# The effective config is rendered on every start into /opt/skyfire/run from
#   /opt/skyfire/etc/<server>.conf       (if you mount one), otherwise
#   /opt/skyfire/etc/<server>.conf.dist
# then container defaults are applied, then SFCONF_* overrides:
#   SFCONF_<Key with "." written as "__">=<value>
#   e.g. SFCONF_WorldDatabase__AutoSetup=1  ->  WorldDatabase.AutoSetup = "1"
#
# Any other command (bash, mapextractor, ...) is executed as-is.

set -euo pipefail

SF_HOME=/opt/skyfire
SF_ETC=$SF_HOME/etc
SF_RUN=$SF_HOME/run

DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-skyfire}
DB_PASSWORD=${DB_PASSWORD:-skyfire}
DB_AUTH=${DB_AUTH:-auth}
DB_WORLD=${DB_WORLD:-world}
DB_CHARACTERS=${DB_CHARACTERS:-characters}

log() { echo "[entrypoint] $*" >&2; }

# set_conf <file> <key> <value>: replace "key = ..." or append it.
set_conf() {
    local file=$1 value=$3
    [[ $value == \"*\" ]] || value="\"$value\""
    K="$2" V="$value" awk '
        BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; found = 0 }
        {
            if ($0 !~ /^[[:space:]]*#/ && (eq = index($0, "=")) > 0) {
                name = substr($0, 1, eq - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
                if (name == k) { print k " = " v; found = 1; next }
            }
            print
        }
        END { if (!found) print k " = " v }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

render_config() {
    local name=$1; shift
    local out=$SF_RUN/$name.conf base

    if [[ -f $SF_ETC/$name.conf ]]; then
        base=$SF_ETC/$name.conf
    else
        base=$SF_ETC/$name.conf.dist
    fi
    log "Rendering $out from $base"
    mkdir -p "$SF_RUN"
    cp "$base" "$out"

    # Container defaults, passed as "key=value" pairs.
    local kv
    for kv in "$@"; do
        set_conf "$out" "${kv%%=*}" "${kv#*=}"
    done

    # User overrides.
    local var key
    while IFS='=' read -r var _; do
        [[ $var == SFCONF_* ]] || continue
        key=${var#SFCONF_}
        key=${key//__/.}
        set_conf "$out" "$key" "${!var}"
    done < <(env)
}

mysql_q() {
    MYSQL_PWD=$DB_PASSWORD mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -N -B "$@"
}

sql_str() { printf "'%s'" "${1//\'/\'\'}"; }

wait_for_db() {
    local i
    for i in $(seq 1 120); do
        if mysql_q -e 'SELECT 1' >/dev/null 2>&1; then
            return 0
        fi
        (( i == 1 )) && log "Waiting for MySQL at $DB_HOST:$DB_PORT..."
        sleep 2
    done
    log "MySQL at $DB_HOST:$DB_PORT is not reachable."
    exit 1
}

table_count() {
    mysql_q -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = $(sql_str "$1")"
}

# Download the world base dump from the GitHub release when the world DB is
# still empty and the dump isn't cached in the dbdump volume yet.
ensure_world_dump() {
    local dump=$1
    if [[ $(table_count "$DB_WORLD") != 0 ]]; then
        return 0
    fi
    if [[ -s $dump ]]; then
        log "World database is empty; it will be imported from $dump."
        return 0
    fi
    if [[ -z ${WORLD_DB_URL:-} ]]; then
        log "World database is empty and $dump is missing. Set WORLD_DB_URL or place the dump there."
        exit 1
    fi

    local tmp
    tmp=$(mktemp -d "$(dirname "$dump")/download.XXXXXX")
    log "World database is empty; downloading $WORLD_DB_URL"
    curl -fL --retry 3 -o "$tmp/world" "$WORLD_DB_URL"
    if unzip -tq "$tmp/world" >/dev/null 2>&1; then
        unzip -q "$tmp/world" -d "$tmp/x"
        local sql
        sql=$(find "$tmp/x" -type f -name '*.sql' -printf '%s %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
        [[ -n $sql ]] || { log "No .sql file found in $WORLD_DB_URL"; exit 1; }
        mv "$sql" "$dump"
    else
        mv "$tmp/world" "$dump"
    fi
    rm -rf "$tmp"
    log "World dump saved to $dump"
}

update_realmlist() {
    local realm_id=${REALM_ID:-1} i
    for i in $(seq 1 60); do
        if [[ $(table_count "$DB_AUTH") != 0 ]] && \
           mysql_q "$DB_AUTH" -e 'SELECT 1 FROM realmlist LIMIT 1' >/dev/null 2>&1; then
            break
        fi
        (( i == 1 )) && log "Waiting for authserver to set up the auth database..."
        sleep 2
    done

    local sets=()
    [[ -n ${REALM_NAME:-} ]] && sets+=("name = $(sql_str "$REALM_NAME")")
    if [[ -n ${REALM_ADDRESS:-} ]]; then
        sets+=("address = $(sql_str "$REALM_ADDRESS")")
        sets+=("localAddress = $(sql_str "${REALM_LOCAL_ADDRESS:-$REALM_ADDRESS}")")
    fi
    sets+=("port = $WORLD_PORT")
    local IFS=,
    log "Updating realmlist id $realm_id: ${sets[*]}"
    mysql_q "$DB_AUTH" -e "UPDATE realmlist SET ${sets[*]} WHERE id = $realm_id"
}

db_info() { echo "$DB_HOST;$DB_PORT;$DB_USER;$DB_PASSWORD;$1"; }

cmd=${1:-worldserver}
case $cmd in
    worldserver)
        shift || true
        WORLD_PORT=${WORLD_PORT:-8085}
        world_dump=$SF_HOME/dbdump/world_database.sql

        if [[ ! -d $SF_HOME/data/dbc ]]; then
            log "No client data in $SF_HOME/data (dbc/ is missing)."
            log "Extract it with: docker compose run --rm extractor  (see doc/Docker.md)"
            exit 1
        fi

        render_config worldserver \
            "DataDir=$SF_HOME/data" \
            "LogsDir=$SF_HOME/logs" \
            "WorldServerPort=$WORLD_PORT" \
            "LoginDatabaseInfo=$(db_info "$DB_AUTH")" \
            "WorldDatabaseInfo=$(db_info "$DB_WORLD")" \
            "CharacterDatabaseInfo=$(db_info "$DB_CHARACTERS")" \
            "WorldDatabase.SqlPath=$SF_HOME/sql" \
            "WorldDatabase.BaseSqlFile=$world_dump" \
            "CharacterDatabase.SqlPath=$SF_HOME/sql"

        wait_for_db
        ensure_world_dump "$world_dump"
        update_realmlist

        exec stdbuf -oL -eL "$SF_HOME/bin/worldserver" -c "$SF_RUN/worldserver.conf" "$@"
        ;;
    authserver)
        shift || true
        render_config authserver \
            "LogsDir=$SF_HOME/logs" \
            "LoginDatabaseInfo=$(db_info "$DB_AUTH")" \
            "LoginDatabase.SqlPath=$SF_HOME/sql"

        wait_for_db

        exec stdbuf -oL -eL "$SF_HOME/bin/authserver" -c "$SF_RUN/authserver.conf" "$@"
        ;;
    *)
        exec "$@"
        ;;
esac
