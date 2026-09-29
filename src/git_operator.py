#!/usr/bin/env python3
"""
git_operator.py — коммит и пуш снапшотов в git.

Работает только если git установлен и доступен.
В контейнере git обычно НЕ нужен — коммит делает хост.
"""

import datetime
import os
import shutil
import subprocess
from pathlib import Path


class GitOperator:
    def __init__(self, repo_path="."):
        self.repo_path = Path(repo_path).resolve()
        self.snapshots_dir = self.repo_path / "snapshots"

    def _git_available(self):
        """Проверяет, установлен ли git в системе"""
        return shutil.which("git") is not None

    def commit_snapshot(self, snapshot_file):
        """Делает коммит нового снапшота"""
        if not self._git_available():
            print("ℹ️ git не установлен, коммит пропущен")
            return False

        os.chdir(self.repo_path)

        # Добавляем файл в Git
        subprocess.run(["git", "add", str(snapshot_file)], check=False)

        # Создаем коммит
        commit_msg = (
            f"📸 Автоматический снапшот: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
        )
        try:
            subprocess.run(
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
        if not self._git_available():
            print("ℹ️ git не установлен, пуш пропущен")
            return False

        try:
            # Проверяем, есть ли удаленный репозиторий
            result = subprocess.run(
                ["git", "remote", "-v"], capture_output=True, text=True, check=True
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
    # Проверяем git до всего остального
    if not shutil.which("git"):
        print("ℹ️ git не установлен, пропускаю коммит")
        exit(0)

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
