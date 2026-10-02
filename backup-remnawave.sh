#!/usr/bin/env bash
# Secure, validated backups for Remnawave + Bedolaga Bot.
# No eval; every backup item is written to a private staging directory and
# published as backup_*.tar.gz only after the mandatory database dumps pass.

set -Eeuo pipefail
umask 077

# Override these with environment variables or edit this configuration block.
BACKUP_DIR="${BACKUP_DIR:-/opt/backups/remnawave}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
LOCK_FILE="${LOCK_FILE:-/run/lock/backup-remnawave.lock}"
TELEGRAM_ENV_FILE="${TELEGRAM_ENV_FILE:-/etc/backup-remnawave.env}"

CONTAINER_REMNAWAVE_DB="${CONTAINER_REMNAWAVE_DB:-remnawave-db}"
CONTAINER_BOT_DB="${CONTAINER_BOT_DB:-remnawave_bot_db}"
CONTAINER_BOT_REDIS="${CONTAINER_BOT_REDIS:-remnawave_bot_redis}"
DB_USER_REMNAWAVE="${DB_USER_REMNAWAVE:-postgres}"
DB_USER_BOT="${DB_USER_BOT:-remnawave_user}"

PATH_REMNAWAVE="${PATH_REMNAWAVE:-/opt/remnawave}"
PATH_BOT="${PATH_BOT:-/opt/remnawave-bedolaga-telegram-bot}"
PATH_CABINET="${PATH_CABINET:-/opt/bedolaga-cabinet}"
PATH_UPTIME_KUMA="${PATH_UPTIME_KUMA:-/opt/uptime-kuma}"
PATH_MONITORING="${PATH_MONITORING:-/opt/monitoring}"
PATH_SCRIPTS="${PATH_SCRIPTS:-/opt/scripts}"

RUN_ID="$(date -u +%Y-%m-%d_%H-%M-%S)_UTC"
START_EPOCH="$(date +%s)"
STAGE=""
TEMP_ARCHIVE=""
LOCK_FD=9
declare -a ITEM_NAMES=() ITEM_STATUS=() ITEM_BYTES=() ITEM_FILES=()
ERRORS=0
WARNINGS=0
PUBLISHED_ARCHIVE=""

