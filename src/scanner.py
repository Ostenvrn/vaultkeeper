#!/usr/bin/env python3
import os
import json
import datetime
import subprocess
from pathlib import Path

class SystemScanner:
    def __init__(self):
        self.snapshot = {
            "timestamp": datetime.datetime.now().isoformat(),
            "hostname": os.uname().nodename,
            "services": {}
        }
    
    def check_nginx(self):
        """Сбор информации о Nginx"""
        result = {"installed": False, "configs": {}, "version": None}
        
        nginx_path = "/etc/nginx"
        if os.path.exists(nginx_path):
            result["installed"] = True
            
            # Версия
            try:
                cmd = subprocess.run(["nginx", "-v"], stderr=subprocess.PIPE, text=True)
                result["version"] = cmd.stderr.strip().split("/")[1]
            except:
                result["version"] = "unknown"
            
            # Конфиги (читаем полностью)
            config_files = [
                "/etc/nginx/nginx.conf",
                "/etc/nginx/sites-available/default"
            ]
            
            for file_path in config_files:
                if os.path.exists(file_path):
                    try:
                        with open(file_path, 'r') as f:
                            result["configs"][file_path] = f.read()
                    except:
                        result["configs"][file_path] = "Ошибка чтения"
        
        self.snapshot["services"]["nginx"] = result
    
    def check_ssh(self):
        """Сбор информации о SSH"""
        result = {"installed": False, "configs": {}, "version": None}
        
        ssh_path = "/etc/ssh"
        if os.path.exists(ssh_path):
            result["installed"] = True
            
            # Версия
            try:
                cmd = subprocess.run(["ssh", "-V"], stderr=subprocess.PIPE, text=True)
                result["version"] = cmd.stderr.strip().split(",")[0].replace("OpenSSH_", "")
            except:
                result["version"] = "unknown"
            
            # Конфиги
            config_files = [
                "/etc/ssh/ssh_config",
                "/etc/ssh/sshd_config"
            ]
            
            for file_path in config_files:
                if os.path.exists(file_path):
                    try:
                        with open(file_path, 'r') as f:
                            result["configs"][file_path] = f.read()
                    except:
                        result["configs"][file_path] = "Ошибка чтения"
        
        self.snapshot["services"]["ssh"] = result
    
    def check_docker(self):
        """Сбор информации о Docker"""
        result = {"installed": False, "version": None, "containers": [], "images": []}
        
        try:
            cmd = subprocess.run(["docker", "--version"], capture_output=True, text=True)
            if cmd.returncode == 0:
                result["installed"] = True
                result["version"] = cmd.stdout.strip().split()[2].replace(",", "")
                
                # Список контейнеров
                containers = subprocess.run(
                    ["docker", "ps", "-a", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}"],
                    capture_output=True, text=True
                )
                for line in containers.stdout.strip().split("\n"):
                    if line:
                        parts = line.split("\t")
                        result["containers"].append({
                            "name": parts[0] if len(parts) > 0 else "unknown",
                            "image": parts[1] if len(parts) > 1 else "unknown",
                            "status": parts[2] if len(parts) > 2 else "unknown"
                        })
                
                # Список образов
                images = subprocess.run(
                    ["docker", "images", "--format", "{{.Repository}}\t{{.Tag}}\t{{.Size}}"],
                    capture_output=True, text=True
                )
                for line in images.stdout.strip().split("\n"):
                    if line:
                        parts = line.split("\t")
                        result["images"].append({
                            "repository": parts[0] if len(parts) > 0 else "unknown",
                            "tag": parts[1] if len(parts) > 1 else "latest",
                            "size": parts[2] if len(parts) > 2 else "unknown"
                        })
        except:
            result["installed"] = False
        
        self.snapshot["services"]["docker"] = result
    
    def check_cron(self):
        """Сбор информации о Cron"""
        result = {"installed": False, "status": "unknown", "crontabs": []}
        
        try:
            cmd = subprocess.run(["systemctl", "is-active", "cron"], capture_output=True, text=True)
            if cmd.stdout.strip() == "active":
                result["installed"] = True
                result["status"] = "active"
            
            # Читаем crontab текущего пользователя
            try:
                crontab = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
                if crontab.returncode == 0:
                    for line in crontab.stdout.strip().split("\n"):
                        if line and not line.startswith("#"):
                            result["crontabs"].append(line)
            except:
                pass
        except:
            result["installed"] = False
        
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
        filename = f"{output_dir}/snapshot_{datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.json"
        with open(filename, 'w') as f:
            json.dump(self.snapshot, f, indent=2, ensure_ascii=False)
        return filename

if __name__ == "__main__":
    scanner = SystemScanner()
    snapshot = scanner.scan()
    
    # Сохраняем
    filename = scanner.save()
    print(f"\n✅ Снапшот сохранён: {filename}")
    
    # Показываем краткий результат
    print("\n📊 КРАТКАЯ СВОДКА:")
    for service, data in snapshot["services"].items():
        status = "✅" if data.get("installed") else "❌"
        version = data.get("version", "N/A")
        print(f"  {status} {service.upper()}: {version}")
