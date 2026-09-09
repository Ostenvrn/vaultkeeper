#!/usr/bin/env python3
import os
import subprocess
import datetime
from pathlib import Path

class GitOperator:
    def __init__(self, repo_path="."):
        self.repo_path = Path(repo_path).resolve()
        self.snapshots_dir = self.repo_path / "snapshots"
    
    def commit_snapshot(self, snapshot_file):
        """Делает коммит нового снапшота"""
        os.chdir(self.repo_path)
        
        # Добавляем файл в Git
        subprocess.run(["git", "add", str(snapshot_file)], check=False)
        
        # Создаем коммит
        commit_msg = f"📸 Автоматический снапшот: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
        try:
            result = subprocess.run(
                ["git", "commit", "-m", commit_msg],
                capture_output=True, text=True, check=True
            )
            print(f"✅ Коммит создан: {commit_msg}")
            return True
        except subprocess.CalledProcessError as e:
            if "nothing to commit" in e.stderr:
                print("ℹ️ Изменений нет, коммит не требуется")
                return False
            else:
                print(f"ℹ️ {e.stderr.strip()}")
                return False
    
    def push(self):
        """Пуш на удаленный репозиторий (если есть)"""
        try:
            # Проверяем, есть ли удаленный репозиторий
            result = subprocess.run(
                ["git", "remote", "-v"],
                capture_output=True, text=True, check=True
            )
            if "origin" not in result.stdout:
                print("ℹ️ Нет удаленного репозитория, пуш пропущен")
                return False
                
            subprocess.run(["git", "push"], check=True, capture_output=True)
            print("✅ Изменения отправлены на GitHub")
            return True
        except subprocess.CalledProcessError as e:
            print(f"ℹ️ Пуш не выполнен: {e.stderr.strip() if e.stderr else 'нет соединения'}")
            return False

if __name__ == "__main__":
    # Ищем последний снапшот
    snapshots_dir = Path("snapshots")
    if not snapshots_dir.exists():
        print("❌ Папка snapshots не найдена")
        exit(1)
    
    snapshot_files = sorted(snapshots_dir.glob("*.json"), key=os.path.getmtime)
    if not snapshot_files:
        print("❌ Нет снапшотов для коммита")
        exit(1)
    
    latest = snapshot_files[-1]
    print(f"📸 Коммитим: {latest.name}")
    
    git_op = GitOperator()
    git_op.commit_snapshot(latest)
    git_op.push()
