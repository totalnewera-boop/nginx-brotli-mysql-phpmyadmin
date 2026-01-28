#!/bin/bash
set -e

if [ "$(id -u)" != "0" ]; then
  echo "Этот скрипт нужно запускать от root."
  exit 1
fi

echo "=== NGINX + Brotli + PHP + MariaDB + phpMyAdmin (Debian 12) ==="
date

echo "Настройка SSH keepalive..."
sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 60/; t; $a ClientAliveInterval 60' /etc/ssh/sshd_config
sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 9999/; t; $a ClientAliveCountMax 9999' /etc/ssh/sshd_config
systemctl restart sshd

echo "Обновление пакетов..."
apt update -y

echo "Установка зависимостей для сборки Nginx с Brotli..."
apt install -y libbrotli-dev dpkg-dev build-essential gnupg2 git gcc cmake \
  libpcre3 libpcre3-dev zlib1g zlib1g-dev openssl libssl-dev curl unzip

echo "Добавление официального репозитория Nginx..."
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor > /usr/share/keyrings/nginx-archive-keyring.gpg

cat > /etc/apt/sources.list.d/nginx.list <<'EOF'
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg arch=amd64] http://nginx.org/packages/debian/ bookworm nginx
deb-src [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg arch=amd64] http://nginx.org/packages/debian/ bookworm nginx
EOF

apt update -y

echo "Подготовка исходников Nginx и модуля Brotli..."
apt install -y build-essential devscripts dpkg-dev git curl

cd /usr/local/src
apt source nginx
apt build-dep nginx -y

git clone --recursive https://github.com/google/ngx_brotli.git

cd /usr/local/src/nginx-*/

echo "Включение модуля ngx_brotli в сборку Nginx..."
sed -i 's|CFLAGS="" ./configure|CFLAGS="" ./configure --add-module=/usr/local/src/ngx_brotli|g' debian/rules

echo "Сборка deb-пакетов Nginx..."
dpkg-buildpackage -b -uc -us

echo "Установка собранных пакетов Nginx..."
dpkg -i /usr/local/src/*.deb

echo "Конфигурация Nginx с Brotli и Gzip..."
cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {

    ##
    # Basic settings
    ##

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    types_hash_max_size 2048;
    server_tokens off;
    ignore_invalid_headers on;

    keepalive_timeout 40s;
    send_timeout 20s;
    client_header_timeout 20s;
    client_body_timeout 20s;
    reset_timedout_connection on;

    server_names_hash_bucket_size 64;

    # Upload limits
    client_max_body_size 100m;
    client_body_buffer_size 128k;

    ##
    # MIME
    ##

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ##
    # Logging
    ##

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$gzip_ratio"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    ##
    # Limits
    ##

    limit_req_zone $binary_remote_addr zone=dos_attack:20m rate=30r/m;

    ##
    # Gzip
    ##

    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 1000;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types
        text/plain
        text/css
        application/json
        application/javascript
        application/xml
        application/rss+xml
        image/svg+xml
        font/ttf
        font/otf
        application/font-woff2;

    gzip_static on;

    ##
    # Brotli
    ##

    brotli on;
    brotli_comp_level 6;
    brotli_types
        text/plain
        text/css
        application/json
        application/javascript
        application/xml
        application/rss+xml
        image/svg+xml
        font/ttf
        font/otf
        application/font-woff2;

    brotli_static on;

    ##
    # Include virtual hosts
    ##

    include /etc/nginx/sites-enabled/*;
    include /etc/nginx/conf.d/*.conf;
    include /usr/share/nginx/modules/*.conf;
}
EOF

mkdir -p /etc/nginx/sites-available/
mkdir -p /etc/nginx/sites-enabled/

nginx -t
systemctl start nginx
systemctl status nginx --no-pager || true

echo "Добавление override для плавного старта nginx..."
mkdir -p /etc/systemd/system/nginx.service.d
printf "[Service]\nExecStartPost=/bin/sleep 0.1\n" > /etc/systemd/system/nginx.service.d/override.conf
systemctl daemon-reload
systemctl restart nginx

echo "Установка и настройка UFW..."
apt install -y ufw

cat > /etc/ufw/applications.d/nginx <<'EOF'
[Nginx HTTP]
title=Web Server
description=Enable NGINX HTTP traffic
ports=80/tcp

[Nginx HTTPS]
title=Web Server (HTTPS)
description=Enable NGINX HTTPS traffic
ports=443/tcp

[Nginx Full]
title=Web Server (HTTP and HTTPS)
description=Enable NGINX HTTP and HTTPS traffic
ports=80,443/tcp
EOF

ufw app update nginx
ufw app list

# Открываем нужные порты ДО включения фаервола
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw allow 3306/tcp   # если нужен удалённый доступ к БД

# Включаем UFW
ufw --force enable

echo "Установка PHP, MariaDB и расширений..."
apt update -y
apt install -y \
  php-fpm php-mysql php-cli php-curl php-zip php-gd php-xml php-mbstring \
  mariadb-server php-imap php-bz2 php-intl php-gmp

apt install -y mariadb-server mariadb-client
systemctl enable mariadb
systemctl start mariadb

DB_ADMIN_PASS=$(openssl rand -base64 18)
echo "Admin DB password: $DB_ADMIN_PASS"

echo "Создание пользователя admin в MariaDB..."
mysql -e "CREATE USER IF NOT EXISTS 'admin'@'localhost' IDENTIFIED BY '${DB_ADMIN_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;"

echo "Разрешение удалённых подключений к MariaDB..."
sed -i 's/^\s*bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mariadb

echo "Установка phpMyAdmin..."
export DEBIAN_FRONTEND=noninteractive
apt install -y phpmyadmin

echo "Создание snippet fastcgi-php.conf..."
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/fastcgi-php.conf <<'EOF'
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
fastcgi_index index.php;
EOF

echo "Создание vhost для phpMyAdmin..."
cat > /etc/nginx/sites-available/phpmyadmin.conf <<'EOF'
server {
    listen 80;
    server_name _;

    root /usr/share/phpmyadmin;
    index index.php index.html;

    location /phpmyadmin {
        alias /usr/share/phpmyadmin/;
        index index.php;
    }

    location ~ ^/phpmyadmin/(.+\.php)$ {
        alias /usr/share/phpmyadmin/$1;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $request_filename;
    }

    location ~* ^/phpmyadmin/(.+\.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt))$ {
        alias /usr/share/phpmyadmin/$1;
    }
}
EOF

ln -sf /etc/nginx/sites-available/phpmyadmin.conf /etc/nginx/sites-enabled/phpmyadmin.conf
nginx -t
systemctl reload nginx

echo "Установка certbot..."
apt install -y certbot python3-certbot-nginx

IP=$(hostname -I | awk '{print $1}')

echo
echo "===================================="
echo " УСТАНОВКА ЗАВЕРШЕНА"
echo "===================================="
echo "phpMyAdmin: http://$IP/phpmyadmin"
echo "DB admin user: admin"
echo "DB admin password: $DB_ADMIN_PASS"
echo "===================================="