log() { printf '[%s UTC] %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
die() { log "FATAL: $*" >&2; exit 1; }

banner() {
    local label='backup.sh'
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        printf '\033[38;5;43m  ╔══════════════════════════════════════╗\033[0m\n'
        printf '\033[38;5;43m  ║             %-20s ║\033[0m\n' "$label"
        printf '\033[38;5;43m  ╚══════════════════════════════════════╝\033[0m\n\n'
    else
        printf '  +--------------------------------------+\n  |             %-20s |\n  +--------------------------------------+\n\n' "$label"
    fi
}
banner

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n "$TEMP_ARCHIVE" && -f "$TEMP_ARCHIVE" ]]; then
        rm -f -- "$TEMP_ARCHIVE" "${TEMP_ARCHIVE}.sha256" || true
    fi
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then
        if (( rc == 0 )); then
            rm -rf -- "$STAGE"
        else
            local failed_dir="$BACKUP_DIR/.failed-$RUN_ID"
            if mv -- "$STAGE" "$failed_dir" 2>/dev/null; then
                chmod 700 "$failed_dir" 2>/dev/null || true
                printf 'Неполный набор оставлен для диагностики: %s\n' "$failed_dir" >&2
            else
                printf 'Не удалось переместить staging каталог: %s\n' "$STAGE" >&2
            fi
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die 'Запусти скрипт от root.'
for cmd in docker tar gzip sha256sum flock find awk date df curl python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "Не найдена обязательная команда: $cmd"
done
[[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || die 'RETENTION_DAYS должен быть положительным целым числом.'

mkdir -p "$BACKUP_DIR" "$(dirname "$LOCK_FILE")"
chmod 700 "$BACKUP_DIR"
exec {LOCK_FD}>"$LOCK_FILE"
flock -n "$LOCK_FD" || die 'Уже выполняется другой backup-remnawave.sh.'

# Telegram credentials are deliberately external to this script and Git.
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
if [[ -z "$TELEGRAM_BOT_TOKEN" && -f "$TELEGRAM_ENV_FILE" ]]; then
    [[ "$(stat -c '%u' "$TELEGRAM_ENV_FILE")" == 0 ]] || die "$TELEGRAM_ENV_FILE должен принадлежать root."
    mode="$(stat -c '%a' "$TELEGRAM_ENV_FILE")"
    (( (8#$mode & 077) == 0 )) || die "$TELEGRAM_ENV_FILE должен иметь права 600 (или строже)."
    # This is an administrator-created root-only environment file.
    # shellcheck disable=SC1090
    source "$TELEGRAM_ENV_FILE"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
fi

STAGE="$BACKUP_DIR/.staging-$RUN_ID-$$"
mkdir -m 700 -- "$STAGE"
TEMP_ARCHIVE="$BACKUP_DIR/.backup_$RUN_ID.tar.gz.tmp"
FINAL_ARCHIVE="$BACKUP_DIR/backup_$RUN_ID.tar.gz"
[[ ! -e "$FINAL_ARCHIVE" && ! -e "$TEMP_ARCHIVE" ]] || die 'Имя архива уже существует; повтори запуск.'

record() {
    local name="$1" status="$2" bytes="${3:-0}" file="${4:-}"
    ITEM_NAMES+=("$name") ITEM_STATUS+=("$status") ITEM_BYTES+=("$bytes") ITEM_FILES+=("$file")
    case "$status" in ERROR) ERRORS=$((ERRORS + 1));; SKIP) WARNINGS=$((WARNINGS + 1));; esac
}

file_bytes() { stat -c '%s' -- "$1"; }

backup_database() {
    local label="$1" container="$2" user="$3" output="$4" version
    log "Снимаю логический дамп: $label ($container)"
    if ! docker inspect "$container" >/dev/null 2>&1 || [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]]; then
        log "ОШИБКА: PostgreSQL контейнер недоступен: $container"
        record "$label" ERROR 0 "$output"
        return 1
    fi
    version="$(docker exec "$container" psql -XAtq -U "$user" -d postgres -c 'SHOW server_version' 2>/dev/null || true)"
    if [[ -z "$version" ]]; then
        log "ОШИБКА: не удалось подключиться к PostgreSQL в $container"
        record "$label" ERROR 0 "$output"
        return 1
    fi
    if docker exec "$container" pg_dumpall -U "$user" 2>"$STAGE/${output}.stderr" | gzip -c > "$STAGE/$output"; then
        if gzip -t "$STAGE/$output" && [[ -s "$STAGE/$output" ]]; then
            printf '%s\n' "$version" > "$STAGE/${output%.gz}.server-version.txt"
            local n; n="$(file_bytes "$STAGE/$output")"
            record "$label (PostgreSQL $version)" OK "$n" "$output"
            rm -f "$STAGE/${output}.stderr"
            log "OK: $label ($(du -h "$STAGE/$output" | awk '{print $1}'))"
            return 0
        fi
    fi
    log "ОШИБКА: дамп $label не прошел gzip/size проверку"
    record "$label" ERROR 0 "$output"
    return 1
}

backup_paths() {
    local label="$1" output="$2"; shift 2
    local -a existing=()
    local path relative
    for path in "$@"; do
        [[ -e "/$path" || -L "/$path" ]] && existing+=("$path")
    done
    if ((${#existing[@]} == 0)); then
        log "SKIP: $label — указанные пути не найдены"
        record "$label" SKIP 0 "$output"
        return 0
    fi
    log "Архивирую: $label"
    if tar --numeric-owner --acls --xattrs -czf "$STAGE/$output" -C / "${existing[@]}" 2>"$STAGE/${output}.stderr" \
        && gzip -t "$STAGE/$output" && tar -tzf "$STAGE/$output" >/dev/null; then
        local n; n="$(file_bytes "$STAGE/$output")"
        record "$label" OK "$n" "$output"
        rm -f "$STAGE/${output}.stderr"
        log "OK: $label ($(du -h "$STAGE/$output" | awk '{print $1}'))"
        return 0
    fi
    rm -f "$STAGE/$output"
    log "ОШИБКА: не удалось создать или проверить архив $label"
    record "$label" ERROR 0 "$output"
    return 1
}

backup_redis() {
    local container="$CONTAINER_BOT_REDIS" state status output="$STAGE/db_redis-bot.rdb.gz"
    log "Сохраняю Redis RDB ($container)"
    if ! docker inspect "$container" >/dev/null 2>&1 || [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != true ]]; then
        log "SKIP: Redis контейнер не запущен: $container"
        record 'Redis Bot' SKIP 0 'db_redis-bot.rdb.gz'
        return 0
    fi
    if ! docker exec "$container" redis-cli BGSAVE >/dev/null; then
        log 'ОШИБКА: Redis BGSAVE не запустился'
        record 'Redis Bot' ERROR 0 'db_redis-bot.rdb.gz'
        return 1
    fi
    for _ in $(seq 1 120); do
        state="$(docker exec "$container" redis-cli --raw INFO persistence 2>/dev/null || true)"
        [[ "$state" == *'rdb_bgsave_in_progress:0'* ]] && break
        sleep 1
    done
    [[ "$state" == *'rdb_bgsave_in_progress:0'* ]] || {
        log 'ОШИБКА: Redis BGSAVE не завершился за 120 секунд'
        record 'Redis Bot' ERROR 0 'db_redis-bot.rdb.gz'
        return 1
    }
    status="$(printf '%s\n' "$state" | awk -F: '$1=="rdb_last_bgsave_status" {gsub("\r", "", $2); print $2; exit}')"
    [[ "$status" == ok ]] || {
        log "ОШИБКА: Redis сообщил rdb_last_bgsave_status=$status"
        record 'Redis Bot' ERROR 0 'db_redis-bot.rdb.gz'
        return 1
    }
    if docker exec "$container" cat /data/dump.rdb | gzip -c > "$output" && gzip -t "$output" \
        && [[ "$(python3 -c 'import gzip,sys; print(gzip.open(sys.argv[1], "rb").read(5).decode("ascii", "replace"))' "$output")" == REDIS ]]; then
        local n; n="$(file_bytes "$output")"
        record 'Redis Bot RDB' OK "$n" 'db_redis-bot.rdb.gz'
        log "OK: Redis RDB ($(du -h "$output" | awk '{print $1}'))"
        return 0
    fi
    rm -f "$output"
    log 'ОШИБКА: Redis RDB пустой, поврежден или имеет неожиданный формат'
    record 'Redis Bot' ERROR 0 'db_redis-bot.rdb.gz'
    return 1
}

log "=== Начинаю резервное копирование ($RUN_ID) ==="
HOST="$(hostname -f 2>/dev/null || hostname)"
OS="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")"
{
    printf 'Backup timestamp (UTC): %s\n' "$RUN_ID"
    printf 'Host: %s\n' "$HOST"
    printf 'OS: %s\n' "$OS"
    printf 'Script: backup-remnawave.sh\n'
    printf 'PostgreSQL containers: %s, %s\n' "$CONTAINER_REMNAWAVE_DB" "$CONTAINER_BOT_DB"
} > "$STAGE/metadata.txt"

backup_database 'PostgreSQL Remnawave' "$CONTAINER_REMNAWAVE_DB" "$DB_USER_REMNAWAVE" 'db_remnawave.sql.gz' || true
backup_database 'PostgreSQL Bedolaga Bot' "$CONTAINER_BOT_DB" "$DB_USER_BOT" 'db_bedolaga-bot.sql.gz' || true
backup_redis || true

# Include existing files only. Optional missing paths are reported as SKIP, not hidden.
backup_paths 'Remnawave config' 'configs_remnawave.tar.gz' \
    "${PATH_REMNAWAVE#/}/.env" "${PATH_REMNAWAVE#/}/docker-compose.yml" \
    "${PATH_REMNAWAVE#/}/.env-node" "${PATH_REMNAWAVE#/}/docker-compose.node.yml" || true
backup_paths 'Bedolaga Bot config and data' 'configs_bot.tar.gz' \
    "${PATH_BOT#/}/.env" "${PATH_BOT#/}/docker-compose.yml" "${PATH_BOT#/}/data" "${PATH_BOT#/}/locales" || true
backup_paths 'Cabinet config' 'configs_cabinet.tar.gz' \
    "${PATH_CABINET#/}/.env" "${PATH_CABINET#/}/docker-compose.yml" "${PATH_CABINET#/}/data" || true
backup_paths 'Uptime Kuma project files' 'configs_uptime-kuma.tar.gz' "${PATH_UPTIME_KUMA#/}" || true
backup_paths 'Monitoring' 'monitoring.tar.gz' "${PATH_MONITORING#/}" || true
backup_paths 'Nginx configuration' 'configs_nginx.tar.gz' 'etc/nginx' || true
backup_paths 'Let’s Encrypt certificates and keys' 'ssl_certs.tar.gz' 'etc/letsencrypt' || true
backup_paths 'Fail2ban configuration' 'configs_fail2ban.tar.gz' 'etc/fail2ban' || true
backup_paths 'Local administration scripts' 'scripts.tar.gz' "${PATH_SCRIPTS#/}" || true

if (( ERRORS > 0 )); then
    log "Отмена публикации: ошибок обязательных/доступных элементов: $ERRORS."
    printf 'Проверь частичный набор и stderr в staging-каталоге после завершения: %s\n' "$STAGE" >&2
    exit 1
fi

MANIFEST="$STAGE/manifest.txt"
{
    cat "$STAGE/metadata.txt"
    printf '\nItem status | bytes | file\n'
    for i in "${!ITEM_NAMES[@]}"; do
        printf '%s | %s | %s | %s\n' "${ITEM_STATUS[$i]}" "${ITEM_BYTES[$i]}" "${ITEM_NAMES[$i]}" "${ITEM_FILES[$i]}"
    done
    printf '\nSHA-256 of staged payloads:\n'
    find "$STAGE" -maxdepth 1 -type f ! -name manifest.txt ! -name '*.stderr' -print0 \
        | sort -z | xargs -0 -r sha256sum | sed "s#${STAGE}/##"
} > "$MANIFEST"

log 'Создаю внешний архив'
tar --numeric-owner -czf "$TEMP_ARCHIVE" -C "$STAGE" . || die 'Ошибка упаковки итогового архива.'
gzip -t "$TEMP_ARCHIVE" || die 'Внешний архив не прошел gzip -t.'
tar -tzf "$TEMP_ARCHIVE" >/dev/null || die 'Внешний архив не прошел tar -tzf.'
[[ -s "$TEMP_ARCHIVE" ]] || die 'Итоговый архив пуст.'
chmod 600 "$TEMP_ARCHIVE"
archive_hash="$(sha256sum "$TEMP_ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$archive_hash" "$(basename "$FINAL_ARCHIVE")" > "${TEMP_ARCHIVE}.sha256"
chmod 600 "${TEMP_ARCHIVE}.sha256"
mv -- "$TEMP_ARCHIVE" "$FINAL_ARCHIVE"
mv -- "${TEMP_ARCHIVE}.sha256" "${FINAL_ARCHIVE}.sha256"
PUBLISHED_ARCHIVE="$FINAL_ARCHIVE"

# Retain completed archives only; never prune directories while a run is active.
log "Удаляю архивы старше $RETENTION_DAYS дней"
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'backup_*.tar.gz' -o -name 'backup_*.tar.gz.sha256' \) \
    -mmin "+$((RETENTION_DAYS * 1440))" -delete

END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))
ARCHIVE_SIZE="$(du -h "$FINAL_ARCHIVE" | awk '{print $1}')"
STATUS_TEXT='Успешно'
(( WARNINGS == 0 )) || STATUS_TEXT="Готово с пропусками: $WARNINGS"
html_escape() {
    python3 -c 'import html,sys; print(html.escape(sys.argv[1], quote=False), end="")' "$1"
}

