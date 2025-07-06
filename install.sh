#!/bin/bash
set -euo pipefail

# === CEK ROOT ===
if [[ $EUID -ne 0 ]]; then
   echo "⚠️ Harus dijalankan sebagai root!"
   exit 1
fi

# === INPUT ===
read -p "🌐 Domain panel (cth: panel.vannhost.my.id): " DOMAIN
read -p "📧 Email admin: " ADMIN_EMAIL
read -p "👤 Username admin: " ADMIN_USER
read -p "🔐 Password admin: " ADMIN_PASS
read -p "📦 Hostname VPS ini (cth: node-1): " NODE_NAME

echo "🚀 Mulai setup Pterodactyl Panel + Wings + Node..."

# === DEPENDENSI DASAR ===
apt update && apt upgrade -y
apt install -y curl wget zip unzip git nginx mysql-server redis composer ufw software-properties-common lsb-release ca-certificates apt-transport-https gnupg

# === PHP 8.1 ===
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.1 php8.1-cli php8.1-mysql php8.1-mysqlnd php8.1-xml php8.1-fpm php8.1-curl php8.1-mbstring php8.1-zip php8.1-bcmath php8.1-gd php8.1-fileinfo php8.1-tokenizer php8.1-common

systemctl enable --now nginx mysql redis php8.1-fpm

# === SWAPFILE (untuk RAM kecil) ===
RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$RAM" -lt 2000 ]; then
    echo "⚠️ RAM <2GB, membuat swapfile..."
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
chown -R www-data:www-data . && chmod -R 755 storage bootstrap/cache

# === DATABASE ===
DB_PASS=$(openssl rand -hex 16)
mysql -u root <<MYSQL
CREATE DATABASE panel;
CREATE USER 'pterodactyl'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost';
FLUSH PRIVILEGES;
MYSQL

# === SETUP PANEL ===
cp .env.example .env
composer install --no-dev --optimize-autoloader

php artisan key:generate --force
php artisan p:environment:setup --email="$ADMIN_EMAIL" --url="https://$DOMAIN" --timezone="Asia/Jakarta" --cache="redis"
php artisan p:environment:database --host=127.0.0.1 --port=3306 --database=panel --username=pterodactyl --password=${DB_PASS}
php artisan p:environment:mail --driver=smtp --host=smtp.mailtrap.io --port=2525 --username=null --password=null --encryption=null --from="$ADMIN_EMAIL"

php artisan migrate --seed --force
php artisan storage:link
php artisan config:clear
php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --name="$ADMIN_USER" --password="$ADMIN_PASS" --admin=1

# === NGINX CONFIG ===
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

# === DOCKER + WINGS ===
curl -sSL https://get.docker.com/ | sh
systemctl enable --now docker

mkdir -p /etc/pterodactyl
cd /etc/pterodactyl
curl -Lo wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
chmod +x wings
cp wings /usr/bin/wings

# === AUTO CONFIG wings.yml ===
PANEL_URL="https://$DOMAIN"
TOKEN=$(openssl rand -hex 20)
UUID=$(uuidgen)
NODE_IP=$(curl -s ipv4.icanhazip.com)

cat > /etc/pterodactyl/config.yml <<EOF
debug: false
uuid: $UUID
token_id: $TOKEN
token: $(openssl rand -hex 32)
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false
system:
  data: /var/lib/pterodactyl
  sftp:
    port: 2022
    ip: 0.0.0.0
remote:
  base: "$PANEL_URL"
  key: "$TOKEN"
EOF

useradd -r -m -U -d /etc/pterodactyl -s /bin/false pterodactyl
chown -R pterodactyl:pterodactyl /etc/pterodactyl

# === SYSTEMD wings.service ===
cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings.pid
ExecStart=/usr/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable --now wings

# === DONE ===
echo ""
echo "✅ Selesai install Pterodactyl Panel + Wings + Node!"
echo "🌐 Akses Panel: https://$DOMAIN"
echo "👤 Username: $ADMIN_USER"
echo "📧 Email: $ADMIN_EMAIL"
echo "🔐 Password: $ADMIN_PASS"
echo "📦 Node name: $NODE_NAME"
echo "📍 Wings config: /etc/pterodactyl/config.yml"
echo "⚙️  Wings Status: systemctl status wings"
