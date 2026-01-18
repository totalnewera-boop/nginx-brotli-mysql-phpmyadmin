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

# PHP-FPM
PHP_FPM_SOCK=$(ls /run/php/php*-fpm.sock | head -1)
PHP_FPM_SERVICE=$(basename "$PHP_FPM_SOCK" | sed 's/.sock//')

systemctl enable nginx mariadb "$PHP_FPM_SERVICE"
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
    root /var/www/html;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
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
