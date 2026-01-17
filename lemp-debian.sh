#!/bin/bash
set -e

LOG="/root/lemp-install.log"
CREDS="/root/lemp-credentials.txt"

exec > >(tee -a $LOG) 2>&1

if [ "$(id -u)" != "0" ]; then
  echo "Run as root"
  exit 1
fi

echo "=== PRO LEMP INSTALLER ==="
echo "Nginx + MariaDB + PHP + phpMyAdmin + Brotli"
date

# Генерация паролей
DB_ROOT_PASS=$(openssl rand -base64 16)
DB_USER="lempuser"
DB_PASS=$(openssl rand -base64 16)
PMA_BLOWFISH=$(openssl rand -base64 32)

# Сохраняем креды
cat > $CREDS <<EOF
MariaDB Root Password: $DB_ROOT_PASS
Database User: $DB_USER
Database Password: $DB_PASS
phpMyAdmin Blowfish: $PMA_BLOWFISH
EOF

chmod 600 $CREDS

# Удаление старых репозиториев (dotdeb и других), если они есть
echo "Cleaning up old repositories..."
rm -f /etc/apt/sources.list.d/dotdeb.list
rm -f /etc/apt/sources.list.d/php.list 2>/dev/null || true

# Обновление пакетов (БЕЗ upgrade)
apt update -y

# Установка основных пакетов (с обработкой конфликтов версий)
echo "Installing core packages..."

# Установка nginx и mariadb
apt install -y nginx nginx-extras mariadb-server || true

# Установка PHP и основных расширений (используем общие имена для совместимости)
PACKAGES="php-fpm php-mysql php-cli php-curl php-zip php-mbstring php-xml php-gd"
for pkg in $PACKAGES; do
    dpkg -l | grep -q "^ii.*$pkg " && echo "$pkg already installed" || apt install -y "$pkg" || echo "Warning: $pkg installation failed"
done

# Установка остальных пакетов
apt install -y unzip curl ufw certbot python3-certbot-nginx || true

# Установка дополнительных PHP расширений (опционально, если доступны)
for pkg in php-imagick php-imap; do
    apt install -y "$pkg" 2>/dev/null && echo "Installed $pkg" || echo "Note: $pkg not available, skipping..."
done

# Включаем сервисы
systemctl enable nginx mariadb

# Включаем PHP-FPM сервис (определяем версию автоматически)
PHP_FPM_SERVICE=$(systemctl list-unit-files | grep -oP 'php\d+\.\d+-fpm\.service' | head -1 || echo "")
if [ ! -z "$PHP_FPM_SERVICE" ]; then
    systemctl enable "$PHP_FPM_SERVICE" 2>/dev/null || true
else
    # Попытка найти любой php-fpm сервис
    systemctl enable php*-fpm 2>/dev/null || systemctl enable php-fpm 2>/dev/null || true
fi

# Настройка MariaDB
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS'; FLUSH PRIVILEGES;"
mysql -uroot -p"$DB_ROOT_PASS" -e "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
mysql -uroot -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'%' WITH GRANT OPTION;"
mysql -uroot -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

# Открытый доступ MySQL для ВСЕХ
mkdir -p /etc/mysql/mariadb.conf.d
cat > /etc/mysql/mariadb.conf.d/50-server.cnf <<EOF
[mysqld]
bind-address = 0.0.0.0
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_connections = 200
max_allowed_packet = 16M
expire_logs_days = 10
max_binlog_size = 100M
EOF

# Настройка NGINX + Brotli
cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;

events { 
    worker_connections 2048;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript application/x-javascript text/x-js image/svg+xml;
    gzip_disable "msie6";

    # Brotli compression
    brotli on;
    brotli_comp_level 6;
    brotli_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript application/x-javascript text/x-js image/svg+xml;
    brotli_static on;
    brotli_min_length 20;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Конфиг сайта
cat > /etc/nginx/sites-available/default <<'EOF'
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
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_intercept_errors on;
        fastcgi_index index.php;
        try_files $uri =404;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
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

# Настройка PHP
PHP_INI_FILE="/etc/php/$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')/fpm/php.ini"
if [ -f "$PHP_INI_FILE" ]; then
    sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' "$PHP_INI_FILE"
    sed -i 's/#cgi.fix_pathinfo=0/cgi.fix_pathinfo=0/g' "$PHP_INI_FILE"
    sed -i 's/memory_limit = .*/memory_limit = 128M/' "$PHP_INI_FILE"
fi

# Установка phpMyAdmin
export DEBIAN_FRONTEND=noninteractive
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/admin-pass password $DB_ROOT_PASS" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password $DB_ROOT_PASS" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect none" | debconf-set-selections

apt install -y phpmyadmin
ln -sf /usr/share/phpmyadmin /var/www/html/phpmyadmin

# ---------------- FIREWALL ----------------
echo "Configuring UFW firewall..."

ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3306/tcp   # MySQL открыт для всех

ufw --force enable

# ---------------- RESTART ----------------
systemctl restart mariadb
systemctl restart php*-fpm
systemctl restart nginx

# Финал
IP=$(hostname -I | awk '{print $1}')

cat >> $CREDS <<EOF

phpMyAdmin URL: http://$IP/phpmyadmin
Login: $DB_USER
Password: $DB_PASS

Web Root: /var/www/html
PHP Info: http://$IP/info.php

SSL Ready:
When you have a domain:
certbot --nginx -d yourdomain.com -d www.yourdomain.com

WARNING: 
- Remove /var/www/html/info.php after testing
- Configure firewall rules for MySQL port 3306 from trusted IPs only
- Change default passwords if needed
EOF

echo "===================================="
echo "INSTALL COMPLETED"
echo "===================================="
echo "Credentials: $CREDS"
echo "Log file: $LOG"
echo "phpMyAdmin: http://$IP/phpmyadmin"
echo "PHP Info: http://$IP/info.php"
echo "===================================="