if (( WARNINGS == 0 )); then
    STATUS_ICON='✅'
else
    STATUS_ICON='⚠️'
fi
REPORT="<b>🛡 TUNNER · BACKUP</b>
<b>Статус:</b> ${STATUS_ICON} $(html_escape "$STATUS_TEXT")
<b>Сервер:</b> <code>$(html_escape "$HOST")</code>
<b>ОС:</b> $(html_escape "$OS")
<b>Время (UTC):</b> <code>$RUN_ID</code>
<b>Длительность:</b> $((DURATION / 60)) мин $((DURATION % 60)) сек
<b>Размер:</b> $ARCHIVE_SIZE

<b>СОСТАВ БЭКАПА</b>"
for i in "${!ITEM_NAMES[@]}"; do
    case "${ITEM_STATUS[$i]}" in
        OK) item_icon='✅';;
        SKIP) item_icon='➖';;
        *) item_icon='❌';;
    esac
    REPORT+="
$item_icon $(html_escape "${ITEM_NAMES[$i]}") · ${ITEM_BYTES[$i]} байт"
done
REPORT+="
<b>Архив:</b> <code>$(html_escape "$(basename "$FINAL_ARCHIVE")")</code>
<b>SHA-256:</b> <code>$(cut -d' ' -f1 "${FINAL_ARCHIVE}.sha256")</code>"

