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
        
        # Проверяем состояние репозитория
        print("[Git] Проверяю состояние репозитория...")
        
        # Проверяем, сломан ли HEAD
        head_check = subprocess.run(
            "git symbolic-ref HEAD",
            cwd=self.repo_path,
            capture_output=True,
            text=True,
            shell=True
        )
        
        # Если HEAD сломан, исправляем его ДО всех операций
        if head_check.returncode != 0 or "fatal" in head_check.stderr.lower() or "unable to resolve" in head_check.stderr.lower():
            print("[Git] HEAD сломан, исправляю...")
            # Удаляем сломанную ссылку если она есть (пустой файл или битая ссылка)
            main_ref = self.repo_path / ".git" / "refs" / "heads" / "main"
            if main_ref.exists():
                try:
                    # Проверяем, пуст ли файл или битая ссылка
                    if main_ref.stat().st_size == 0:
                        main_ref.unlink()
                    else:
                        # Проверяем содержимое - если это не валидный SHA, удаляем
                        content = main_ref.read_text(encoding='utf-8').strip()
                        if not content or len(content) < 7 or not all(c in '0123456789abcdef' for c in content.lower()):
                            main_ref.unlink()
                except Exception:
                    main_ref.unlink(missing_ok=True)
            
            # Исправляем HEAD напрямую через файловую систему
            head_file = self.repo_path / ".git" / "HEAD"
            try:
                head_file.write_text("ref: refs/heads/main\n", encoding='utf-8')
                print("[Git] HEAD исправлен напрямую")
            except Exception as e:
                print(f"[Ошибка] Не удалось записать HEAD: {e}")
            
            # Проверяем, что HEAD теперь корректный
            head_check2 = subprocess.run(
                "git symbolic-ref HEAD",
                cwd=self.repo_path,
                capture_output=True,
                text=True,
                shell=True
            )
            if head_check2.returncode != 0:
                print("[Предупреждение] HEAD все еще может быть поврежден, но продолжаю...")
        
        # Проверяем, есть ли коммиты
        log_result = subprocess.run(
            "git log --oneline -1",
            cwd=self.repo_path,
            capture_output=True,
            text=True,
            shell=True
        )
        
        has_commits = log_result.returncode == 0
        
        # Проверяем текущую ветку
        branch_result = subprocess.run(
            "git symbolic-ref HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD",
            cwd=self.repo_path,
            capture_output=True,
            text=True,
            shell=True
        )
        
        current_branch = branch_result.stdout.strip() if branch_result.returncode == 0 else "main"
        
        # Если нет коммитов, убеждаемся что ветка main существует
        if not has_commits:
            print("[Git] Репозиторий новый, инициализирую ветку main...")
            self.run_git_command("git checkout -b main 2>/dev/null || git branch -M main 2>/dev/null || true", check=False)
            
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
        
        # Если это первый коммит или HEAD сломан, исправляем HEAD
        if not has_commits:
            print("[Git] Создаю первый коммит...")
            # Исправляем HEAD если он сломан
            self.run_git_command("git symbolic-ref HEAD refs/heads/main 2>/dev/null || git branch -M main 2>/dev/null || true", check=False)
        
        commit_result = subprocess.run(
            f'git commit -m "{commit_message}"',
            cwd=self.repo_path,
            capture_output=True,
            text=True,
            shell=True
        )
        
        if commit_result.returncode != 0:
            error_msg = commit_result.stderr.lower()
            print(f"[Ошибка] Не удалось создать коммит: {commit_result.stderr.strip()}")
            
            # Пытаемся исправить HEAD если он сломан
            if "cannot lock ref 'HEAD'" in error_msg or "unable to resolve reference" in error_msg:
                print("[Git] Попытка исправить поврежденный HEAD напрямую...")
                # Удаляем сломанную ссылку через файловую систему
                main_ref = self.repo_path / ".git" / "refs" / "heads" / "main"
                if main_ref.exists():
                    try:
                        main_ref.unlink()
                    except Exception:
                        pass
                
                # Исправляем HEAD напрямую через файловую систему
                head_file = self.repo_path / ".git" / "HEAD"
                try:
                    head_file.write_text("ref: refs/heads/main\n", encoding='utf-8')
                    print("[Git] HEAD исправлен напрямую через файловую систему")
                except Exception as e:
                    print(f"[Ошибка] Не удалось записать HEAD: {e}")
                    return
                
                # Ждем немного и пытаемся создать коммит снова
                time.sleep(0.5)
                commit_result2 = subprocess.run(
                    f'git commit -m "{commit_message}"',
                    cwd=self.repo_path,
                    capture_output=True,
                    text=True,
                    shell=True
                )
                if commit_result2.returncode == 0:
                    print("[Успех] Коммит создан после исправления HEAD")
                else:
                    print(f"[Ошибка] Все еще не удалось создать коммит: {commit_result2.stderr.strip()}")
                    print("[Подсказка] Попробуйте вручную: echo 'ref: refs/heads/main' > .git/HEAD")
                    return
            else:
                return
        
        # Пушим в GitHub
        print("[Git] Отправляю изменения в GitHub...")
        # Определяем имя ветки для push
        branch_name = current_branch if current_branch else "main"
        
        # Проверяем, есть ли удаленные изменения
        fetch_result = subprocess.run(
            "git fetch origin",
            cwd=self.repo_path,
            capture_output=True,
            text=True,
            shell=True
        )
        
        # Проверяем, разошлись ли ветки
        status_result = subprocess.run(
            "git status --porcelain -b",
            cwd=self.repo_path,
            capture_output=True,
            text=True,
            shell=True
        )
        
        if "diverged" in status_result.stdout.lower() or "behind" in status_result.stdout.lower():
            print("[Git] Локальная и удаленная ветки разошлись, объединяю изменения...")
            # Пробуем pull с allow-unrelated-histories для объединения несвязанных историй
            pull_result = subprocess.run(
                f"git pull --allow-unrelated-histories origin {branch_name}",
                cwd=self.repo_path,
                capture_output=True,
                text=True,
                shell=True
            )
            
            if pull_result.returncode != 0:
                # Если pull не сработал, пробуем rebase
                rebase_result = subprocess.run(
                    f"git pull --rebase --allow-unrelated-histories origin {branch_name}",
                    cwd=self.repo_path,
                    capture_output=True,
                    text=True,
                    shell=True
                )
                
                if rebase_result.returncode != 0:
                    error_msg = rebase_result.stderr.lower()
                    if "unrelated histories" in error_msg:
                        print("[Предупреждение] Истории репозиториев не связаны")
                        print("[Подсказка] Выполните вручную: git pull --allow-unrelated-histories origin main")
                    else:
                        print("[Предупреждение] Не удалось объединить изменения автоматически")
                        print(f"[Ошибка] {rebase_result.stderr.strip()}")
                    # Продолжаем попытку push - может быть это первый раз
        
        # Пушим изменения
        if not self.run_git_command(f"git push -u origin {branch_name} 2>/dev/null || git push origin {branch_name}"):
            error_msg = subprocess.run(
                f"git push origin {branch_name}",
                cwd=self.repo_path,
                capture_output=True,
                text=True,
                shell=True
            ).stderr.lower()
            
            if "non-fast-forward" in error_msg or "rejected" in error_msg:
                print("[Ошибка] Удаленный репозиторий содержит изменения, которые отсутствуют локально")
                print("[Подсказка] Выполните: git pull --rebase origin main")
                print("[Подсказка] Затем синхронизация продолжится автоматически")
            else:
                print("[Ошибка] Не удалось отправить изменения в GitHub")
                print("[Подсказка] Проверьте настройки git и подключение к интернету")
                print("[Подсказка] Убедитесь, что удаленный репозиторий настроен: git remote add origin <url>")
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