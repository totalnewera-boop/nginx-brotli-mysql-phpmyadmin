#!/bin/bash
set -e

LOG="/root/lemp-install.log"
CREDS="/root/lemp-credentials.txt"

exec > >(tee -a $LOG) 2>&1

if [ "$(id -u)" != "0" ]; then
  echo "Run as root"
  exit 1
fi

echo "=== LEMP INSTALLER (DEBIAN 12 FIXED) ==="
date

# Генерация паролей
DB_ROOT_PASS=$(openssl rand -base64 16)
DB_USER="lempuser"
DB_PASS=$(openssl rand -base64 16)

cat > $CREDS <<EOF
MariaDB Root Password: $DB_ROOT_PASS
Database User: $DB_USER
Database Password: $DB_PASS
EOF

chmod 600 $CREDS

# Очистка старых реп
rm -f /etc/apt/sources.list.d/dotdeb.list
rm -f /etc/apt/sources.list.d/php.list

apt update -y

# Установка пакетов
apt install -y nginx nginx-extras mariadb-server \
php-fpm php-mysql php-cli php-curl php-zip php-mbstring php-xml php-gd \
unzip curl ufw certbot python3-certbot-nginx

# Включение сервисов
systemctl enable nginx mariadb php8.2-fpm

# Запуск MariaDB
systemctl start mariadb

# Ждём БД
for i in {1..15}; do
  if mysql -e "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Настройка MariaDB
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS'; FLUSH PRIVILEGES;"
mysql -uroot -p"$DB_ROOT_PASS" -e "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
mysql -uroot -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'%' WITH GRANT OPTION;"
mysql -uroot -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

# Открытый MySQL
cat > /etc/mysql/mariadb.conf.d/50-server.cnf <<EOF
[mysqld]
bind-address = 0.0.0.0
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_connections = 200
EOF

systemctl restart mariadb

# NGINX + Brotli
cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;

events { worker_connections 2048; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    keepalive_timeout 65;

    gzip on;
    brotli on;
    brotli_comp_level 6;
    brotli_types text/plain text/css application/javascript application/json image/svg+xml;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Сайт
cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    root /var/www/html;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
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

# Firewall (3306 открыт для всех)
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw allow 3306
ufw --force enable

# Перезапуск
systemctl restart php8.2-fpm
systemctl restart nginx

IP=$(hostname -I | awk '{print $1}')

cat >> $CREDS <<EOF

phpMyAdmin: http://$IP/phpmyadmin
Login: $DB_USER
Password: $DB_PASS
EOF

echo "===================================="
echo "INSTALL COMPLETED"
echo "Credentials: $CREDS"
echo "Log: $LOG"
echo "===================================="
