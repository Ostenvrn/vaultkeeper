#!/bin/bash
# ============================================
# restore.sh — восстановление системы из снапшота
# Использование:
#   На хосте:      ./restore.sh [путь_к_снапшоту]
#   В контейнере:  HOST_ROOT=/host ./restore.sh [путь_к_снапшоту]
# ============================================

set -e  # Остановка при любой ошибке

# ============================================
# КОММИТ: рефактор: поддержка HOST_ROOT для работы в контейнере
# Причина: restore.sh должен работать и на хосте, и в привилегированном
#          контейнере (--privileged -v /:/host), где корень хоста — в /host.
# Решение: переменная HOST_ROOT (пусто = хост, /host = контейнер).
#          Все системные пути получают префикс ${HOST_ROOT}.
#          systemctl заменён на chroot ${HOST_ROOT} systemctl ...
# ============================================

# HOST_ROOT: пусто (работа на хосте) или /host (работа в контейнере)
HOST_ROOT="${HOST_ROOT:-}"

# Определяем: работаем в контейнере или на хосте
if [ -n "$HOST_ROOT" ]; then
    echo "🐳 Режим контейнера: корень хоста смонтирован в $HOST_ROOT"
    # Проверяем, что корень хоста действительно смонтирован
    if [ ! -d "${HOST_ROOT}/etc" ]; then
        echo "❌ Ошибка: ${HOST_ROOT}/etc не существует."
        echo "   Запусти контейнер с флагом: -v /:/host"
        exit 1
    fi
    # В контейнере мы уже root, sudo не нужен и часто отсутствует
    SUDO=""
else
    echo "🖥️  Режим хоста: работаем напрямую с системой"
    # На хосте используем sudo (если не root)
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
    fi
fi

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================
# Функция: перезагрузить сервис через systemd хоста
# В контейнере systemctl хоста недоступен напрямую.
# Используем chroot в HOST_ROOT.
# ============================================
host_systemctl() {
    local action="$1"   # reload, restart, status
    local service="$2"  # ssh, nginx

    if [ -n "$HOST_ROOT" ]; then
        # В контейнере — chroot в корень хоста и запускаем systemctl там
        chroot "${HOST_ROOT}" systemctl "$action" "$service"
    else
        # На хосте — обычный systemctl
        $SUDO systemctl "$action" "$service"
    fi
}

