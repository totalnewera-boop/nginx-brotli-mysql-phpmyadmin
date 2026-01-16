# nginx-brotli-mysql-phpmyadmin

Этот репозиторий содержит скрипт установки, который упрощает развертывание LEMP стека, подходящего для shared-подобных Linux окружений.

**Установленное ПО:**
- **Nginx** с поддержкой Brotli сжатия
- **MySQL/MariaDB** с удаленным доступом
- **PHP 8.1-FPM** с необходимыми расширениями
- **phpMyAdmin** (опционально)

**Особенности:**
- Автоматическая настройка Brotli сжатия для Nginx
- MySQL настроен для удаленного доступа (bind-address: 0.0.0.0)
- Оптимизированная конфигурация PHP-FPM
- UTF-8 (utf8mb4) поддержка в MySQL
- Готовые конфигурации для виртуальных хостов

Есть вопросы или проблемы? Создайте issue или предложите новые функции.

## Быстрая установка

Выполните эти команды на сервере от имени root:

```bash
wget https://raw.githubusercontent.com/totalnewera-boop/nginx-brotli-mysql-phpmyadmin/main/lemp-debian.sh
chmod +x lemp-debian.sh
./lemp-debian.sh
```

Или одной командой:

```bash
wget -qO- https://raw.githubusercontent.com/totalnewera-boop/nginx-brotli-mysql-phpmyadmin/main/lemp-debian.sh | bash
```

## Системные требования

- Debian или Ubuntu Linux
- Права root
- Интернет-соединение для загрузки пакетов

## Что устанавливает скрипт

### Nginx
- Веб-сервер Nginx последней версии
- Модули Brotli для сжатия (ngx_http_brotli_filter_module, ngx_http_brotli_static_module)
- Оптимизированная конфигурация с поддержкой gzip и Brotli

### MySQL
- MySQL/MariaDB сервер
- Удаленный доступ включен (bind-address: 0.0.0.0)
- UTF-8 (utf8mb4) кодировка по умолчанию
- Базовые настройки производительности

### PHP 8.1
- PHP-FPM 8.1
- Расширения: mysql, sqlite, curl, xml, zip, gd, mbstring, bcmath, intl, imagick, opcache
- Оптимизированная конфигурация пула

### phpMyAdmin (опционально)
- Последняя версия phpMyAdmin
- Автоматическая настройка виртуального хоста Nginx

## После установки

1. **Настройте безопасность MySQL:**
   ```bash
   mysql_secure_installation
   ```

2. **Настройте файрвол** для защиты MySQL (порт 3306):
   ```bash
   # UFW пример
   ufw allow from YOUR_IP to any port 3306
   ```

3. **Проверьте установку:**
   - Откройте в браузере: `http://ваш-сервер/info.php`
   - Удалите файл `info.php` после проверки

4. **Используйте setup-vhost** для создания виртуальных хостов:
   ```bash
   setup-vhost username domain.com
   ```

## Безопасность

⚠️ **ВАЖНО:**
- После установки обязательно настройте пароль root для MySQL
- Настройте файрвол для ограничения доступа к порту 3306 только с доверенных IP
- Удалите `/var/www/html/info.php` после проверки
- Рассмотрите возможность ограничения доступа к phpMyAdmin по IP

## Лицензия

MIT License - смотрите файл [LICENSE](LICENSE) для деталей.

## Вклад в проект

Предложения и исправления приветствуются! Создайте issue или pull request.