#!/bin/bash
# ==============================================================================
# Nombre:        Automatizaciones_Instalar_Nagios.sh
# Descripcion:   Instalador Headless de Nagios Core para Ubuntu 24.04 LTS.
# Autor:         Alejandro Suarez (@alexsf93)
# Version:       1.0
# Uso:           ./Automatizaciones_Instalar_Nagios.sh [usuario] [contrasena]
# Notas:         Compila e instala Nagios Core y Plugins. Configura acceso web.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Iniciando instalación headless de Nagios Core...${NC}"

NAGIOS_ADMIN="${1:-nagiosadmin}"
NAGIOS_PASS="${2:-Nagios123!}"

echo -e "${CYAN}Actualizando sistema...${NC}"
apt update && apt upgrade -y

echo -e "${CYAN}Instalando dependencias...${NC}"
apt install -y autoconf gcc libapache2-mod-php php unzip apache2 libgd-dev libmcrypt-dev libssl-dev daemon wget bc gawk dc build-essential snmp libnet-snmp-perl gettext make

if ! id "nagios" &>/dev/null; then useradd nagios; fi
if ! grep -q nagios /etc/group; then groupadd nagios; fi
usermod -a -G nagios www-data

NAGIOS_VERSION="4.5.9"
cd /tmp
echo -e "${CYAN}Descargando Nagios Core $NAGIOS_VERSION...${NC}"
wget -q https://github.com/NagiosEnterprises/nagioscore/releases/download/nagios-$NAGIOS_VERSION/nagios-$NAGIOS_VERSION.tar.gz
tar -xzf nagios-$NAGIOS_VERSION.tar.gz
cd nagios-$NAGIOS_VERSION

echo -e "${CYAN}Compilando Nagios Core...${NC}"
./configure --with-httpd-conf=/etc/apache2/sites-enabled
make all
make install
make install-daemoninit
make install-commandmode
make install-config
make install-webconf

echo -e "${CYAN}Instalando plugins de Nagios...${NC}"
cd /tmp
PLUGIN_VERSION="2.4.10"
wget -q https://github.com/nagios-plugins/nagios-plugins/releases/download/release-$PLUGIN_VERSION/nagios-plugins-$PLUGIN_VERSION.tar.gz
tar -xzf nagios-plugins-$PLUGIN_VERSION.tar.gz
cd nagios-plugins-$PLUGIN_VERSION
./configure
make
make install

echo -e "${CYAN}Configurando usuario web para Nagios...${NC}"
htpasswd -b -c /usr/local/nagios/etc/htpasswd.users "$NAGIOS_ADMIN" "$NAGIOS_PASS"

echo -e "${CYAN}Habilitando CGI y reiniciando Apache...${NC}"
a2enmod cgi
systemctl enable apache2
systemctl restart apache2

systemctl enable nagios
systemctl restart nagios

echo -e "\n${GREEN}${BOLD}Nagios Core $NAGIOS_VERSION instalado correctamente.${NC}"
echo -e "${BLUE}Acceso web (sustituye <IP-DE-TU-VM> por la IP pública):${NC} ${YELLOW}http://<IP-DE-TU-VM>/nagios${NC}"
echo -e "${BLUE}Usuario web:${NC} ${YELLOW}${NAGIOS_ADMIN}${NC}"
echo -e "${BLUE}Contraseña web:${NC} ${YELLOW}${NAGIOS_PASS}${NC}\n"
echo -e "${CYAN}IMPORTANTE: Cambia la contraseña tras la primera conexión si es un entorno de producción.${NC}"

exit 0
