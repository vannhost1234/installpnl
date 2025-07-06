#!/bin/bash
set -euo pipefail

# === CEK ROOT ===
if [[ $EUID -ne 0 ]]; then
   echo "⚠️ Script ini harus dijalankan sebagai root!"
   exit 1
fi

# === INPUT PENGGUNA ===
read -p "🌐 Masukkan domain panel (cth: panel.vannhost.my.id): " DOMAIN
read -p "📧 Masukkan email admin: " ADMIN_EMAIL
read -p "👤 Masukkan username admin: " ADMIN_USER
read -p "🔐 Masukkan password admin: " ADMIN_PASS

echo "🚀 Mulai install Pterodactyl Panel + Wings untuk $DOMAIN"

# === UPDATE DAN INSTALL DEPENDENSI ===
apt update && apt upgrade -y
apt install -y curl wget zip unzip git nginx mysql-server redis composer ufw software-properties-common lsb-release ca-certificates apt-transport-https gnupg

# === INSTALL PHP 8.1 ===
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.1 php8.1-cli php8.1-mbstring php8.1-zip php8.1-bcmath php8.1-tokenizer php8.1-common \
php8.1-curl php8.1-mysql php8.1-mysqlnd php8.1-xml php8.1-fpm php8.1-gd php8.1-fileinfo php8.1-opcache

systemctl enable --now nginx mysql redis php8.1-fpm

# === CEK & BUAT SWAP JIKA <2GB RAM ===
RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$RAM" -lt 2000 ]; then
    echo "⚠️ RAM kurang dari 2GB, membuat swapfile..."
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# === INSTALL PANEL ===
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz && rm panel.tar.gz

chown -R www-data:www-data /var/www/pterodactyl/*
chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache

# === SETUP DATABASE ===
DB_PASS=$(openssl rand -hex 16)
mysql -u root <<MYSQL_SCRIPT
CREATE DATABASE panel;
CREATE USER 'pterodactyl'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# === SETUP PANEL ===
cp .env.example .env
composer install --no-dev --optimize-autoloader

php artisan key:generate --force
php artisan p:environment:setup --email="$ADMIN_EMAIL" --url="https://$DOMAIN" --timezone="Asia/Jakarta" --cache="redis"
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="${DB_PASS}"
php artisan p:environment:mail --driver="smtp" --host="smtp.mailtrap.io" --port=2525 --username=null --password=null --encryption=null --from="$ADMIN_EMAIL"

php artisan migrate --seed --force
php artisan storage:link
php artisan config:clear
php artisan p:user:make --email=$ADMIN_EMAIL --username=$ADMIN_USER --name=$ADMIN_USER --password=$ADMIN_PASS --admin=1

# === KONFIG NGINX ===
cat > /etc/nginx/sites-available/pterodactyl <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -s /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# === SSL LET’S ENCRYPT ===
apt install -y certbot python3-certbot-nginx
certbot --nginx --non-interactive --agree-tos -m $ADMIN_EMAIL -d $DOMAIN

# === FIREWALL ===
ufw allow OpenSSH
ufw allow http
ufw allow https
ufw --force enable

# === INSTALL DOCKER + WINGS ===
curl -sSL https://get.docker.com/ | sh
systemctl enable --now docker

mkdir -p /etc/pterodactyl
cd /etc/pterodactyl
curl -Lo wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
chmod +x wings
cp wings /usr/bin/wings

# === DONE ===
echo ""
echo "✅ Selesai install Pterodactyl Panel + Wings!"
echo "🌐 Buka: https://$DOMAIN"
echo "👤 Username: $ADMIN_USER"
echo "📧 Email: $ADMIN_EMAIL"
echo "🔐 Password: $ADMIN_PASS"
echo "🛠️ MySQL Password: $DB_PASS"
echo "📌 Login ke panel, setup node, dan upload config wings ke: /etc/pterodactyl/config.yml"
