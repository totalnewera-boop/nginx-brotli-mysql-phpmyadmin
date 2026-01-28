#!/bin/bash
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Этот скрипт нужно запускать от root."
  exit 1
fi

echo "=== УСТАНОВКА НОВОГО САЙТА ==="
echo

# Запрос домена
read -p "Введите домен (например: fitness-journey.bond): " DOMAIN

if [ -z "$DOMAIN" ]; then
  echo "Ошибка: домен не может быть пустым"
  exit 1
fi

# Убираем www. из начала, если есть
DOMAIN=$(echo "$DOMAIN" | sed 's/^www\.//')

echo
echo "Установка сайта для домена: $DOMAIN"
echo "Также будет настроен www.$DOMAIN"
echo

# Создание директорий
echo "Создание директорий..."
mkdir -p /var/www/$DOMAIN/public
chown -R www-data:www-data /var/www/$DOMAIN
chmod -R 755 /var/www/$DOMAIN

# Создание тестового index.php
echo "Создание тестового index.php..."
cat > /var/www/$DOMAIN/public/index.php <<EOF
<?php
echo "Fitness Journey работает 🚀<br>";
echo "URI: " . \$_SERVER['REQUEST_URI'];
EOF

# Создание конфигурации Nginx
echo "Создание конфигурации Nginx..."
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    root /var/www/$DOMAIN/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
    }
}
EOF

# Активация сайта
echo "Активация сайта..."
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

# Проверка конфигурации Nginx
echo "Проверка конфигурации Nginx..."
nginx -t

# Перезагрузка Nginx
echo "Перезагрузка Nginx..."
systemctl reload nginx

# Получение SSL сертификата
echo
echo "Получение SSL сертификата через Let's Encrypt..."
certbot --nginx \
  -d $DOMAIN \
  -d www.$DOMAIN \
  --agree-tos \
  --register-unsafely-without-email \
  --redirect \
  --non-interactive

# Проверка статуса certbot
echo
echo "Проверка статуса certbot..."
systemctl status certbot.timer --no-pager || true

# Тестовый запуск обновления сертификата
echo
echo "Тестовый запуск обновления сертификата (dry-run)..."
certbot renew --dry-run

echo
echo "===================================="
echo " УСТАНОВКА САЙТА ЗАВЕРШЕНА"
echo "===================================="
echo "Домен: https://$DOMAIN"
echo "Домен: https://www.$DOMAIN"
echo "Директория: /var/www/$DOMAIN/public"
echo "Конфигурация Nginx: /etc/nginx/sites-available/$DOMAIN"
echo "===================================="
