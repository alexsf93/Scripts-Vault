# Scripts-Vault

Repositorio centralizado de herramientas, scripts de automatización e infraestructura para la administración de sistemas Windows, Microsoft 365 / Entra ID, Linux (Ubuntu), utilidades de red, herramientas web y scripts de generación de datos de prueba (seeding).

---

## Estructura del Repositorio

```text
Scripts-Vault/
├── Automatizaciones/
│   ├── Automatizaciones_Cliente_W11.ps1
│   ├── Automatizaciones_Instalar_Grafana.sh
│   ├── Automatizaciones_Instalar_N8N.sh
│   ├── Automatizaciones_Instalar_Nagios.sh
│   ├── Automatizaciones_Instalar_Nextcloud.sh
│   ├── Automatizaciones_Instalar_Wordpress.sh
│   └── Automatizaciones_Server_AADS_DNS_DOMINIOA.ps1
├── HTML/
│   └── LiveLogViewer/
│       └── LiveLogViewer.html
├── Juegos/
│   ├── Juego - Arkanoid.py
│   ├── Juego - Pong.ps1
│   ├── Juego - Pong.py
│   └── Juego - Snake.py
├── Pruebas-Seeding/
│   ├── Pruebas-Seeding - Generador_Datos_Exchange.ps1
│   ├── Pruebas-Seeding - Generador_Datos_SharePoint.ps1
│   ├── Pruebas-Seeding - Generador_Permisos_Unicos_SharePoint.ps1
│   └── Pruebas-Seeding - Generador_Usuarios_Teams.ps1
├── Microsoft 365 - Exchange - Limpieza_Correos_Destinatario.ps1
├── Microsoft 365 - Exchange - Recopilacion_Buzones.ps1
├── Microsoft 365 - SharePoint - Auditoria_Permisos.ps1
├── Microsoft 365 - SharePoint - Limpieza_Historial_Versiones.ps1
├── Microsoft 365 - Teams - Eliminacion_Masiva_Usuarios.ps1
├── Microsoft Intune - Auditoria_Asignaciones_Grupo.ps1
├── Microsoft Intune - Registro_Dispositivo_Autopilot.ps1
├── Script - Listener_UDP.ps1
└── Script - Sender_UDP.ps1
```

---

## Catálogo de Herramientas y Scripts

### 1. Administración de Microsoft 365 e Intune

Scripts en PowerShell para la auditoría, mantenimiento y gestión automatizada de entornos cloud en Microsoft 365 y Microsoft Intune.

| Archivo | Plataforma | Descripción |
| :--- | :--- | :--- |
| `Microsoft 365 - SharePoint - Auditoria_Permisos.ps1` | PowerShell / Graph API | Audita permisos en SharePoint Online (sitios, subsitios y carpetas con permisos únicos). Permite selección múltiple, importación por CSV (`-CsvPath`) y genera reportes en HTML interactivo. |
| `Microsoft 365 - SharePoint - Limpieza_Historial_Versiones.ps1` | PowerShell / Graph API | Audita y elimina versiones obsoletas en bibliotecas de SharePoint Online. Calcula el espacio liberado (MB/GB) y genera informes en HTML. |
| `Microsoft 365 - Exchange - Recopilacion_Buzones.ps1` | PowerShell / ExchangeOnline | Recopila y exporta información detallada sobre los buzones de Exchange Online presentándola mediante una interfaz interactiva (`Out-GridView`). |
| `Microsoft 365 - Exchange - Gestion_Listas_Distribucion.ps1` | PowerShell / ExchangeOnline | Automatiza altas, bajas, sustitución/reemplazo global y auditoría de miembros en Listas de Distribución y Grupos habilitados para correo con soporte interactivo y por parámetros. |
| `Microsoft 365 - Exchange - Limpieza_Correos_Destinatario.ps1` | PowerShell / Graph API | Identifica y elimina correos antiguos (>6 meses) por destinatario en carpetas seleccionadas (Enviados, Entrada, Spam, etc.), calculando el espacio liberado. |
| `Microsoft 365 - Teams - Eliminacion_Masiva_Usuarios.ps1` | PowerShell / Teams API | Facilita la desvinculación masiva de miembros o invitados en equipos de Microsoft Teams mediante filtrado por dominio. |
| `Microsoft Intune - Auditoria_Asignaciones_Grupo.ps1` | PowerShell / Graph API | Audita las políticas, perfiles de configuración, aplicaciones, scripts y remediaciones asignadas a un grupo específico de Entra ID / Intune. |
| `Microsoft Intune - Registro_Dispositivo_Autopilot.ps1` | PowerShell | Registra el equipo local en Microsoft Autopilot mediante `Get-WindowsAutopilotInfo` y programa el apagado automático del sistema. |

---

### 2. Automatización de Sistemas e Infraestructura

Scripts para aprovisionamiento desatendido y configuración de servidores y clientes en entornos Windows y Linux.

