#!/usr/bin/env python3
"""
scanner.py — сбор информации о системе для vaultkeeper.

Поддерживает работу в контейнере через переменную HOST_ROOT:
  - HOST_ROOT не задан  → сканируем локальную систему
  - HOST_ROOT=/host     → сканируем хост, смонтированный в /host

В режиме контейнера команды (nginx -v, ssh -V, systemctl, docker)
запускаются через chroot ${HOST_ROOT} ... — чтобы видеть систему хоста.
"""

import datetime
import json
import os
import subprocess

# ============================================
# КОММИТ: фикс: поддержка HOST_ROOT + chroot для команд хоста
# Причина: в контейнере /etc/nginx — это контейнерный /etc.
#          Нужен /host/etc/nginx (хоста). Плюс команды (nginx -v, ssh -V,
#          systemctl, docker) не работают без chroot.
# Решение:
#   - host_path() добавляет префикс HOST_ROOT к путям чтения
#   - run_host_cmd() запускает команды через chroot в HOST_ROOT
# ============================================

# Префикс: пусто (хост) или /host (контейнер)
HOST_ROOT = os.environ.get("HOST_ROOT", "")


def host_path(path: str) -> str:
    """Добавляет префикс HOST_ROOT к системному пути."""
    return f"{HOST_ROOT}{path}"


def run_host_cmd(cmd: list, **kwargs):
    """
    Запускает команду в контексте хоста.

    На хосте:       subprocess.run(cmd)
    В контейнере:   chroot HOST_ROOT cmd

    Возвращает subprocess.CompletedProcess или None при ошибке.
    """
    try:
        if HOST_ROOT:
            # В контейнере — через chroot, чтобы команда видела систему хоста
            return subprocess.run(["chroot", HOST_ROOT, *cmd], **kwargs)
        else:
            return subprocess.run(cmd, **kwargs)
    except (FileNotFoundError, PermissionError, OSError):
        return None


