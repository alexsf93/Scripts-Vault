#!/bin/bash
# ==============================================================================
# Nombre:        Automatizaciones_Instalar_Wordpress.sh
# Descripción:   Instalador Headless de WordPress para Ubuntu 24.04 LTS.
# Autor:         Alejandro Suárez (@alexsf93)
# Versión:       1.0
# Uso:           ./Automatizaciones_Instalar_Wordpress.sh [params...]
# Notas:         Instala LAMP stack y WordPress. Configura base de datos automáticamente.
# ==============================================================================

set -euo pipefail

# --- INPUTS ---
MYSQL_ROOT_PASS="${1:-changeme_rootpass}"
WP_DB="${2:-wordpress_db}"
WP_USER="${3:-wp_user}"
WP_PASS="${4:-WpUserPassw0rd!}"
SITE_URL="${5:-http://localhost}"
WP_ADMIN="${6:-admin}"
WP_ADMIN_PASS="${7:-AdminWordpress2024!}"
WP_ADMIN_MAIL="${8:-admin@demo.com}"

export DEBIAN_FRONTEND=noninteractive

# --- Actualiza sistema y paquetes esenciales ---
apt-get update -y
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y

apt-get install -y apache2 php php-mysql php-cli php-curl php-gd php-xml php-mbstring mysql-server curl wget unzip

# --- Configura MySQL root ---
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}'; FLUSH PRIVILEGES;"

# --- Prepara base de datos y usuario de WordPress ---
mysql -u root -p"${MYSQL_ROOT_PASS}" -e "CREATE DATABASE IF NOT EXISTS ${WP_DB} DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS '${WP_USER}'@'localhost' IDENTIFIED BY '${WP_PASS}';
GRANT ALL ON ${WP_DB}.* TO '${WP_USER}'@'localhost';
FLUSH PRIVILEGES;"

# --- Instala WordPress ---
cd /tmp
wget -q https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
rm -rf /var/www/html/*
cp -r wordpress/* /var/www/html/

chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

cd /var/www/html
cp wp-config-sample.php wp-config.php

sed -i "s/database_name_here/${WP_DB}/" wp-config.php
sed -i "s/username_here/${WP_USER}/" wp-config.php
sed -i "s/password_here/${WP_PASS}/" wp-config.php

# --- Añade claves secretas únicas ---
SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
sed -i "/AUTH_KEY/d;/SECURE_AUTH_KEY/d;/LOGGED_IN_KEY/d;/NONCE_KEY/d;/AUTH_SALT/d;/SECURE_AUTH_SALT/d;/LOGGED_IN_SALT/d;/NONCE_SALT/d" wp-config.php
echo "$SALT" >> wp-config.php

# --- Instala WP-CLI ---
cd /tmp
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp

# Asegura que www-data pueda usar wp-cli
ln -sf /usr/local/bin/wp /usr/bin/wp

# --- Instala WordPress (headless, sin wizard web) ---
cd /var/www/html

# Espera a que MySQL esté activo
for i in {1..10}; do
    sudo -u www-data wp core is-installed --allow-root && break
    sleep 3
done

# Solo instala si no está instalado aún
if ! sudo -u www-data wp core is-installed --allow-root; then
  sudo -u www-data wp core install --url="${SITE_URL}" --title="WordPress Demo" --admin_user="${WP_ADMIN}" --admin_password="${WP_ADMIN_PASS}" --admin_email="${WP_ADMIN_MAIL}" --skip-email --allow-root
fi

# --- Reinicia Apache ---
systemctl restart apache2

# --- (Opcional) Actualización no atendida ---
unattended-upgrade -d || true

echo "WordPress instalado correctamente en /var/www/html"