| Archivo | Entorno | Descripción |
| :--- | :--- | :--- |
| `Automatizaciones/Automatizaciones_Cliente_W11.ps1` | Windows 11 | Post-instalación y optimización de Windows 11 (configuración regional, desinstalación de bloatware e instalación de software base). |
| `Automatizaciones/Automatizaciones_Server_AADS_DNS_DOMINIOA.ps1` | Windows Server | Instalación y configuración desatendida de roles de Active Directory Domain Services (AD DS) y DNS. |
| `Automatizaciones/Automatizaciones_Instalar_Grafana.sh` | Bash / Ubuntu | Despliegue desatendido de Grafana OSS en Ubuntu LTS. |
| `Automatizaciones/Automatizaciones_Instalar_N8N.sh` | Bash / Ubuntu | Instalación de n8n con Node.js, configuración de Nginx como proxy inverso y certificados SSL. |
| `Automatizaciones/Automatizaciones_Instalar_Nagios.sh` | Bash / Ubuntu | Compilación e instalación automatizada de Nagios Core y sus plugins oficiales. |
| `Automatizaciones/Automatizaciones_Instalar_Nextcloud.sh` | Bash / Ubuntu | Despliegue del stack LAMP (Apache, MySQL, PHP) y configuración inicial de Nextcloud. |
| `Automatizaciones/Automatizaciones_Instalar_Wordpress.sh` | Bash / Ubuntu | Despliegue del stack LAMP y aprovisionamiento automatizado de WordPress. |

---

### 3. Herramientas de Red y Visualización Web

Utilidades para diagnóstico de red en capa de transporte y herramientas de análisis local.

| Archivo | Tipo | Descripción |
| :--- | :--- | :--- |
| `HTML/LiveLogViewer/LiveLogViewer.html` | HTML / JS / Bootstrap | Visor web interactivo para la lectura, filtrado y monitoreo de archivos de registro (logs) en tiempo real. |
| `Script - Listener_UDP.ps1` | PowerShell | Inicia un socket de escucha UDP en un puerto configurable para pruebas de conectividad y recepción de paquetes. |
| `Script - Sender_UDP.ps1` | PowerShell | Envía datagramas UDP de prueba hacia un host y puerto de destino. |

---

### 4. Generación de Datos de Prueba (Seeding)

Scripts diseñados para poblar entornos de prueba y validar el funcionamiento de los scripts de auditoría y mantenimiento.

| Archivo | Entorno Target | Descripción |
| :--- | :--- | :--- |
| `Pruebas-Seeding/Pruebas-Seeding - Generador_Datos_SharePoint.ps1` | SharePoint Online | Crea bibliotecas de prueba y genera archivos simulando múltiples versiones para testear scripts de limpieza. |
| `Pruebas-Seeding/Pruebas-Seeding - Generador_Permisos_Unicos_SharePoint.ps1` | SharePoint Online | Crea estructuras de carpetas y rompe la herencia de permisos para validar scripts de auditoría de permisos. |
| `Pruebas-Seeding/Pruebas-Seeding - Generador_Datos_Exchange.ps1` | Exchange Online | Genera tráfico simulado de correos electrónicos antiguos y recientes en un buzón de prueba. |
| `Pruebas-Seeding/Pruebas-Seeding - Generador_Usuarios_Teams.ps1` | Microsoft Teams | Añade usuarios e invitados de prueba con dominios específicos a un equipo para testear la eliminación masiva. |

---

### 5. Juegos Retro

Recreaciones de juegos clásicos para consola y entorno gráfico.

| Archivo | Lenguaje | Descripción |
| :--- | :--- | :--- |
| `Juegos/Juego - Arkanoid.py` | Python (Turtle) | Juego estilo Arkanoid con física de colisiones, power-ups y niveles dinámicos. |
| `Juegos/Juego - Pong.py` | Python (Turtle) | Clon clásico de Pong para 1 o 2 jugadores con marcador e interfaz gráfica. |
| `Juegos/Juego - Snake.py` | Python (Turtle) | Juego de la serpiente con mecánicas de velocidad e ítems especiales. |
| `Juegos/Juego - Pong.ps1` | PowerShell | Implementación del juego Pong ejecutable directamente en la consola de PowerShell. |

---

## Requisitos y Prerrequisitos

- **PowerShell**: Windows PowerShell 5.1 o PowerShell 7+. Requiere permisos de administrador para scripts de sistema local.
  - Módulos requeridos para Microsoft 365:
    - `Microsoft.Graph.Authentication`
    - `ExchangeOnlineManagement`
    - `MicrosoftTeams`
- **Linux**: Ubuntu 22.04 LTS / 24.04 LTS con acceso a `sudo`.
- **Python**: Python 3.x (utiliza únicamente la librería estándar `turtle` y `tkinter`).

---

## Ejemplos de Uso

### Ejecutar auditoría de permisos en SharePoint
```powershell
.\Microsoft 365 - SharePoint - Auditoria_Permisos.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/IT"
```

### Iniciar un socket de escucha UDP en PowerShell
```powershell
.\Script - Listener_UDP.ps1 -Port 514
```

### Ejecutar el visor de logs local
Abrir directamente `HTML/LiveLogViewer/LiveLogViewer.html` en cualquier navegador web moderno (Chrome, Edge, Firefox).

---

## Autor

**Alejandro Suárez** ([@alexsf93](https://github.com/alexsf93))