# --- 1. Проверка аргументов ---
if [ -z "$1" ]; then
    # Если снапшот не указан — берём последний по времени.
    # Используем find вместо ls — надёжнее для имён с пробелами/спецсимволами.
    # -printf '%T@ %p\n' — время модификации + путь, sort -rn — сортировка по убыванию.
    SNAPSHOT_FILE=$(find snapshots -maxdepth 1 -name "snapshot_*.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

    if [ -z "$SNAPSHOT_FILE" ]; then
        echo -e "${RED}❌ Ошибка: Нет снапшотов в папке snapshots/${NC}"
        echo "Использование: ./restore.sh [путь_к_снапшоту]"
        exit 1
    fi
    echo -e "${YELLOW}ℹ️ Снапшот не указан, беру последний: $SNAPSHOT_FILE${NC}"
else
    SNAPSHOT_FILE="$1"
    if [ ! -f "$SNAPSHOT_FILE" ]; then
        echo -e "${RED}❌ Ошибка: Файл $SNAPSHOT_FILE не найден${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}🔧 Начинаю восстановление из: $SNAPSHOT_FILE${NC}"

# --- 2. Функция восстановления Nginx ---
restore_nginx() {
    echo -e "${YELLOW}📦 Восстановление Nginx...${NC}"

    NGINX_INSTALLED=$(jq -r '.services.nginx.installed' "$SNAPSHOT_FILE" 2>/dev/null)
    if [ "$NGINX_INSTALLED" != "true" ]; then
        echo -e "${YELLOW}⚠️ Nginx не был установлен в снапшоте, пропускаю${NC}"
        return 0
    fi

    # В контейнере мы не можем установить nginx на хост через apt.
    # Проверяем наличие конфига, а не бинарника.
    NGINX_CONF="${HOST_ROOT}/etc/nginx/nginx.conf"

    if [ ! -d "${HOST_ROOT}/etc/nginx" ]; then
        echo -e "${YELLOW}⚠️ ${HOST_ROOT}/etc/nginx не существует, пропускаю Nginx${NC}"
        return 0
    fi

    # Извлекаем конфиг из снапшота (ключ в снапшоте — без префикса)
    CONFIG=$(jq -r '.services.nginx.configs["/etc/nginx/nginx.conf"]' "$SNAPSHOT_FILE")
    if [ -z "$CONFIG" ] || [ "$CONFIG" = "null" ]; then
        echo -e "${RED}❌ Ошибка: Не найден конфиг Nginx в снапшоте${NC}"
        return 1
    fi

    # Бэкап текущего конфига
    if [ -f "$NGINX_CONF" ]; then
        $SUDO cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"
        echo -e "${YELLOW}📁 Бэкап текущего конфига сохранён${NC}"
    fi

    # Записываем новый конфиг
    echo "$CONFIG" | $SUDO tee "$NGINX_CONF" > /dev/null

    # Проверяем конфиг.
    # В контейнере nginx не установлен — проверяем через chroot хоста.
    local nginx_test_ok=false
    if [ -n "$HOST_ROOT" ]; then
        if chroot "${HOST_ROOT}" nginx -t 2>/dev/null; then
            nginx_test_ok=true
        fi
    else
        if $SUDO nginx -t 2>/dev/null; then
            nginx_test_ok=true
        fi
    fi

    if [ "$nginx_test_ok" = true ]; then
        host_systemctl restart nginx
        echo -e "${GREEN}✅ Nginx успешно восстановлен и перезапущен${NC}"
    else
        echo -e "${RED}❌ Ошибка: Невалидный конфиг Nginx${NC}"
        echo -e "${YELLOW}📁 Восстанавливаю бэкап...${NC}"
        LATEST_BAK=$(find "${HOST_ROOT}/etc/nginx" -maxdepth 1 -name "nginx.conf.bak.*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [ -n "$LATEST_BAK" ]; then
            $SUDO cp "$LATEST_BAK" "$NGINX_CONF"
            host_systemctl restart nginx
        fi
        return 1
    fi
}

# --- 3. Функция восстановления SSH ---
restore_ssh() {
    echo -e "${YELLOW}📦 Восстановление SSH...${NC}"

    # ============================================
    # КОММИТ: фикс: безопасное восстановление sshd_config
    # Причина: старый код перезаписывал конфиг и делал restart
    #          без проверки через `sshd -t`. Если конфиг битый —
    #          SSH не поднимается, доступ к серверу теряется.
    # Решение:
    #   1. Бэкап текущего конфига с timestamp
    #   2. Новый конфиг во временный файл
    #   3. Проверка синтаксиса через `sshd -t -f <tmp>`
    #   4. Применение + `reload` (не restart!)
    #   5. Откат при ошибке
    # Обновлено: все пути через ${HOST_ROOT} для работы в контейнере.
    # ============================================

    SSH_INSTALLED=$(jq -r '.services.ssh.installed' "$SNAPSHOT_FILE" 2>/dev/null)
    if [ "$SSH_INSTALLED" != "true" ]; then
        echo -e "${YELLOW}⚠️ SSH не был установлен в снапшоте, пропускаю${NC}"
        return 0
    fi

    CONFIG=$(jq -r '.services.ssh.configs["/etc/ssh/sshd_config"]' "$SNAPSHOT_FILE")
    if [ -z "$CONFIG" ] || [ "$CONFIG" = "null" ]; then
        echo -e "${YELLOW}⚠️ Конфиг SSH не найден в снапшоте, пропускаю${NC}"
        return 0
    fi

    SSH_CONFIG="${HOST_ROOT}/etc/ssh/sshd_config"
    if [ ! -d "${HOST_ROOT}/etc/ssh" ]; then
        echo -e "${RED}❌ ${HOST_ROOT}/etc/ssh не существует${NC}"
        return 1
    fi

    # --- Шаг 1: Бэкап ---
    BACKUP_FILE="${SSH_CONFIG}.bak.$(date +%s)"
    if [ -f "$SSH_CONFIG" ]; then
        $SUDO cp "$SSH_CONFIG" "$BACKUP_FILE"
        echo -e "${YELLOW}📁 Бэкап: $BACKUP_FILE${NC}"
    fi

    # --- Шаг 2: Новый конфиг во временный файл ---
    TMP_CONFIG=$(mktemp)
    echo "$CONFIG" > "$TMP_CONFIG"

    # --- Шаг 3: Проверка синтаксиса ---
    # sshd -t проверяет конфиг. В контейнере sshd может отсутствовать —
    # используем chroot хоста.
    local sshd_test_ok=false
    if [ -n "$HOST_ROOT" ]; then
        # Копируем временный конфиг внутрь chroot, чтобы sshd его видел
        TMP_IN_CHROOT="${HOST_ROOT}/tmp/sshd_test_$$.conf"
        $SUDO cp "$TMP_CONFIG" "$TMP_IN_CHROOT"
        if chroot "${HOST_ROOT}" sshd -t -f "/tmp/sshd_test_$$.conf" 2>/tmp/sshd_test_error; then
            sshd_test_ok=true
        fi
        $SUDO rm -f "$TMP_IN_CHROOT"
    else
        if $SUDO sshd -t -f "$TMP_CONFIG" 2>/tmp/sshd_test_error; then
            sshd_test_ok=true
        fi
    fi

    if [ "$sshd_test_ok" != true ]; then
        echo -e "${RED}❌ Новый sshd_config не прошёл проверку${NC}"
        cat /tmp/sshd_test_error
        rm -f "$TMP_CONFIG" /tmp/sshd_test_error
        return 1
    fi
    echo -e "${GREEN}✅ Синтаксис sshd_config корректен${NC}"

    # --- Шаг 4: Применяем ---
    $SUDO cp "$TMP_CONFIG" "$SSH_CONFIG"
    $SUDO chmod 600 "$SSH_CONFIG"
    if [ -z "$HOST_ROOT" ]; then
        $SUDO chown root:root "$SSH_CONFIG"
    else
        # В контейнере chown root:root внутри /host — это UID 0 хоста
        $SUDO chown 0:0 "$SSH_CONFIG"
    fi
    rm -f "$TMP_CONFIG" /tmp/sshd_test_error

    # --- Шаг 5: reload ---
    if host_systemctl reload ssh 2>/dev/null; then
        echo -e "${GREEN}✅ SSH восстановлен (reload ssh)${NC}"
    elif host_systemctl reload sshd 2>/dev/null; then
        echo -e "${GREEN}✅ SSH восстановлен (reload sshd)${NC}"
    else
        echo -e "${YELLOW}⚠️ reload не удался, пробую HUP${NC}"
        if [ -n "$HOST_ROOT" ]; then
            chroot "${HOST_ROOT}" pkill -HUP sshd || echo -e "${RED}❌ HUP не удался${NC}"
        else
            $SUDO pkill -HUP sshd || echo -e "${RED}❌ HUP не удался${NC}"
        fi
    fi
}

# --- 4. Функция восстановления Docker ---
restore_docker() {
    echo -e "${YELLOW}📦 Восстановление Docker...${NC}"

    DOCKER_INSTALLED=$(jq -r '.services.docker.installed' "$SNAPSHOT_FILE" 2>/dev/null)
    if [ "$DOCKER_INSTALLED" != "true" ]; then
        echo -e "${YELLOW}⚠️ Docker не был установлен в снапшоте, пропускаю${NC}"
        return 0
    fi

    # В контейнере мы не можем установить docker на хост.
    # Проверяем наличие docker.sock хоста.
    if [ -n "$HOST_ROOT" ]; then
        if [ ! -S "${HOST_ROOT}/var/run/docker.sock" ]; then
            echo -e "${YELLOW}⚠️ docker.sock хоста не смонтирован, пропускаю Docker${NC}"
            return 0
        fi
        # Используем docker CLI хоста через chroot
        DOCKER_CMD="chroot ${HOST_ROOT} docker"
    else
        if ! command -v docker &> /dev/null; then
            echo -e "${YELLOW}⚠️ Docker не установлен, пропускаю${NC}"
            return 0
        fi
        DOCKER_CMD="docker"
    fi

    CONTAINER_COUNT=$(jq '.services.docker.containers | length' "$SNAPSHOT_FILE" 2>/dev/null)
    if [ "$CONTAINER_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}🐳 Восстановление контейнеров...${NC}"
        for i in $(seq 0 $((CONTAINER_COUNT - 1))); do
            NAME=$(jq -r ".services.docker.containers[$i].name" "$SNAPSHOT_FILE")
            IMAGE=$(jq -r ".services.docker.containers[$i].image" "$SNAPSHOT_FILE")
            if [ "$NAME" != "null" ] && [ "$NAME" != "" ]; then
                echo -e "${YELLOW}  📦 $NAME ($IMAGE)${NC}"
                $DOCKER_CMD rm -f "$NAME" 2>/dev/null || true
                $DOCKER_CMD run -d --name "$NAME" "$IMAGE" || echo -e "${YELLOW}⚠️ Не удалось запустить $NAME${NC}"
            fi
        done
        echo -e "${GREEN}✅ Контейнеры восстановлены${NC}"
    else
        echo -e "${YELLOW}ℹ️ Нет контейнеров для восстановления${NC}"
    fi
}

# --- 5. Функция восстановления Cron ---
restore_cron() {
    echo -e "${YELLOW}📦 Восстановление Cron...${NC}"

    CRON_INSTALLED=$(jq -r '.services.cron.installed' "$SNAPSHOT_FILE" 2>/dev/null)
    if [ "$CRON_INSTALLED" != "true" ]; then
        echo -e "${YELLOW}⚠️ Cron не был установлен в снапшоте, пропускаю${NC}"
        return 0
    fi

    CRONTABS=$(jq -r '.services.cron.crontabs[]' "$SNAPSHOT_FILE" 2>/dev/null)
    if [ -z "$CRONTABS" ] || [ "$CRONTABS" = "null" ]; then
        echo -e "${YELLOW}ℹ️ Нет cron-задач${NC}"
        return 0
    fi

    # В контейнере работаем через chroot
    if [ -n "$HOST_ROOT" ]; then
        # Сохраняем текущий crontab хоста
        chroot "${HOST_ROOT}" crontab -l 2>/dev/null > /tmp/crontab.bak || true
        chroot "${HOST_ROOT}" crontab -r 2>/dev/null || true
        echo "$CRONTABS" | chroot "${HOST_ROOT}" crontab -
    else
        crontab -l 2>/dev/null > /tmp/crontab.bak || true
        crontab -r 2>/dev/null || true
        echo "$CRONTABS" | crontab -
    fi

    echo -e "${GREEN}✅ Cron-задачи восстановлены${NC}"
}

# --- 6. ОСНОВНАЯ ЛОГИКА ---

# Проверяем, установлен ли jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ jq не установлен. Установи: apt install jq${NC}"
    exit 1
fi

# Восстанавливаем всё по порядку
restore_nginx
restore_ssh
restore_docker
restore_cron

echo -e "\n${GREEN}✅ Восстановление завершено!${NC}"
