# VaultKeeper — система аудита и восстановления инфраструктуры

VaultKeeper сканирует конфигурации ключевых служб, сохраняет снапшоты и умеет восстанавливать систему из любого снапшота.

---

## 📋 Команды

| Команда | Что делает |
|---------|------------|
| `python3 src/scanner.py` | Создает новый снапшот системы |
| `./restore.sh` | Восстанавливает систему из ПОСЛЕДНЕГО снапшота |
| `./restore.sh snapshots/snapshot_2026-09-09_16-40-21.json` | Восстанавливает из КОНКРЕТНОГО снапшота |
| `./run.sh` | Полный цикл: сканирование → коммит → чистка |
| `crontab -l \| grep vaultkeeper` | Проверить, запускается ли скрипт по расписанию |
| `git log --oneline -5` | Показать последние 5 коммитов (история снапшотов) |
| `ls -la snapshots/` | Список всех сохраненных снапшотов |

---

## 🚀 Быстрый старт

```bash
# 1. Клонировать репозиторий
git clone https://github.com/Ostenvrn/vaultkeeper.git
cd vaultkeeper

# 2. Установить зависимости
sudo apt install -y jq python3

# 3. Создать первый снапшот
python3 src/scanner.py

# 4. (Опционально) Настроить автоматический запуск каждые 5 минут
crontab -e
# Добавить:
*/5 * * * * /home/osten/devops/vaultkeeper/run.sh >> /home/osten/devops/vaultkeeper/logs/cron.log 2>&1


Восстановление
bash

# Из последнего снапшота
./restore.sh

# Из конкретного снапшота
./restore.sh snapshots/snapshot_2026-09-09_16-40-21.json

📂 Что сохраняется
Служба	Что сканируется
Nginx	/etc/nginx/nginx.conf, /etc/nginx/sites-available/default
SSH	/etc/ssh/ssh_config, /etc/ssh/sshd_config
Docker	Версия, список контейнеров, список образов
Cron	Список cron-задач текущего пользователя
🧠 Архитектура

    Сканер собирает конфиги и сохраняет в JSON

    Git-оператор коммитит изменения в локальный репозиторий

    restore.sh восстанавливает систему из любого снапшота

Текущее хранилище

Снапшоты хранятся локально в папке snapshots/. Это сделано для скорости разработки.
Планируемое развитие

В продакшен-среде снапшоты будут храниться в:

    Приватном Git-репозитории

    Или S3-совместимом хранилище

🛠 Требования

    Linux (Ubuntu/Mint/Debian)

    Python 3.6+

    jq (парсер JSON)

    Nginx, Docker, SSH, Cron (опционально, сканер адаптируется)

📄 Лицензия

MIT


    Допустим добавляется новая служба (например, sudo apt install postgresql).

    Ты открываешь src/scanner.py и добавляешь новый метод:

python

def check_postgresql(self):
    result = {"installed": False, "configs": {}, "version": None}
    
    # Проверяем наличие
    try:
        cmd = subprocess.run(["psql", "--version"], capture_output=True, text=True)
        if cmd.returncode == 0:
            result["installed"] = True
            result["version"] = cmd.stdout.strip()
            
            # Читаем конфиг
            if os.path.exists("/etc/postgresql/14/main/postgresql.conf"):
                with open("/etc/postgresql/14/main/postgresql.conf", 'r') as f:
                    result["configs"]["/etc/postgresql/14/main/postgresql.conf"] = f.read()
    except:
        result["installed"] = False
    
    self.snapshot["services"]["postgresql"] = result

    Добавляешь вызов в scan():

self.check_postgresql()
print("  ✅ PostgreSQL")

    Запускаешь сканер, проверяешь снапшот.

    Коммитишь изменения в код.
