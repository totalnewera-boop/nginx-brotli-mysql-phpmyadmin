#!/bin/bash
function pause(){
   read -p "$*"
}

function check_root() {
	if [ ! "`whoami`" = "root" ]
	then
	    echo "Root previlege required to run this script. Rerun as root."
	    exit 1
	fi
}
check_root

echo "=========================================="
echo "LEMP Stack Installation Script"
echo "Nginx + MySQL + PHP + phpMyAdmin + Brotli"
echo "=========================================="
echo ""

# Detect OS
OS_DISTRO=$(cat /etc/issue|awk 'NR==1 {print $1}')
echo "Detected OS: $OS_DISTRO"

# Add repositories for Ubuntu/Debian
if [ "$OS_DISTRO" != "Ubuntu" ]; then
	echo "Adding DotDeb repositories for Debian..."
	cat > /etc/apt/sources.list.d/dotdeb.list <<END
deb http://packages.dotdeb.org stable all
deb-src http://packages.dotdeb.org stable all
END
	wget -qO- http://www.dotdeb.org/dotdeb.gpg | apt-key add -
fi

# Add PHP repository for Ubuntu
if [ "$OS_DISTRO" = "Ubuntu" ]; then
	echo "Adding PHP repository..."
	apt-get install -y software-properties-common
	add-apt-repository -y ppa:ondrej/php
fi

# Add nginx with Brotli module repository (Ubuntu)
if [ "$OS_DISTRO" = "Ubuntu" ]; then
	echo "Adding Nginx repository with Brotli support..."
	apt-get install -y gnupg2 ca-certificates lsb-release
	echo "deb http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list
	wget -qO- https://nginx.org/keys/nginx_signing.key | apt-key add -
fi

apt-get update
apt-get upgrade -y
apt-get remove -y apache2*

echo ""
echo "Installing Nginx, MySQL, and PHP..."

# Install nginx
apt-get install -y nginx

# Install MySQL
echo "mysql-server mysql-server/root_password password root" | debconf-set-selections
echo "mysql-server mysql-server/root_password_again password root" | debconf-set-selections
apt-get install -y mysql-server mysql-client

# Install PHP 8.1 and extensions
echo "Installing PHP 8.1 and extensions..."
apt-get install -y php8.1-fpm php8.1-cli php8.1-common php8.1-mysql php8.1-sqlite3 \
	php8.1-curl php8.1-xml php8.1-zip php8.1-gd php8.1-mbstring php8.1-bcmath \
	php8.1-intl php8.1-readline php8.1-opcache php8.1-imagick php8.1-imap \
	php-pear php8.1-dev libcurl4-openssl-dev libpcre3-dev build-essential

# Install Brotli module for nginx
echo ""
echo "Installing Brotli compression module..."
apt-get install -y libbrotli-dev
if [ ! -d "/tmp/ngx_brotli" ]; then
	cd /tmp
	git clone https://github.com/google/ngx_brotli.git
	cd ngx_brotli
	git submodule update --init
fi

# Build nginx with Brotli module (if not available as package)
# Alternative: use dynamic module if available
if [ ! -f "/usr/lib/nginx/modules/ngx_http_brotli_filter_module.so" ] && [ ! -f "/etc/nginx/modules-enabled/brotli.conf" ]; then
	echo "Building nginx with Brotli support..."
	cd /tmp
	# Install build tools and dependencies
	apt-get install -y build-essential gcc libpcre3-dev zlib1g-dev libssl-dev
	
	# Get nginx version
	if command -v nginx >/dev/null 2>&1; then
		NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+\.\d+')
	else
		NGINX_VERSION=$(dpkg -l | grep nginx | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "1.22.1")
	fi
	
	if [ -z "$NGINX_VERSION" ]; then
		NGINX_VERSION="1.22.1"
	fi
	
	mkdir -p /usr/lib/nginx/modules
	wget -q http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz -O nginx-${NGINX_VERSION}.tar.gz || true
	if [ -f "nginx-${NGINX_VERSION}.tar.gz" ]; then
		tar xzf nginx-${NGINX_VERSION}.tar.gz
		cd nginx-${NGINX_VERSION}
		./configure --with-compat --add-dynamic-module=../ngx_brotli --prefix=/etc/nginx --sbin-path=/usr/sbin/nginx --modules-path=/usr/lib/nginx/modules 2>/dev/null
		make modules 2>/dev/null || true
		if [ -f "objs/ngx_http_brotli_filter_module.so" ]; then
			cp objs/ngx_http_brotli_filter_module.so /usr/lib/nginx/modules/
		fi
		if [ -f "objs/ngx_http_brotli_static_module.so" ]; then
			cp objs/ngx_http_brotli_static_module.so /usr/lib/nginx/modules/
		fi
		cd /tmp
		rm -rf nginx-${NGINX_VERSION} nginx-${NGINX_VERSION}.tar.gz*
	fi
	cd /
