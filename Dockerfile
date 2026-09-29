# ============================================
# vaultkeeper — Dockerfile для ВОССТАНОВЛЕНИЯ
# ============================================
# КОММИТ: фича: Dockerfile для привилегированного восстановления
# Причина: восстановление требует доступа к системным путям хоста.
# Решение: контейнер запускается с --privileged -v /:/host,
#          внутри работает restore.sh с HOST_ROOT=/host.
# ВАЖНО: контейнер работает от root — это осознанное решение,
#        потому что запись в /host/etc требует прав.
# ============================================

FROM python:3.12-slim

LABEL maintainer="Ostenvrn" \
      description="vaultkeeper — восстановление инфраструктуры (privileged)" \
      org.opencontainers.image.source="https://github.com/Ostenvrn/vaultkeeper"

# Утилиты, нужные restore.sh и run.sh:
#   jq     — парсинг JSON-снапшотов
#   curl   — установка Docker (если нужно)
#   procps — pkill -HUP для SSH
#   findutils — find для поиска снапшотов
#   coreutils — базовые утилиты
#   bash   — restore.sh использует bash-специфику
RUN apt-get update && apt-get install -y --no-install-recommends \
        jq \
        curl \
        procps \
        findutils \
        coreutils \
        bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Копируем скрипты и код
COPY src/ ./src/
COPY restore.sh ./
COPY run.sh ./
COPY test_scanner.py ./
COPY pyproject.toml ./

# Делаем скрипты исполняемыми
RUN chmod +x restore.sh run.sh

# ============================================
# ВАЖНО: пользователь root
# ============================================
# Здесь мы НЕ переключаемся на non-root, потому что:
#   - restore.sh пишет в /host/etc/...
#   - нужны права для chmod 600, chown 0:0
#   - chroot требует root
#
# Безопасность обеспечивается на уровне запуска:
#   docker run --privileged -v /:/host ...
#
# Если хочешь запускать ТОЛЬКО scanner (без restore) — создай
# отдельный образ с USER appuser.
# ============================================

# По умолчанию запускается scanner (run.sh)
# Для восстановления переопредели entrypoint: -e HOST_ROOT=/host restore.sh
ENTRYPOINT ["./run.sh"]
