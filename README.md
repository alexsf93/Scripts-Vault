# Scripts-Vault

Colección de scripts y utilidades para administración de sistemas Windows/M365, automatizaciones en Linux (Ubuntu) y proyectos en Python y PowerShell.

## 📁 Estructura del repositorio

```text
.
├── Automatizaciones/     # Scripts de despliegue e infraestructura (Bash / PowerShell)
├── HTML/                 # Herramientas y visualizadores web locales
├── Juegos/               # Juegos retro en Python (Turtle) y PowerShell
└── *.ps1                 # Scripts de administración de M365, Redes e Intune
```

## 📜 Inventario de Scripts

### ☁️ Microsoft 365 y Administración Windows

| Script | Descripción |
| :--- | :--- |
| `Sharepoint - Auditoria permisos.ps1` | Auditoría completa de permisos en SharePoint Online (sitios, subsitios y carpetas con permisos únicos) vía Graph API con reporte HTML interactivo. |
| `Exchange - Gathering.ps1` | Obtiene un reporte detallado de buzones de Exchange Online en una tabla interactiva (`Out-GridView`). |
| `Teams - Bulk_User_Cleanup.ps1` | Eliminación masiva de usuarios (miembros o invitados) en equipos de Microsoft Teams con filtrado por dominio. |
| `Script - Intune_AutopilotAdd.ps1` | Registra el equipo local en Microsoft Autopilot vía `Get-WindowsAutopilotInfo` y apaga el equipo tras completar. |
| `Script - Listener_UDP.ps1` | Inicia un servidor de escucha UDP en el puerto indicado para pruebas de red. |
| `Script - Sender_UDP.ps1` | Envía paquetes UDP de prueba a un servidor local. |

### 🐧 Automatización y Despliegues en Linux (Bash)

| Script | Descripción |
| :--- | :--- |
| `Automatizaciones_Instalar_Grafana.sh` | Instalación desatendida de Grafana OSS en Ubuntu 24.04 LTS. |
| `Automatizaciones_Instalar_N8N.sh` | Despliegue automatizado de n8n con Node.js, Nginx como reverse proxy y SSL autofirmado. |
| `Automatizaciones_Instalar_Nagios.sh` | Compilación e instalación desatendida de Nagios Core 4.x y plugins oficiales. |
| `Automatizaciones_Instalar_Nextcloud.sh` | Instalación del stack LAMP (Apache, MySQL, PHP) y despliegue de Nextcloud. |
| `Automatizaciones_Instalar_Wordpress.sh` | Instalación del stack LAMP y configuración automatizada de WordPress. |

### 💻 Automatización de Sistemas Windows

| Script | Descripción |
| :--- | :--- |
| `Automatizaciones_Cliente_W11.ps1` | Post-instalación y puesta a punto de Windows 11 (región, limpieza de bloatware, software básico). |
| `Automatizaciones_Server_AADS_DNS_DOMINIOA.ps1` | Instalación 100% desatendida de los roles Active Directory Domain Services y DNS. |

### 🎮 Juegos Retro

| Script | Lenguaje | Descripción |
| :--- | :--- | :--- |
| `Juego - Arkanoid.py` | Python | Remake de Arkanoid con estética neón CRT, power-ups y niveles aleatorios usando Turtle. |
| `Juego - Pong.py` | Python | Recreación del clásico Pong estilo CRT para jugar contra la CPU en Turtle. |
| `Juego - Snake.py` | Python | Juego de la serpiente con filtro CRT, frutas especiales y vidas acumulables. |
| `Juego - Pong.ps1` | PowerShell | Pong clásico jugable directamente dentro de la consola de PowerShell. |

---

## ⚙️ Requisitos

- **PowerShell:** Windows PowerShell 5.1 / PowerShell 7.x ejecutado como Administrador. Los scripts de M365 requieren sus respectivos módulos (`Microsoft.Graph.Authentication`, `ExchangeOnlineManagement`, `MicrosoftTeams`).
- **Linux:** Ubuntu 22.04 / 24.04 LTS con permisos de `sudo`.
- **Python:** Python 3.x (librería estándar `turtle`).

---

## 👤 Autor

**Alejandro Suárez** ([@alexsf93](https://github.com/alexsf93))