fi

# Stop services before configuration
systemctl stop mysql 2>/dev/null || service mysql stop
systemctl stop nginx 2>/dev/null || service nginx stop
systemctl stop php8.1-fpm 2>/dev/null || service php8.1-fpm stop

echo ""
echo "Configuring MySQL for remote access..."

# Create MySQL config directory if it doesn't exist
mkdir -p /etc/mysql/mysql.conf.d

# Configure MySQL - Enable remote access
cat > /etc/mysql/mysql.conf.d/mysqld.cnf <<END
[mysqld]
user		= mysql
pid-file	= /var/run/mysqld/mysqld.pid
socket		= /var/run/mysqld/mysqld.sock
port		= 3306
basedir		= /usr
datadir		= /var/lib/mysql
tmpdir		= /tmp
lc-messages-dir	= /usr/share/mysql
skip-external-locking
bind-address		= 0.0.0.0
default-storage-engine = InnoDB
innodb_file_per_table = 1
max_connections = 200
max_allowed_packet = 16M
expire_logs_days = 10
max_binlog_size = 100M
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysqldump]
quick
quote-names
max_allowed_packet = 16M

[mysql]
default-character-set = utf8mb4

[client]
default-character-set = utf8mb4
END

echo "MySQL configured for remote access (bind-address: 0.0.0.0)"
echo "WARNING: Make sure to configure firewall rules and strong passwords!"

# Configure PHP template for nginx
cat > /etc/nginx/php <<END
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
        	fastcgi_intercept_errors on;
    		fastcgi_index index.php;
    		fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    		try_files \$uri =404;
    		fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    		error_page 404 /404page.html; 
        }
 
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
                expires max;
                log_not_found off;
                access_log off;
        }
END

# Configure nginx with Brotli support
cat > /etc/nginx/nginx.conf <<END
user www-data;
worker_processes auto;
pid /var/run/nginx.pid;

# Load Brotli modules
load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;

events {
	worker_connections 2048;
	multi_accept on;
	use epoll;
}