class SystemScanner:
    def __init__(self):
        self.snapshot = {
            "timestamp": datetime.datetime.now().isoformat(),
            "hostname": os.uname().nodename,
            "host_root": HOST_ROOT or "(host)",
            "services": {},
        }

    def check_nginx(self):
        """Сбор информации о Nginx"""
        result = {"installed": False, "configs": {}, "version": None}

        nginx_path = host_path("/etc/nginx")
        if os.path.exists(nginx_path):
            result["installed"] = True

            # Версия — через chroot в контейнере
            cmd = run_host_cmd(["nginx", "-v"], stderr=subprocess.PIPE, text=True)
            if cmd and cmd.stderr:
                try:
                    result["version"] = cmd.stderr.strip().split("/")[1]
                except (IndexError, ValueError):
                    result["version"] = "unknown"
            else:
                result["version"] = "unknown"

            # Конфиги
            config_files = [
                "/etc/nginx/nginx.conf",
                "/etc/nginx/sites-available/default",
                "/etc/nginx/sites-available/osten-devops-Notebook",
            ]

            for file_path in config_files:
                full_path = host_path(file_path)
                if os.path.exists(full_path):
                    try:
                        with open(full_path) as f:
                            result["configs"][file_path] = f.read()
                    except Exception:
                        result["configs"][file_path] = "Ошибка чтения"

        self.snapshot["services"]["nginx"] = result

    def check_ssh(self):
        """Сбор информации о SSH"""
        result = {"installed": False, "configs": {}, "version": None}

        ssh_path = host_path("/etc/ssh")
        if os.path.exists(ssh_path):
            result["installed"] = True

            # Версия — через chroot
            cmd = run_host_cmd(["ssh", "-V"], stderr=subprocess.PIPE, text=True)
            if cmd and cmd.stderr:
                try:
                    result["version"] = cmd.stderr.strip().split(",")[0].replace("OpenSSH_", "")
                except (IndexError, ValueError):
                    result["version"] = "unknown"
            else:
                result["version"] = "unknown"

            config_files = [
                "/etc/ssh/ssh_config",
                "/etc/ssh/sshd_config",
            ]

            for file_path in config_files:
                full_path = host_path(file_path)
                if os.path.exists(full_path):
                    try:
                        with open(full_path) as f:
                            result["configs"][file_path] = f.read(1000)
                    except Exception:
                        result["configs"][file_path] = "Ошибка чтения"

        self.snapshot["services"]["ssh"] = result

    def check_docker(self):
        """Сбор информации о Docker"""
        result = {"installed": False, "version": None, "containers": [], "images": []}

        # В контейнере — chroot /host docker ...
        cmd = run_host_cmd(["docker", "--version"], capture_output=True, text=True)
        if cmd and cmd.returncode == 0:
            result["installed"] = True
            try:
                result["version"] = cmd.stdout.strip().split()[2].replace(",", "")
            except IndexError:
                result["version"] = "unknown"

            containers = run_host_cmd(
                ["docker", "ps", "-a", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}"],
                capture_output=True,
                text=True,
            )
            if containers and containers.returncode == 0:
                for line in containers.stdout.strip().split("\n"):
                    if line:
                        parts = line.split("\t")
                        result["containers"].append(
                            {
                                "name": parts[0] if len(parts) > 0 else "unknown",
                                "image": parts[1] if len(parts) > 1 else "unknown",
                                "status": parts[2] if len(parts) > 2 else "unknown",
                            }
                        )

            images = run_host_cmd(
                ["docker", "images", "--format", "{{.Repository}}\t{{.Tag}}\t{{.Size}}"],
                capture_output=True,
                text=True,
            )
            if images and images.returncode == 0:
                for line in images.stdout.strip().split("\n"):
                    if line:
                        parts = line.split("\t")
                        result["images"].append(
                            {
                                "repository": parts[0] if len(parts) > 0 else "unknown",
                                "tag": parts[1] if len(parts) > 1 else "latest",
                                "size": parts[2] if len(parts) > 2 else "unknown",
                            }
                        )

        self.snapshot["services"]["docker"] = result

    def check_cron(self):
        """Сбор информации о Cron"""
        result = {"installed": False, "status": "unknown", "crontabs": []}

        # ============================================
        # КОММИТ: фикс: определение cron без systemctl
        # Причина: systemctl не работает через chroot (нужен D-Bus).
        # Решение: несколько fallback-проверок:
        #   1. systemctl is-active (сработает на хосте)
        #   2. pgrep -x cron (проверка процесса)
        #   3. наличие файлов /etc/crontab, /etc/cron.d/, /var/spool/cron/crontabs/
        # ============================================

        # Проверка 1: systemctl (работает только на хосте)
        cmd = run_host_cmd(["systemctl", "is-active", "cron"], capture_output=True, text=True)
        if cmd and cmd.stdout and cmd.stdout.strip() == "active":
            result["installed"] = True
            result["status"] = "active"

        # Проверка 2: pgrep -x cron (работает через chroot)
        if not result["installed"]:
            proc = run_host_cmd(["pgrep", "-x", "cron"], capture_output=True, text=True)
            if proc and proc.returncode == 0 and proc.stdout.strip():
                result["installed"] = True
                result["status"] = "active (process)"

        # Проверка 3: наличие файлов crontab
        if not result["installed"]:
            cron_paths = [
                "/etc/crontab",
                "/etc/cron.d",
                "/var/spool/cron/crontabs",
                "/var/spool/cron",
            ]
            for path in cron_paths:
                if os.path.exists(host_path(path)):
                    result["installed"] = True
                    result["status"] = "installed (files)"
                    break

        # Список cron-задач пользователя
        crontab = run_host_cmd(["crontab", "-l"], capture_output=True, text=True)
        if crontab and crontab.returncode == 0:
            for line in crontab.stdout.strip().split("\n"):
                if line and not line.startswith("#"):
                    result["crontabs"].append(line)

        self.snapshot["services"]["cron"] = result

    def scan(self):
        """Запуск полного сканирования"""
        print("🔍 Начинаю сканирование системы...")
        self.check_nginx()
        print("  ✅ Nginx")
        self.check_ssh()
        print("  ✅ SSH")
        self.check_docker()
        print("  ✅ Docker")
        self.check_cron()
        print("  ✅ Cron")
        return self.snapshot

    def save(self, output_dir="snapshots"):
        """Сохранение снапшота в файл"""
        os.makedirs(output_dir, exist_ok=True)
        filename = (
            f"{output_dir}/snapshot_{datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.json"
        )
        with open(filename, "w") as f:
            json.dump(self.snapshot, f, indent=2, ensure_ascii=False)
        return filename


if __name__ == "__main__":
    scanner = SystemScanner()
    snapshot = scanner.scan()

    filename = scanner.save()
    print(f"\n✅ Снапшот сохранён: {filename}")

    print("\n📊 КРАТКАЯ СВОДКА:")
    for service, data in snapshot["services"].items():
        status = "✅" if data.get("installed") else "❌"
        version = data.get("version", "N/A")
        print(f"  {status} {service.upper()}: {version}")
