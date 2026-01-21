# Scripts-Vault

Bienvenido a **Scripts-Vault**. Este repositorio centraliza una colección de scripts profesionales para la automatización de tareas en sistemas Windows y Linux, incluyendo administración de Exchange Online, despliegues desatendidos en Ubuntu y herramientas de utilidad.

## 📂 Estructura del Repositorio

El repositorio está organizado por categorías para facilitar la localización de herramientas:

- **/** (Raíz): Scripts de utilidad general para Windows/PowerShell.
- **Automatizaciones/**: Scripts para despliegues automáticos (Bash/PowerShell).
- **Juegos/**: Pequeños proyectos recreativos en PowerShell.

## 📜 Inventario de Scripts

### 🛠️ Administración y Utilidades (PowerShell)

| Script | Descripción |
| :--- | :--- |
| `Exchange - Gathering.ps1` | Obtiene un reporte detallado de buzones de Exchange Online (tamaño, cuotas, alias, etc.) en una interfaz gráfica filtrable. |
| `Script - Intune_AutopilotAdd.ps1` | Automatiza el registro de dispositivos en Windows Autopilot y apaga el equipo si el proceso es exitoso. |
| `Script - Listener_UDP.ps1` | Levanta un listener UDP en un puerto local para pruebas de conectividad y diagnóstico de red. |
| `Script - Sender_UDP.ps1` | Envía paquetes UDP de prueba a un puerto local para verificar la recepción de datos. |
| `Teams - Bulk_User_Cleanup.ps1` | Herramienta para la eliminación masiva de miembros o invitados de equipos en Microsoft Teams. |

### 🚀 Despliegues Automáticos (Bash / Linux)

| Script | Descripción |
| :--- | :--- |
| `Automatizaciones_Instalar_Grafana.sh` | Instalación desatendida de Grafana OSS en Ubuntu 24.04 LTS. |
| `Automatizaciones_Instalar_N8N.sh` | Despliegue automático de n8n con Node.js y Reverse Proxy Nginx (SSL autofirmado). |
| `Automatizaciones_Instalar_Nagios.sh` | Instalación completa y desatendida de Nagios Core 4.x y plugins. |
| `Automatizaciones_Instalar_Nextcloud.sh` | Despliegue de Stack LAMP + Nextcloud con configuración de base de datos automática. |
| `Automatizaciones_Instalar_Wordpress.sh` | Despliegue de Stack LAMP + WordPress + WP-CLI con configuración segura. |

### 🔧 Automatización Windows (PowerShell)

| Script | Descripción |
| :--- | :--- |
| `Automatizaciones_Cliente_W11.ps1` | Post-instalación para Windows 11: Zona horaria, limpieza de bloatware e instalación de software básico. |
| `Automatizaciones_Server_AADS_DNS_DOMINIOA.ps1` | Instalación desatendida de controlador de dominio (ADDS + DNS) para laboratorios. |

### 🎮 Juegos (PowerShell)

| Script | Descripción |
| :--- | :--- |
| `Juego - Pong.ps1` | Recreación del clásico Pong jugable directamente en la consola de PowerShell. |

## ⚙️ Requisitos Generales

- **Scripts PowerShell (.ps1):**
  - Windows PowerShell 5.1 o PowerShell 7.x.
  - La mayoría requiere privilegios de Administrador.
  - Algunos scripts requieren módulos específicos (ej. `ExchangeOnlineManagement`, `MicrosoftTeams`).

- **Scripts Bash (.sh):**
  - Ubuntu 22.04 LTS o 24.04 LTS.
  - Privilegios de `root` o `sudo`.
  - Conexión a Internet para descargar paquetes.

## 👤 Autor

**Alejandro Suárez**  
GitHub: [@alexsf93](https://github.com/alexsf93)

---
*Este repositorio se mantiene para uso personal y educativo. Úsalo bajo tu propia responsabilidad.*
