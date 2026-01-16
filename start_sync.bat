@echo off
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

REM Проверяем зависимости
echo [Проверка] Проверяю зависимости...
pip show watchdog >nul 2>&1
if errorlevel 1 (
    echo [Установка] Устанавливаю зависимости...
    pip install -r requirements.txt
)

REM Запускаем скрипт синхронизации
echo [Запуск] Запускаю автоматическую синхронизацию...
echo.
python auto_sync.py

pause