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

# Обновление пакетов (БЕЗ upgrade)
apt update -y

# Установка пакетов
apt install -y nginx nginx-extras mariadb-server \
php-fpm php-mysql php-cli php-curl php-zip php-mbstring php-xml unzip curl ufw certbot python3-certbot-nginx

# Включаем сервисы
systemctl enable nginx mariadb

# Настройка MariaDB
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS'; FLUSH PRIVILEGES;"
mysql -uroot -p"$DB_ROOT_PASS" -e "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
mysql -uroot -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'%' WITH GRANT OPTION;"
mysql -uroot -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

# Открытый доступ MySQL для ВСЕХ
cat > /etc/mysql/mariadb.conf.d/50-server.cnf <<EOF
[mysqld]
bind-address = 0.0.0.0
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_connections = 200
EOF

# Настройка NGINX + Brotli
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

# Конфиг сайта
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
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF

# PHP info
mkdir -p /var/www/html
cat > /var/www/html/info.php <<EOF
<?php phpinfo(); ?>
EOF

# Установка phpMyAdmin
export DEBIAN_FRONTEND=noninteractive
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/admin-pass password $DB_ROOT_PASS" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password $DB_ROOT_PASS" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect none" | debconf-set-selections

apt install -y phpmyadmin
ln -s /usr/share/phpmyadmin /var/www/html/phpmyadmin

# ---------------- FIREWALL ----------------
echo "Configuring UFW firewall..."

ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw allow 3306   # MySQL открыт для всех

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

SSL Ready:
When you have a domain:
certbot --nginx -d yourdomain.com -d www.yourdomain.com
EOF

echo "===================================="
echo "INSTALL COMPLETED"
echo "Credentials: $CREDS"
echo "Log file: $LOG"
echo "phpMyAdmin: http://$IP/phpmyadmin"
echo "===================================="
