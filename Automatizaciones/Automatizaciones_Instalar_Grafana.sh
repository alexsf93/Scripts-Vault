#!/bin/bash
# ==============================================================================
# Nombre:        Automatizaciones_Instalar_Grafana.sh
# Descripción:   Instalador headless de Grafana OSS en Ubuntu 24.04 LTS.
# Autor:         Alejandro Suárez (@alexsf93)
# Versión:       1.0
# Uso:           ./Automatizaciones_Instalar_Grafana.sh [GRAFANA_URL]
# Notas:         Instala dependencias, añade repositorio oficial y configura el servicio.
# ==============================================================================

set -euo pipefail

GRAFANA_URL="${1:-http://localhost:3000}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Instalando dependencias...${NC}"
sudo apt update && sudo apt upgrade -y
sudo apt install -y wget apt-transport-https software-properties-common

echo -e "${CYAN}Añadiendo repositorio de Grafana OSS...${NC}"
sudo wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key
echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null

sudo apt update
echo -e "${CYAN}Instalando Grafana OSS...${NC}"
sudo apt install -y grafana

echo -e "${CYAN}Habilitando e iniciando el servicio Grafana...${NC}"
sudo systemctl enable grafana-server
sudo systemctl start grafana-server

sleep 2

echo -e "${GREEN}${BOLD}Grafana OSS instalado correctamente.${NC}"
echo -e "${BLUE}Acceso web (puerto 3000):${NC} ${YELLOW}${GRAFANA_URL}${NC}\n"
echo -e "${BLUE}Usuario por defecto:${NC} ${YELLOW}admin${NC}"
echo -e "${BLUE}Contraseña por defecto:${NC} ${YELLOW}admin${NC}"
echo -e "${CYAN}¡Se recomienda cambiar la contraseña en el primer login!${NC}"
exit 0
