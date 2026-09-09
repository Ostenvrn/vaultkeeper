#!/bin/bash
# ============================================
# restore.sh — восстановление системы из снапшота
# Использование: ./restore.sh [путь_к_снапшоту]
# ============================================

set -e  # Остановка при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 1. Проверка аргументов ---
if [ -z "$1" ]; then
    # Если снапшот не указан — берём последний
    SNAPSHOT_FILE=$(ls -t snapshots/snapshot_*.json 2>/dev/null | head -1)
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
    
    # Проверяем, есть ли Nginx в снапшоте
    NGINX_INSTALLED=$(jq -r '.services.nginx.installed' "$SNAPSHOT_FILE" 2>/dev/null)
    if [ "$NGINX_INSTALLED" != "true" ]; then
        echo -e "${YELLOW}⚠️ Nginx не был установлен в снапшоте, пропускаю${NC}"
        return 0
    fi
    
    # Проверяем, установлен ли Nginx сейчас
    if ! command -v nginx &> /dev/null; then
        echo -e "${YELLOW}⚠️ Nginx не установлен в системе, устанавливаю...${NC}"
        sudo apt update && sudo apt install -y nginx
    fi
    
    # Извлекаем конфиг из снапшота
    CONFIG=$(jq -r '.services.nginx.configs["/etc/nginx/nginx.conf"]' "$SNAPSHOT_FILE")
    if [ -z "$CONFIG" ] || [ "$CONFIG" = "null" ]; then
        echo -e "${RED}❌ Ошибка: Не найден конфиг Nginx в снапшоте${NC}"
        return 1
    fi
    
    # Сохраняем бэкап текущего конфига
    if [ -f /etc/nginx/nginx.conf ]; then
        sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
        echo -e "${YELLOW}📁 Бэкап текущего конфига сохранён в /etc/nginx/nginx.conf.bak${NC}"
    fi
    
    # Записываем новый конфиг
    echo "$CONFIG" | sudo tee /etc/nginx/nginx.conf > /dev/null
    
    # Проверяем конфиг
    if sudo nginx -t 2>/dev/null; then
        sudo systemctl restart nginx
        echo -e "${GREEN}✅ Nginx успешно восстановлен и перезапущен${NC}"
    else
        echo -e "${RED}❌ Ошибка: Невалидный конфиг Nginx${NC}"
        echo -e "${YELLOW}📁 Восстанавливаю бэкап...${NC}"
        sudo cp /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
        sudo systemctl restart nginx
        return 1
    fi
}

# --- 3. Функция восстановления SSH ---
restore_ssh() {
    echo -e "${YELLOW}📦 Восстановление SSH...${NC}"
    
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
    
    # Сохраняем бэкап
    if [ -f /etc/ssh/sshd_config ]; then
        sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    fi
    
    echo "$CONFIG" | sudo tee /etc/ssh/sshd_config > /dev/null
    sudo systemctl restart ssh
    echo -e "${GREEN}✅ SSH успешно восстановлен${NC}"
}

# --- 4. Функция восстановления Docker ---
restore_docker() {
    echo -e "${YELLOW}📦 Восстановление Docker...${NC}"
    
    DOCKER_INSTALLED=$(jq -r '.services.docker.installed' "$SNAPSHOT_FILE" 2>/dev/null)
    if [ "$DOCKER_INSTALLED" != "true" ]; then
        echo -e "${YELLOW}⚠️ Docker не был установлен в снапшоте, пропускаю${NC}"
        return 0
    fi
    
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}⚠️ Docker не установлен в системе, устанавливаю...${NC}"
        curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh
        sudo usermod -aG docker $USER
    fi
    
    # Проверяем, есть ли контейнеры в снапшоте
    CONTAINER_COUNT=$(jq '.services.docker.containers | length' "$SNAPSHOT_FILE" 2>/dev/null)
    if [ "$CONTAINER_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}🐳 Восстановление Docker-контейнеров...${NC}"
        
        # Проходим по всем контейнерам в снапшоте
        for i in $(seq 0 $((CONTAINER_COUNT - 1))); do
            NAME=$(jq -r ".services.docker.containers[$i].name" "$SNAPSHOT_FILE")
            IMAGE=$(jq -r ".services.docker.containers[$i].image" "$SNAPSHOT_FILE")
            
            if [ "$NAME" != "null" ] && [ "$NAME" != "" ]; then
                echo -e "${YELLOW}  📦 Восстанавливаю контейнер: $NAME ($IMAGE)${NC}"
                docker rm -f "$NAME" 2>/dev/null || true
                docker run -d --name "$NAME" "$IMAGE" || echo -e "${YELLOW}⚠️ Не удалось запустить $NAME (возможно, нужны доп. параметры)${NC}"
            fi
        done
        echo -e "${GREEN}✅ Docker-контейнеры восстановлены${NC}"
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
        echo -e "${YELLOW}ℹ️ Нет cron-задач для восстановления${NC}"
        return 0
    fi
    
    # Сохраняем текущий crontab как бэкап
    crontab -l 2>/dev/null > /tmp/crontab.bak || true
    
    # Очищаем и записываем новые задачи
    crontab -r 2>/dev/null || true
    echo "$CRONTABS" | crontab -
    
    echo -e "${GREEN}✅ Cron-задачи восстановлены${NC}"
}

# --- 6. ОСНОВНАЯ ЛОГИКА ---

# Проверяем, установлен ли jq (парсер JSON)
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}📦 Устанавливаю jq (парсер JSON)...${NC}"
    sudo apt update && sudo apt install -y jq
fi

# Восстанавливаем всё по порядку
restore_nginx
restore_ssh
restore_docker
restore_cron

echo -e "\n${GREEN}✅ Восстановление завершено!${NC}"
echo -e "${GREEN}📊 Проверь свои сервисы:${NC}"
echo "  systemctl status nginx"
echo "  systemctl status ssh"
echo "  docker ps"
echo "  crontab -l"