log "Готово: $FINAL_ARCHIVE ($ARCHIVE_SIZE); $STATUS_TEXT"

if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    response="$STAGE/telegram-response.json"
    http_code="$(curl -sS -o "$response" -w '%{http_code}' --max-time 30 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode 'parse_mode=HTML' \
        --data-urlencode "text=$REPORT" || true)"
    if [[ "$http_code" =~ ^2 && -f "$response" ]] && grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$response"; then
        log 'Отчет Telegram доставлен'
    else
        log "ВНИМАНИЕ: Telegram не принял отчет (HTTP ${http_code:-unknown}); локальный архив готов"
    fi
    http_code="$(curl -sS -o "$response" -w '%{http_code}' --max-time 300 \
        -F "chat_id=$TELEGRAM_CHAT_ID" -F "document=@$FINAL_ARCHIVE" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" || true)"
    if [[ "$http_code" =~ ^2 && -f "$response" ]] && grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$response"; then
        log 'Архив Telegram доставлен'
    else
        log "ВНИМАНИЕ: Telegram не принял архив (HTTP ${http_code:-unknown}); локальная копия сохранена"
    fi
else
    log "Telegram не настроен: архив сохранен локально. Настройте $TELEGRAM_ENV_FILE для уведомлений."
fi

exit 0
