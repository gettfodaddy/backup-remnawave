#!/usr/bin/env bash
# restore-from-backup.sh
# Selective PostgreSQL database restore from archives made by backup-remnawave.sh.
# This script deliberately does not restore config tarballs, Redis, panel files, or certificates.
# Those files can change service topology and are intentionally kept separate from DB rollback.

set -Eeuo pipefail
umask 077

BACKUP_DIR="${BACKUP_DIR:-/opt/backups/remnawave}"
SAFETY_DIR_ROOT="${SAFETY_DIR_ROOT:-/root/backups}"
PANEL_PG_CONTAINER="${PANEL_PG_CONTAINER:-remnawave-db}"
PANEL_APP_CONTAINER="${PANEL_APP_CONTAINER:-remnawave}"
BOT_PG_CONTAINER="${BOT_PG_CONTAINER:-remnawave_bot_db}"
BOT_APP_CONTAINER="${BOT_APP_CONTAINER:-remnawave_bot}"

WORK_DIR=""
STOPPED_APP=""
LOCK_FILE="/run/lock/restore-from-backup.lock"

fail() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

banner() {
    local label='restore.sh'
    local inner=40 pad right content
    pad=$(( (inner - ${#label}) / 2 ))
    right=$(( inner - ${#label} - pad ))
    printf -v content '%*s%s%*s' "$pad" '' "$label" "$right" ''
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        printf '\033[38;5;45m  +----------------------------------------+\033[0m\n'
        printf '\033[38;5;45m  |%s|\033[0m\033[38;5;240m\\\033[0m\n' "$content"
        printf '\033[38;5;45m  +----------------------------------------+\033[0m\033[38;5;240m \\\033[0m\n'
        printf '\033[38;5;240m   \\________________________________________\\\033[0m\n\n'
    else
        printf '  +----------------------------------------+\n  |%s|\\\n  +----------------------------------------+ \\\n   \\________________________________________\\\n\n' "$content"
    fi
}
banner

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n "$STOPPED_APP" ]]; then
        if docker inspect "$STOPPED_APP" >/dev/null 2>&1; then
            local running
            running=$(docker inspect -f '{{.State.Running}}' "$STOPPED_APP" 2>/dev/null || printf 'false')
            if [[ "$running" != true ]]; then
                log "Запускаю обратно остановленный контейнер $STOPPED_APP"
                docker start "$STOPPED_APP" >/dev/null || {
                    printf 'ВНИМАНИЕ: не удалось автоматически запустить %s\n' "$STOPPED_APP" >&2
                    rc=1
                }
            fi
        fi
    fi
    if [[ -n "$WORK_DIR" && "$WORK_DIR" == /root/restore-from-backup.* && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    exit "$rc"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail 'Запусти скрипт от root.'
for cmd in docker gzip tar awk sed grep date df flock; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Не найдена обязательная команда: $cmd"
done
[[ $# -le 1 ]] || fail "Использование: $0 [backup_YYYY-MM-DD_HH-MM.tar.gz | каталог-бэкапа]"

mkdir -p /run/lock "$SAFETY_DIR_ROOT"
chmod 700 "$SAFETY_DIR_ROOT"
exec 9>"$LOCK_FILE"
flock -n 9 || fail 'Уже выполняется другой restore-from-backup.sh.'

WORK_DIR=$(mktemp -d /root/restore-from-backup.XXXXXX)
chmod 700 "$WORK_DIR"

select_source() {
    local -a archives=()
    local i choice
    mapfile -t archives < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.tar.gz' -printf '%p\n' 2>/dev/null | sort -r)
    ((${#archives[@]} > 0)) || fail "В $BACKUP_DIR не найдены backup_*.tar.gz"
    printf 'Доступные архивы:\n'
    for i in "${!archives[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${archives[$i]}"
    done
    printf '  0) Выход\n'
    read -r -p 'Номер архива: ' choice
    [[ "$choice" =~ ^[0-9]+$ ]] || fail 'Нужно ввести номер из списка.'
    (( choice != 0 )) || exit 0
    (( choice >= 1 && choice <= ${#archives[@]} )) || fail 'Номер архива вне списка.'
    SOURCE="${archives[$((choice - 1))]}"
}

SOURCE="${1:-}"
if [[ -z "$SOURCE" ]]; then
    select_source
fi
[[ -e "$SOURCE" ]] || fail "Источник не найден: $SOURCE"

ARCHIVE_MODE=0
ARCHIVE_MEMBERS=()
if [[ -f "$SOURCE" ]]; then
    [[ "$SOURCE" == *.tar.gz || "$SOURCE" == *.tgz ]] || fail 'Ожидается внешний архив .tar.gz/.tgz или каталог распакованного бэкапа.'
    archive_listing=$(tar -tzf "$SOURCE") || fail 'Не удалось прочитать список файлов внешнего tar.gz.'
    while IFS= read -r member; do
        [[ -n "$member" ]] || continue
        [[ "$member" != /* ]] || fail 'Внешний архив содержит абсолютный путь; восстановление отменено.'
        case "/$member/" in
            *"/../"*|*"/./"*) fail 'Внешний архив содержит небезопасный путь; восстановление отменено.' ;;
        esac
        ARCHIVE_MEMBERS+=("$member")
    done <<< "$archive_listing"
    ARCHIVE_MODE=1
elif [[ -d "$SOURCE" ]]; then
    SOURCE=$(realpath "$SOURCE")
else
    fail 'Источник должен быть tar.gz архивом или каталогом одного бэкапа.'
fi

extract_backup_item() {
    local basename="$1" output="$2"
    if (( ARCHIVE_MODE )); then
        local -a matches=()
        local member
        for member in "${ARCHIVE_MEMBERS[@]}"; do
            [[ "${member##*/}" == "$basename" ]] && matches+=("$member")
        done
        ((${#matches[@]} == 1)) || fail "В архиве ожидался ровно один $basename, найдено: ${#matches[@]}"
        tar -xOzf "$SOURCE" "${matches[0]}" > "$output" || fail "Не удалось извлечь $basename из внешнего архива."
    else
        [[ -f "$SOURCE/$basename" ]] || fail "В каталоге бэкапа отсутствует $basename"
        cp -- "$SOURCE/$basename" "$output"
    fi
    gzip -t "$output" || fail "$basename повреждён или не является gzip-файлом."
}

printf '\nВосстановление затронет только выбранную базу данных.\n'
printf 'Конфиги, файлы панели/бота, Redis и другие контейнеры скрипт не меняет.\n\n'
printf '  1) База Remnawave (контейнер %s)\n' "$PANEL_PG_CONTAINER"
printf '  2) База Bedolaga Bot (контейнер %s)\n' "$BOT_PG_CONTAINER"
printf '  0) Выход\n'
read -r -p 'Выбери компонент: ' component

case "$component" in
    1)
        LABEL='Remnawave'
        DUMP_NAME='db_remnawave.sql.gz'
        PG_CONTAINER="$PANEL_PG_CONTAINER"
        APP_CONTAINER="$PANEL_APP_CONTAINER"
        DEFAULT_DB='remnawave'
        DEFAULT_USER='postgres'
        ;;
    2)
        LABEL='Bedolaga Bot'
        DUMP_NAME='db_bedolaga-bot.sql.gz'
        PG_CONTAINER="$BOT_PG_CONTAINER"
        APP_CONTAINER="$BOT_APP_CONTAINER"
        DEFAULT_DB='remnawave_bot'
        DEFAULT_USER='remnawave_user'
        ;;
    0) exit 0 ;;
    *) fail 'Выбор не распознан.' ;;
esac

for container in "$PG_CONTAINER" "$APP_CONTAINER"; do
    docker inspect "$container" >/dev/null 2>&1 || fail "Контейнер $container не найден. Проверь настройки в начале скрипта."
done
[[ $(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER") == true ]] || fail "Контейнер PostgreSQL $PG_CONTAINER не запущен."

PG_USER=$(docker exec "$PG_CONTAINER" printenv POSTGRES_USER 2>/dev/null || true)
TARGET_DB=$(docker exec "$PG_CONTAINER" printenv POSTGRES_DB 2>/dev/null || true)
PG_USER=${PG_USER:-$DEFAULT_USER}
TARGET_DB=${TARGET_DB:-$DEFAULT_DB}
[[ "$PG_USER" =~ ^[A-Za-z0-9_]+$ ]] || fail 'Неожиданное имя пользователя БД; проверь POSTGRES_USER.'
[[ "$TARGET_DB" =~ ^[A-Za-z0-9_]+$ ]] || fail 'Неожиданное имя базы; проверь POSTGRES_DB.'

SOURCE_GZ="$WORK_DIR/$DUMP_NAME"
extract_backup_item "$DUMP_NAME" "$SOURCE_GZ"

SQL_SECTION="$WORK_DIR/${TARGET_DB}.sql"
SOURCE_VERSION_FILE="$WORK_DIR/source-version.txt"
# gzip -t уже проверил весь исходный файл. awk читает поток целиком, сохраняет только секцию
# выбранной БД между соответствующими командами pg_dumpall `\\connect`.
gzip -dc "$SOURCE_GZ" | awk -v target="$TARGET_DB" -v version_file="$SOURCE_VERSION_FILE" '
    /^-- Dumped from database version / && source_version == "" { source_version = $6 }
    /^\\connect[[:space:]]/ {
        if (active) active = 0
        db = $2
        gsub(/^"/, "", db)
        gsub(/"$/, "", db)
        if (!found && db == target) { active = 1; found = 1 }
        next
    }
    active { print }
    END {
        if (source_version != "") print source_version > version_file
        if (!found) exit 42
    }
' > "$SQL_SECTION" || fail "В дампе нет секции базы '$TARGET_DB'. Проверь POSTGRES_DB и архив."
[[ -s "$SQL_SECTION" ]] || fail 'Секция базы в дампе пустая.'

SOURCE_VERSION=$(cat "$SOURCE_VERSION_FILE" 2>/dev/null || true)
SERVER_VERSION_NUM=$(docker exec "$PG_CONTAINER" psql -XAtq -U "$PG_USER" -d postgres -c 'SHOW server_version_num')
[[ "$SERVER_VERSION_NUM" =~ ^[0-9]+$ ]] || fail 'Не удалось определить версию целевого PostgreSQL.'
SERVER_MAJOR=$((SERVER_VERSION_NUM / 10000))
if [[ "$SOURCE_VERSION" =~ ^([0-9]+)\. ]]; then
    SOURCE_MAJOR=${BASH_REMATCH[1]}
    (( SERVER_MAJOR >= SOURCE_MAJOR )) || fail "Дамп сделан PostgreSQL $SOURCE_VERSION, а целевой сервер PostgreSQL $SERVER_MAJOR. Восстановление в более старую major-версию запрещено."
else
    printf 'ВНИМАНИЕ: в дампе не удалось определить major-версию PostgreSQL.\n'
fi

DB_OWNER=$(docker exec "$PG_CONTAINER" psql -XAtq -U "$PG_USER" -d postgres \
    -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$TARGET_DB'")
[[ "$DB_OWNER" =~ ^[A-Za-z0-9_]+$ ]] || fail "Не удалось определить владельца базы $TARGET_DB."
ROLE_PRESENT=$(docker exec "$PG_CONTAINER" psql -XAtq -U "$PG_USER" -d postgres \
    -c "SELECT 1 FROM pg_roles WHERE rolname='$DB_OWNER'")
[[ "$ROLE_PRESENT" == 1 ]] || fail "Роль-владелец $DB_OWNER отсутствует в целевом кластере."
DB_PRESENT=$(docker exec "$PG_CONTAINER" psql -XAtq -U "$PG_USER" -d postgres \
    -c "SELECT 1 FROM pg_database WHERE datname='$TARGET_DB'")
[[ "$DB_PRESENT" == 1 ]] || fail "Целевая база $TARGET_DB не существует. Убедись, что приложение уже установлено."

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SAFETY_DIR="$SAFETY_DIR_ROOT/restore-from-backup-$STAMP"
mkdir -m 700 -p "$SAFETY_DIR"
DB_SIZE=$(docker exec "$PG_CONTAINER" psql -XAtq -U "$PG_USER" -d postgres \
    -c "SELECT pg_database_size('$TARGET_DB')")
FREE_KB=$(df -Pk "$SAFETY_DIR" | awk 'NR==2 {print $4}')
[[ "$DB_SIZE" =~ ^[0-9]+$ && "$FREE_KB" =~ ^[0-9]+$ ]] || fail 'Не удалось проверить свободное место.'
(( FREE_KB * 1024 >= DB_SIZE )) || fail 'На диске меньше свободного места, чем текущий размер базы; безопасный pre-restore dump может не поместиться.'

printf '\nПлан восстановления:\n'
printf '  Компонент:       %s\n' "$LABEL"
printf '  Источник:        %s\n' "$SOURCE"
printf '  Дамп:            %s\n' "$DUMP_NAME"
printf '  PostgreSQL:      контейнер %s, версия %s\n' "$PG_CONTAINER" "$SERVER_MAJOR"
printf '  База назначения: %s (владелец %s)\n' "$TARGET_DB" "$DB_OWNER"
printf '  Приложение:      %s (будет остановлено только на время restore)\n' "$APP_CONTAINER"
printf '  Pre-restore:     %s\n' "$SAFETY_DIR"
printf '\nБудет удалено содержимое только базы %s и загружено из бэкапа.\n' "$TARGET_DB"
printf 'Другие базы/контейнеры и Remnawave-панель при выборе Bot не затрагиваются.\n'
read -r -p "Для продолжения введи RESTORE: " confirmation
[[ "$confirmation" == RESTORE ]] || fail 'Операция отменена.'

APP_WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' "$APP_CONTAINER")
if [[ "$APP_WAS_RUNNING" == true ]]; then
    log "Останавливаю только приложение $APP_CONTAINER"
    docker stop --time 30 "$APP_CONTAINER" >/dev/null
    STOPPED_APP="$APP_CONTAINER"
fi

CURRENT_DUMP="$SAFETY_DIR/current-${TARGET_DB}.dump"
log 'Снимаю pre-restore дамп текущей базы'
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$TARGET_DB" -Fc > "$CURRENT_DUMP"
[[ -s "$CURRENT_DUMP" ]] || fail 'Pre-restore дамп пустой; исходная база не будет изменена.'
chmod 600 "$CURRENT_DUMP"

log "Заменяю содержимое только базы $TARGET_DB"
docker exec "$PG_CONTAINER" dropdb --if-exists --force -U "$PG_USER" "$TARGET_DB"
docker exec "$PG_CONTAINER" createdb -U "$PG_USER" -O "$DB_OWNER" "$TARGET_DB"

if ! docker exec -i "$PG_CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$TARGET_DB" < "$SQL_SECTION"; then
    printf '\nВосстановление из выбранного архива завершилось ошибкой. Возвращаю pre-restore базу.\n' >&2
    if docker exec "$PG_CONTAINER" dropdb --if-exists --force -U "$PG_USER" "$TARGET_DB" \
        && docker exec "$PG_CONTAINER" createdb -U "$PG_USER" -O "$DB_OWNER" "$TARGET_DB" \
        && docker exec -i "$PG_CONTAINER" pg_restore --exit-on-error -U "$PG_USER" -d "$TARGET_DB" < "$CURRENT_DUMP"; then
        fail "Исходный restore не удался; текущая база восстановлена из $CURRENT_DUMP"
    else
        fail "Не удался restore и автоматический откат. Не удаляй $CURRENT_DUMP; требуется ручное восстановление."
    fi
fi

TABLE_COUNT=$(docker exec "$PG_CONTAINER" psql -XAtq -U "$PG_USER" -d "$TARGET_DB" \
    -c "SELECT count(*) FROM pg_tables WHERE schemaname='public'")
[[ "$TABLE_COUNT" =~ ^[0-9]+$ ]] || fail 'Не удалось проверить таблицы после импорта.'
(( TABLE_COUNT > 0 )) || fail 'В восстановленной базе нет таблиц public; оставлен pre-restore дамп для ручного отката.'

log "Готово: в базе $TARGET_DB найдено таблиц public: $TABLE_COUNT"
printf 'Pre-restore дамп сохранён: %s\n' "$CURRENT_DUMP"
printf 'При необходимости удали только после проверки сервиса: %s\n' "$SAFETY_DIR"
printf 'Конфиги, Redis и файлы приложения не восстанавливались.\n'
printf 'Проверь health контейнера приложения и журналы соответствующего Compose-проекта.\n'
