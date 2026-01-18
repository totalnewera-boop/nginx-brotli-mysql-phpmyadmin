#!/bin/bash
set -e

LOG="/root/lemp-install.log"
CREDS="/root/lemp-credentials.txt"

exec > >(tee -a $LOG) 2>&1

if [ "$(id -u)" != "0" ]; then
  echo "Run as root"
  exit 1
fi

echo "=== LEMP AUTO INSTALLER (DEBIAN 12) ==="
date

# Генерация паролей
DB_ROOT_PASS=$(openssl rand -base64 18)
DB_USER="lempuser"
DB_PASS=$(openssl rand -base64 18)

cat > $CREDS <<EOF
MariaDB ROOT Password: $DB_ROOT_PASS
Database User: $DB_USER
Database Password: $DB_PASS
EOF

chmod 600 $CREDS

echo ""
echo "==============================="
echo " MariaDB ROOT PASSWORD:"
echo " $DB_ROOT_PASS"
echo "==============================="
echo ""

apt update -y

# Установка пакетов
apt install -y nginx nginx-extras mariadb-server \
php-fpm php-mysql php-cli php-curl php-zip php-mbstring php-xml php-gd \
unzip curl ufw certbot python3-certbot-nginx openssl

# PHP-FPM - определяем socket и service
# Сначала определяем имя сервиса через systemctl
PHP_FPM_SERVICE=$(systemctl list-unit-files 2>/dev/null | grep -o 'php[0-9.]*-fpm\.service' | head -1 | sed 's/\.service$//')
if [ -z "$PHP_FPM_SERVICE" ]; then
  # Если не нашли через systemctl, используем fallback
  PHP_FPM_SERVICE="php8.2-fpm"
fi

# Определяем socket файл
PHP_FPM_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)
if [ -z "$PHP_FPM_SOCK" ]; then
  # Если socket не найден, ищем альтернативные пути
  PHP_FPM_SOCK=$(ls /var/run/php/php*-fpm.sock 2>/dev/null | head -1)
fi
if [ -z "$PHP_FPM_SOCK" ]; then
  # Если socket все еще не найден, используем стандартный путь на основе имени сервиса
  PHP_FPM_SOCK="/run/php/${PHP_FPM_SERVICE}.sock"
fi

systemctl enable nginx mariadb
if systemctl list-unit-files | grep -q "^${PHP_FPM_SERVICE}.service"; then
  systemctl enable "$PHP_FPM_SERVICE"
else
  echo "Warning: PHP-FPM service '$PHP_FPM_SERVICE' not found, trying to start it anyway"
fi
systemctl start mariadb

# Ждём MariaDB
echo "Waiting for MariaDB to start..."
for i in {1..20}; do
  if mysql -e "SELECT 1" >/dev/null 2>&1 || mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
    echo "MariaDB is ready"
    break
  fi
  sleep 2
done

# Переключаем root на пароль (пробуем разные способы подключения)
echo "Configuring MariaDB root password..."
if mysql -e "SELECT 1" >/dev/null 2>&1; then
  # Подключение без пароля работает
  mysql <<EOF
ALTER USER 'root'@'localhost'
IDENTIFIED WITH mysql_native_password
BY '$DB_ROOT_PASS';
FLUSH PRIVILEGES;
EOF
elif mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
  # Подключение с -uroot работает
  mysql -uroot <<EOF
ALTER USER 'root'@'localhost'
IDENTIFIED WITH mysql_native_password
BY '$DB_ROOT_PASS';
FLUSH PRIVILEGES;
EOF
else
  # Пароль уже установлен или нужна другая аутентификация
  echo "Warning: MariaDB root already has a password or needs manual configuration"
  echo "Root password was set to: $DB_ROOT_PASS"
  echo "You may need to set it manually with: mysql_secure_installation"
fi

# Создаём пользователя (пробуем с новым паролем)
echo "Creating database user..."
if mysql -uroot -p"$DB_ROOT_PASS" -e "SELECT 1" >/dev/null 2>&1; then
  mysql -uroot -p"$DB_ROOT_PASS" <<EOF
CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
  echo "Database user created successfully"
else
  echo "Warning: Could not create database user. You may need to do it manually:"
  echo "mysql -uroot -p"
  echo "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
  echo "GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'%' WITH GRANT OPTION;"
fi

# Открытый MySQL
cat > /etc/mysql/mariadb.conf.d/50-server.cnf <<EOF
[mysqld]
bind-address = 0.0.0.0
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_connections = 200
EOF

systemctl restart mariadb

# Brotli (если есть)
BROTLI=$(ls /usr/lib/nginx/modules | grep brotli || true)

# NGINX
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;

${BROTLI:+load_module modules/ngx_http_brotli_filter_module.so;}
${BROTLI:+load_module modules/ngx_http_brotli_static_module.so;}

events { worker_connections 2048; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    keepalive_timeout 65;

    gzip on;
    ${BROTLI:+brotli on;}
    ${BROTLI:+brotli_comp_level 6;}
    ${BROTLI:+brotli_types text/plain text/css application/javascript application/json image/svg+xml;}

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Сайт
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.php index.html index.htm;

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_intercept_errors on;
        fastcgi_index index.php;
        try_files \$uri =404;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires max;
        log_not_found off;
        access_log off;
    }

    access_log /var/log/nginx/default-access.log;
    error_log /var/log/nginx/default-error.log;
}
EOF

# PHP info
mkdir -p /var/www/html
cat > /var/www/html/info.php <<EOF
<?php phpinfo(); ?>
EOF

# phpMyAdmin
export DEBIAN_FRONTEND=noninteractive
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/admin-pass password $DB_ROOT_PASS" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password $DB_ROOT_PASS" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect none" | debconf-set-selections

apt install -y phpmyadmin
ln -sf /usr/share/phpmyadmin /var/www/html/phpmyadmin

# Firewall
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw allow 3306
ufw --force enable

# Перезапуск
systemctl restart "$PHP_FPM_SERVICE"
systemctl restart nginx

IP=$(hostname -I | awk '{print $1}')

cat >> $CREDS <<EOF

phpMyAdmin: http://$IP/phpmyadmin
Login: root
Password: $DB_ROOT_PASS
EOF

echo ""
echo "===================================="
echo " INSTALL COMPLETED SUCCESSFULLY"
echo "===================================="
echo "ROOT DB PASSWORD:"
echo " $DB_ROOT_PASS"
echo ""
echo "Credentials file: $CREDS"
echo "phpMyAdmin: http://$IP/phpmyadmin"
echo "===================================="
