# 🔐 VaultKeeper — аудит и восстановление инфраструктуры

[![CI](https://github.com/Ostenvrn/vaultkeeper/actions/workflows/ci.yml/badge.svg)](https://github.com/Ostenvrn/vaultkeeper/actions/workflows/ci.yml)
[![Python](https://img.shields.io/badge/python-3.12-blue.svg)](https://www.python.org/)
[![Docker](https://img.shields.io/badge/docker-ready-blue.svg)](https://www.docker.com/)
[![ShellCheck](https://img.shields.io/badge/shellcheck-passing-brightgreen.svg)](https://www.shellcheck.net/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

VaultKeeper сканирует конфигурации ключевых служб (Nginx, SSH, Docker, Cron),
сохраняет снапшоты в JSON и умеет восстанавливать систему из любого снапшота.

Работает **в двух режимах**:
- 🖥️ **На хосте** — обычный запуск, сканирует локальную систему.
- 🐳 **В привилегированном контейнере** — сканирует и восстанавливает систему
  хоста через `-v /:/host` и `chroot`.

---

## ✨ Возможности

- 📸 **Снапшоты системы** — версии служб, конфиги, список контейнеров, crontab
- 🔄 **Восстановление** — из последнего или конкретного снапшота
- 🛡️ **Безопасное восстановление SSH** — проверка `sshd -t` перед применением,
  `reload` вместо `restart`, откат при ошибке
- 🐳 **Docker-режим** — привилегированный контейнер с доступом к хосту
- 🤖 **Автоматизация** — запуск по cron каждые N минут
- 📝 **Git-история** — опциональный коммит снапшотов
- 🧪 **Линтеры** — `ruff` для Python, `shellcheck` для Bash

---

## 🚀 Быстрый старт

### На хосте (обычный режим)

```bash
# 1. Клонировать репозиторий
git clone https://github.com/Ostenvrn/vaultkeeper.git
cd vaultkeeper

# 2. Установить зависимости
sudo apt install -y jq python3

# 3. Создать первый снапшот
python3 src/scanner.py

# 4. Восстановить из последнего снапшота (ОСТОРОЖНО!)
./restore.sh


## В Docker (привилегированный режим)

docker build -t vaultkeeper:restore .

docker run --rm \
  --privileged \
  -v /:/host \
  -v "$PWD/snapshots:/app/snapshots" \
  vaultkeeper:restore


## Пример вывода:

📂 Рабочая директория: /app
🐳 Режим контейнера: сканируем /host (хост)

🔍 Начинаю сканирование системы...
  ✅ Nginx
  ✅ SSH
  ✅ Docker
  ✅ Cron

📊 КРАТКАЯ СВОДКА:
  ✅ NGINX: 1.24.0 (Ubuntu)
  ✅ SSH: 9.6p1 Ubuntu-3ubuntu13.19
  ✅ DOCKER: 29.1.3
  ✅ CRON: active


## 📋 Команды

| Команда | Что делает |
|---------|-----------|
| `python3 src/scanner.py` | Создать новый снапшот системы |
| `./run.sh` | Полный цикл: сканирование → коммит → пуш |
| `./restore.sh` | Восстановить из **последнего** снапшота |
| `./restore.sh <путь>` | Восстановить из **конкретного** снапшота |
| `ls -la snapshots/` | Список всех снапшотов |
| `crontab -l \| grep vaultkeeper` | Проверить, запускается ли по расписанию |


## 🛡️ Безопасность

### Восстановление SSH — самое опасное место

Если конфиг `sshd_config` битый и применить его с `restart` — **ты потеряешь доступ
к серверу**. VaultKeeper делает это безопасно:

1. **Сохраняет бэкап** текущего конфига с timestamp.
2. **Пишет новый** конфиг во временный файл.
3. **Проверяет синтаксис** через `sshd -t -f <tmp>` — если битый, откат.
4. **Применяет** через `reload` (не `restart`) — не рвёт активные SSH-сессии.
5. **Устанавливает права** `chmod 600` и `chown root:root`.

Ключевой фрагмент `restore.sh`:

```bash
if ! sudo sshd -t -f "$TMP_CONFIG" 2>/tmp/sshd_test_error; then
    echo "❌ Конфиг не прошёл проверку, откат"
    return 1
fi
sudo systemctl reload ssh   # НЕ restart!


## 🏗 Архитектура

```text
vaultkeeper/
├── src/
│   ├── scanner.py           # сбор информации о системе (HOST_ROOT, chroot)
│   └── git_operator.py      # коммит и пуш снапшотов (если git доступен)
├── restore.sh               # восстановление (безопасный SSH, HOST_ROOT)
├── run.sh                   # полный цикл: scan → git commit
├── test_scanner.py          # юнит-тесты
├── Dockerfile               # привилегированный контейнер
├── pyproject.toml           # конфиг ruff
├── snapshots/               # JSON-снапшоты (не в git)
└── .github/workflows/ci.yml # CI: lint + shellcheck


## 📂 Что сохраняется

| Служба | Что сканируется |
|--------|-----------------|
| **Nginx** | `/etc/nginx/nginx.conf`, `sites-available/default`, версия |
| **SSH** | `/etc/ssh/ssh_config`, `sshd_config`, версия |
| **Docker** | Версия, список контейнеров, список образов |
| **Cron** | Статус, список cron-задач пользователя |


## ❓ FAQ

**Q: Как vaultkeeper узнаёт, что запущен в контейнере?**
A: По наличию `/host/etc`. Если есть — `HOST_ROOT=/host`, сканируется хост.
Если нет — работаем с локальной системой.

**Q: Безопасно ли запускать `restore.sh`?**
A: Да, если соблюдать правила: бэкап перед запуском, проверка `sshd -t`,
`reload` вместо `restart`. Все эти проверки уже встроены в скрипт.

**Q: Что если `sshd_config` битый?**
A: `restore.sh` сделает `sshd -t` перед применением. Если конфиг невалиден —
применение отменяется, старый конфиг остаётся. **Доступ не потеряется.**

**Q: Почему контейнер работает от root?**
A: Восстановление требует записи в `/host/etc/...` и `chroot`. Root внутри
контейнера с `--privileged` — осознанное решение. Безопасность обеспечивается
на уровне **запуска**: только свои образы, только с бэкапом.

**Q: Можно ли добавить новую службу (например, PostgreSQL)?**
A: Да. Добавь метод `check_postgresql()` в `scanner.py` и вызови его в `scan()`.
Смотри раздел «Как добавить службу» ниже.


## 🧪 Разработка

```bash
python3 -m venv venv
source venv/bin/activate
pip install ruff

ruff check .
ruff format .

python3 -m unittest test_scanner.py -v

docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable /mnt/restore.sh
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable /mnt/run.sh

🛠 Как добавить новую службу

Пример — PostgreSQL. Открыть src/scanner.py, добавить метод:

def check_postgresql(self):
"""Сбор информации о PostgreSQL"""
result = {"installed": False, "configs": {}, "version": None}

cmd = run_host_cmd(["psql", "--version"], capture_output=True, text=True)
if cmd and cmd.returncode == 0:
result["installed"] = True
result["version"] = cmd.stdout.strip()

config_path = host_path("/etc/postgresql/14/main/postgresql.conf")
if os.path.exists(config_path):
with open(config_path) as f:
result["configs"]["/etc/postgresql/14/main/postgresql.conf"] = f.read()

self.snapshot["services"]["postgresql"] = result

Добавить вызов в scan():

self.check_postgresql()
print(" ✅ PostgreSQL")

Запустить сканер, проверить снапшот.



## 💾 Хранение снапшотов

Сейчас снапшоты хранятся локально в snapshots/ (в .gitignore).

В планах:

    Приватный Git-репозиторий для снапшотов

    S3-совместимое хранилище (MinIO, AWS S3)


## 🛠 Требования

    Linux (Ubuntu/Mint/Debian)

    Python 3.10+

    jq — парсер JSON

    Docker — для контейнерного режима (опционально)

    Nginx, SSH, Cron — сканируются, если установлены (опционально)

## 🔄 CI/CD

GitHub Actions при каждом пуше:

    Lint Python — ruff check .

    Lint Bash — shellcheck restore.sh run.sh

## 🧪 Разработка

python3 -m venv venv
source venv/bin/activate
pip install ruff
ruff check .
ruff format .
python3 -m unittest test_scanner.py -v

## 📄 Лицензия

MIT — используй, форкай, дорабатывай.