http {
	sendfile on;
	tcp_nopush on;
	tcp_nodelay on;
	keepalive_timeout 65;
	types_hash_max_size 2048;
	server_tokens off;

	include /etc/nginx/mime.types;
	default_type application/octet-stream;

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
	brotli_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript application/x-javascript text/x-js image/svg+xml application/font-woff application/font-woff2 font/woff font/woff2;
	brotli_static on;
	brotli_min_length 20;

	include /etc/nginx/conf.d/*.conf;
	include /etc/nginx/sites-enabled/*;
}
END

# Default site configuration
cat > /etc/nginx/sites-available/default <<END
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.php index.html index.htm;
    
    include php;

    access_log /var/log/nginx/default-access.log;
    error_log /var/log/nginx/default-error.log;
}
END

# Configure PHP-FPM
# Create PHP-FPM config directory if it doesn't exist
mkdir -p /etc/php/8.1/fpm/pool.d
cat > /etc/php/8.1/fpm/pool.d/www.conf <<END
[www]
user = www-data
group = www-data
listen = /var/run/php/php8.1-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.max_requests = 500
chdir = /
env[HOSTNAME] = \$HOSTNAME
php_admin_value[upload_max_filesize] = 32M
php_admin_value[post_max_size] = 32M
END

# Configure PHP
sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g' /etc/php/8.1/fpm/php.ini
sed -i 's/#cgi.fix_pathinfo=0/cgi.fix_pathinfo=0/g' /etc/php/8.1/fpm/php.ini
sed -i 's/memory_limit = .*/memory_limit = 128M/' /etc/php/8.1/fpm/php.ini

# Install phpMyAdmin
echo ""
echo -n "Install PHPMyAdmin?[y/n][y]:"
read pma_install
if [ "$pma_install" != "n" ]; then
	echo "Installing PHPMyAdmin..."
	export DEBIAN_FRONTEND=noninteractive
	debconf-set-selections <<< "phpmyadmin phpmyadmin/reconfigure-webserver multiselect nginx"
	debconf-set-selections <<< "phpmyadmin phpmyadmin/dbconfig-install boolean false"
	apt-get install -y phpmyadmin
	
	echo -n "Domain for PHPMyAdmin Web Interface? Example: pma.domain.com :"
	read pma_url
	if [ ! -z "$pma_url" ]; then
		cat > "/etc/nginx/sites-available/${pma_url}.conf" <<'EOF'
server {
    server_name PMA_URL;
    root /usr/share/phpmyadmin;
    
    include php;
    
    # Security: Restrict access if needed
    # allow 192.168.1.0/24;
    # deny all;
    
    access_log  /var/log/nginx/PMA_URL-access.log;
    error_log  /var/log/nginx/PMA_URL-error.log;
}
EOF
		sed -i "s|PMA_URL|${pma_url}|g" "/etc/nginx/sites-available/${pma_url}.conf"
		ln -sf "/etc/nginx/sites-available/${pma_url}.conf" "/etc/nginx/sites-enabled/${pma_url}.conf"
		echo "PHPMyAdmin configured for: $pma_url"
	fi
else
	echo "Skipping PHPMyAdmin Installation"
fi

# Create web directory
mkdir -p /var/www/html
chown -R www-data:www-data /var/www
mkdir -p /var/log/nginx

# Create info.php
cat > /var/www/html/info.php <<END
<?php
phpinfo();
?>
END

# Test nginx configuration
nginx -t

# Start services
echo ""
echo "Starting services..."
systemctl enable mysql
systemctl enable nginx
systemctl enable php8.1-fpm

systemctl start mysql
systemctl start php8.1-fpm
systemctl start nginx

# Download setup-vhost script
echo ""
echo "Downloading setup-vhost script..."
wget -q https://raw.github.com/aatishnn/lempstack/master/setup-vhost.sh -O /bin/setup-vhost 2>/dev/null || echo "Could not download setup-vhost script. Please add it manually."
if [ -f "/bin/setup-vhost" ]; then
	chmod 755 /bin/setup-vhost
fi

echo ""
echo "=========================================="
echo "Installation completed!"
echo "=========================================="
echo ""
echo "Services installed:"
echo "  - Nginx with Brotli compression"
echo "  - MySQL (remote access enabled)"
echo "  - PHP 8.1-FPM"
if [ "$pma_install" != "n" ]; then
	echo "  - PHPMyAdmin"
fi
echo ""
echo "Default web root: /var/www/html"
echo "PHP info: http://your-server-ip/info.php"
echo ""
echo "IMPORTANT SECURITY NOTES:"
echo "  1. Configure MySQL root password: mysql_secure_installation"
echo "  2. Configure firewall to allow MySQL port 3306 only from trusted IPs"
echo "  3. Remove /var/www/html/info.php after testing"
echo "  4. Use setup-vhost to configure virtual hosts"
echo ""
echo "MySQL Remote Access:"
echo "  To allow remote access for specific user:"
echo "  CREATE USER 'username'@'%' IDENTIFIED BY 'password';"
echo "  GRANT ALL PRIVILEGES ON database.* TO 'username'@'%';"
echo "  FLUSH PRIVILEGES;"
echo ""
pause 'Press [Enter] key to run mysql_secure_installation ...'
mysql_secure_installation

echo ""
echo "Installation script finished!"
exit 0