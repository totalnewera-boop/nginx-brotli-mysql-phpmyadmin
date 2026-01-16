#!/usr/bin/env python3
"""
Автоматическая синхронизация локальных изменений с GitHub репозиторием.
Отслеживает изменения файлов и автоматически пушит их в GitHub.
"""

import os
import time
import subprocess
import sys
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler


class GitAutoSyncHandler(FileSystemEventHandler):
    """Обработчик событий файловой системы для автоматической синхронизации с GitHub."""
    
    def __init__(self, repo_path, debounce_time=5):
        """
        Инициализация обработчика.
        
        Args:
            repo_path: Путь к репозиторию
            debounce_time: Время ожидания перед коммитом (секунды)
        """
        self.repo_path = Path(repo_path)
        self.debounce_time = debounce_time
        self.last_modified = {}
        self.commit_timer = None
        
        # Файлы и директории, которые нужно игнорировать
        self.ignore_patterns = [
            '.git',
            '__pycache__',
            '.pyc',
            '.pyo',
            '.pyd',
            '.env',
            'venv',
            'env',
            'node_modules',
            '.DS_Store',
            'Thumbs.db'
        ]
    
    def should_ignore(self, path):
        """Проверка, нужно ли игнорировать путь."""
        path_str = str(path).lower()
        return any(pattern in path_str for pattern in self.ignore_patterns)
    
    def on_modified(self, event):
        """Обработка события изменения файла."""
        if event.is_directory:
            return
            
        file_path = Path(event.src_path)
        
        # Игнорируем системные файлы
        if self.should_ignore(file_path):
            return
        
        # Игнорируем сам скрипт синхронизации (чтобы избежать бесконечного цикла)
        if file_path.name == 'auto_sync.py':
            return
        
        print(f"[Изменение обнаружено] {file_path.name}")
        self.last_modified[file_path] = time.time()
        
        # Запускаем отложенную синхронизацию
        self.schedule_sync()
    
    def on_created(self, event):
        """Обработка события создания файла."""
        if event.is_directory:
            return
            
        file_path = Path(event.src_path)
        
        if self.should_ignore(file_path):
            return
        
        if file_path.name == 'auto_sync.py':
            return
        
        print(f"[Новый файл] {file_path.name}")
        self.last_modified[file_path] = time.time()
        self.schedule_sync()
    
    def on_deleted(self, event):
        """Обработка события удаления файла."""
        if event.is_directory:
            return
            
        file_path = Path(event.src_path)
        
        if self.should_ignore(file_path):
            return
        
        print(f"[Файл удален] {file_path.name}")
        self.schedule_sync()
    
    def schedule_sync(self):
        """Запланировать синхронизацию через debounce_time секунд."""
        # Используем простую задержку для группировки изменений
        time.sleep(self.debounce_time)
        self.sync_to_github()
    
    def run_git_command(self, command, check=True):
        """
        Выполнить git команду.
        
        Args:
            command: Список команд для выполнения
            check: Проверять ли код возврата
        """
        try:
            result = subprocess.run(
                command,
                cwd=self.repo_path,
                capture_output=True,
                text=True,
                check=check,
                shell=True
            )
            if result.stdout:
                print(result.stdout.strip())
            return result.returncode == 0
        except subprocess.CalledProcessError as e:
            print(f"[Ошибка] {e.stderr.strip()}")
            return False
    
    def sync_to_github(self):
        """Синхронизировать изменения с GitHub."""
        print("\n[Синхронизация] Начинаю синхронизацию с GitHub...")
        
        # Проверяем статус репозитория
        print("[Git] Проверяю статус...")
        self.run_git_command("git status", check=False)
        
        # Добавляем все изменения
        print("[Git] Добавляю изменения...")
        if not self.run_git_command("git add -A"):
            print("[Ошибка] Не удалось добавить файлы")
            return
        
        # Проверяем, есть ли что коммитить
        status_result = subprocess.run(
            "git status --porcelain",
            cwd=self.repo_path,
            capture_output=True,
            text=True,
            shell=True
        )
        
        if not status_result.stdout.strip():
            print("[Инфо] Нет изменений для коммита")
            return
        
        # Создаем коммит
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        commit_message = f"Auto-sync: обновление от {timestamp}"
        print(f"[Git] Создаю коммит: {commit_message}")
        
        if not self.run_git_command(f'git commit -m "{commit_message}"'):
            print("[Ошибка] Не удалось создать коммит")
            return
        
        # Пушим в GitHub
        print("[Git] Отправляю изменения в GitHub...")
        if not self.run_git_command("git push origin main"):
            print("[Ошибка] Не удалось отправить изменения в GitHub")
            print("[Подсказка] Проверьте настройки git и подключение к интернету")
            return
        
        print("[Успех] Изменения успешно отправлены в GitHub!\n")


def main():
    """Основная функция для запуска автоматической синхронизации."""
    repo_path = Path(__file__).parent.absolute()
    
    print("=" * 60)
    print("Автоматическая синхронизация с GitHub")
    print("=" * 60)
    print(f"Директория: {repo_path}")
    print("Нажмите Ctrl+C для остановки")
    print("=" * 60)
    print()
    
    # Проверяем, что это git репозиторий
    if not (repo_path / '.git').exists():
        print("[Ошибка] Это не git репозиторий!")
        print("[Подсказка] Выполните: git init")
        sys.exit(1)
    
    # Создаем обработчик и наблюдатель
    event_handler = GitAutoSyncHandler(repo_path, debounce_time=5)
    observer = Observer()
    observer.schedule(event_handler, str(repo_path), recursive=True)
    
    # Запускаем наблюдение
    observer.start()
    
    try:
        print("[Старт] Отслеживание изменений запущено...\n")
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n\n[Остановка] Останавливаю синхронизацию...")
        observer.stop()
    
    observer.join()
    print("[Завершено] Синхронизация остановлена")


if __name__ == "__main__":
    main()