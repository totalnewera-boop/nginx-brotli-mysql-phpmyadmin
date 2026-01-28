@echo off
REM Переходим в директорию, где находится батник
cd /d "%~dp0"

echo ====================================
echo Автоматическая синхронизация с GitHub
echo ====================================
echo.

REM Проверяем наличие Python
python --version >nul 2>&1
if errorlevel 1 (
    echo [Ошибка] Python не найден! Установите Python 3.
    pause
    exit /b 1
)

REM Проверяем наличие auto_sync.py
if not exist "auto_sync.py" (
    echo [Ошибка] auto_sync.py не найден в %cd%
    echo Убедитесь, что файл находится в той же папке, что и start_sync.bat
    pause
    exit /b 1
)

REM Проверяем зависимости
echo [Проверка] Проверяю зависимости...
if exist "requirements.txt" (
    pip show watchdog >nul 2>&1
    if errorlevel 1 (
        echo [Установка] Устанавливаю зависимости...
        pip install -r requirements.txt
    )
) else (
    echo [Предупреждение] requirements.txt не найден, пропускаю проверку зависимостей
)

REM Запускаем скрипт синхронизации
echo [Запуск] Запускаю автоматическую синхронизацию...
echo.
python auto_sync.py

pause