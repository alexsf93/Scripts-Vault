<#
.SYNOPSIS
    Microsoft Intune - Auditoría de Asignaciones por Grupo.

.DESCRIPTION
    Este script audita y recopila todas las políticas, perfiles de configuración, aplicaciones,
    cumplimiento (compliance), scripts de PowerShell, remediaciones proactivas y plantillas administrativas
    en Microsoft Intune asignadas a un grupo específico (por Nombre u Object ID).

    Incluye:
    - Control de frecuencia de peticiones (Request Rate Pacing) para evitar que Entra Identity Protection
      o Conditional Access marquen la cuenta/token como arriesgada y fuercen cambio de contraseña.
    - Control de errores robusto y reintentos ante Throttling (HTTP 429/503/504).
    - Verificación automática de sesión Graph activa y módulo de autenticación.
    - Soporte para desambiguación interactiva si existen múltiples grupos con el mismo nombre.
    - Exportación de resultados a Consola, CSV, HTML interactivo u Out-GridView.

.PARAMETER InputGroup
    Object ID (GUID) o Nombre del Grupo de Microsoft Entra / Microsoft 365 a auditar.
    Si no se especifica, se solicitará de forma interactiva.

.PARAMETER ExportCsvPath
    Ruta de archivo para exportar el informe de resultados en formato CSV (UTF-8).

.PARAMETER ExportHtmlPath
    Ruta de archivo para generar un informe HTML interactivo visual con diseño moderno.

.PARAMETER ShowGridView
    Muestra la lista de asignaciones encontradas en una ventana interactiva de Out-GridView (si está disponible).

.PARAMETER RequestDelayMs
    Tiempo de pausa en milisegundos entre cada petición HTTP a Microsoft Graph (Por defecto: 300 ms).
    Pautar las peticiones evita picos inusuales de tráfico que disparan reglas de riesgo en Entra Identity Protection.

.PARAMETER ForceReconnect
    Fuerza el inicio de una nueva sesión de Microsoft Graph omitiendo la conexión existente.

.EXAMPLE
    & '.\Microsoft Intune - Auditoria_Asignaciones_Grupo.ps1'
    Ejecución interactiva con solicitudes por pantalla y pautado seguro (300ms).

.EXAMPLE
    & '.\Microsoft Intune - Auditoria_Asignaciones_Grupo.ps1' -InputGroup "GRP-SISTEMAS-W11" -RequestDelayMs 500
    Audita el grupo por nombre introduciendo una pausa de 500ms entre peticiones para máxima protección.

.EXAMPLE
    & '.\Microsoft Intune - Auditoria_Asignaciones_Grupo.ps1' -InputGroup "a1b2c3d4-e5f6-7890-abcd-1234567890ab" -ExportHtmlPath ".\Reporte_Intune.html"
    Audita el grupo por su Object ID y genera un reporte HTML interactivo.

.NOTES
    Nombre:         Microsoft Intune - Auditoria_Asignaciones_Grupo.ps1
    Autor:          Alejandro Suarez (@alexsf93)
    Version:        2.1.0
    Requisitos:     Módulo Microsoft.Graph.Authentication
    Permisos Graph: Group.Read.All, DeviceManagementConfiguration.Read.All, DeviceManagementApps.Read.All,
                    DeviceManagementServiceConfig.Read.All, DeviceManagementScripts.Read.All
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false, HelpMessage = "Object ID o Nombre del Grupo de Microsoft Entra / M365")]
    [string]$InputGroup = "",

    [Parameter(Mandatory = $false, HelpMessage = "Ruta del archivo CSV para exportar los resultados")]
    [string]$ExportCsvPath = "",

    [Parameter(Mandatory = $false, HelpMessage = "Ruta del archivo HTML para exportar el reporte interactivo")]
    [string]$ExportHtmlPath = "",

    [Parameter(Mandatory = $false, HelpMessage = "Muestra los resultados en una ventana Out-GridView")]
    [switch]$ShowGridView,

    [Parameter(Mandatory = $false, HelpMessage = "Tiempo de pausa en ms entre peticiones Graph para evitar Identity Protection Risk (Def: 300ms)")]
    [int]$RequestDelayMs = 300,

    [Parameter(Mandatory = $false, HelpMessage = "Fuerza la reconexión con Microsoft Graph")]
    [switch]$ForceReconnect
)

# Forzar UTF-8 en consola
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

# ---------------------------------------------------------
# Funciones Auxiliares de Formato y Logs
# ---------------------------------------------------------

function Write-StepHeader {
    param(
        [int]$StepNumber,
        [int]$TotalSteps = 4,
        [string]$Title
    )
    Write-Host "`n=========================================================================" -ForegroundColor Cyan
    Write-Host " Paso ${StepNumber} de ${TotalSteps}: $Title" -ForegroundColor White
    Write-Host "=========================================================================" -ForegroundColor Cyan
}

function Write-StatusMsg {
    param(
        [string]$Message,
        [string]$Status = "INFO"
    )
    switch ($Status) {
        "SUCCESS" { Write-Host "  [+] $Message" -ForegroundColor Green }
        "WORKING" { Write-Host "  [*] $Message" -ForegroundColor Yellow }
        "INFO"    { Write-Host "  [i] $Message" -ForegroundColor Cyan }
        "WARN"    { Write-Host "  [!] $Message" -ForegroundColor DarkYellow }
        "FAIL"    { Write-Host "  [x] $Message" -ForegroundColor Red }
        default   { Write-Host "  [-] $Message" -ForegroundColor Gray }
    }
}

function Get-SpainDateTime {
    param([datetime]$DateTime = [datetime]::UtcNow)
    $tz = $null
    foreach ($tzId in @('Romance Standard Time', 'Europe/Madrid', 'Central European Standard Time')) {
        try {
            $tz = [TimeZoneInfo]::FindSystemTimeZoneById($tzId)
            if ($null -ne $tz) { break }
        } catch { }
    }
    if ($null -ne $tz) {
        $utc = if ($DateTime.Kind -eq [System.DateTimeKind]::Utc) { $DateTime } else { $DateTime.ToUniversalTime() }
        return [TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz)
    } else {
        return Get-Date
    }
}

# ---------------------------------------------------------
# Manejador de Peticiones Graph con Reintentos (Throttling 429/503/504)
# ---------------------------------------------------------

function Invoke-MgGraphWithRetry {
    param(
        [string]$Method = "GET",
        [string]$Uri,
        [int]$MaxRetries = 4
    )
    $Attempt = 0
    while ($true) {
        $Attempt++
        try {
            $response = Invoke-MgGraphRequest -Method $Method -Uri $Uri -ErrorAction Stop
            return $response
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $errorMessage = $_.Exception.Message

            if ($statusCode -in @(429, 503, 504) -and $Attempt -le $MaxRetries) {
                $retryAfter = 5
                if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers.Contains("Retry-After")) {
                    $headerVal = $_.Exception.Response.Headers.GetValues("Retry-After") | Select-Object -First 1
                    if ([int]::TryParse($headerVal, [ref]$retryAfter)) { }
                }
                Write-StatusMsg "Throttling/Latencia Graph (HTTP $statusCode). Reintentando en $retryAfter segundos (Intento $Attempt/$MaxRetries)..." "WARN"
                Start-Sleep -Seconds $retryAfter
            } else {
                throw $_
            }
        }
    }
}

function Get-GraphAllItems ($Uri, [int]$DelayMs = 300) {
    $items = @()
    $nextLink = $Uri
    while ($nextLink) {
        try {
            $response = Invoke-MgGraphWithRetry -Method GET -Uri $nextLink
            if ($response.value) {
                $items += $response.value
            }
            $nextLink = $response.'@odata.nextLink'

            # Control de frecuencia (Rate Pacing) entre páginas para evitar alarmas de Entra Identity Protection
            if ($DelayMs -gt 0) {
                Start-Sleep -Milliseconds $DelayMs
            }
        } catch {
            Write-StatusMsg "Error al consultar el endpoint API Graph ($nextLink): $($_.Exception.Message)" "WARN"
            break
        }
    }
    return $items
}

# ---------------------------------------------------------
# Generador de Informe HTML Interactivo
# ---------------------------------------------------------

function Export-IntuneAuditHtml {
    param(
        [PSCustomObject]$GroupInfo,
        [System.Collections.Generic.List[PSCustomObject]]$ReportData,
        [string]$FilePath
    )

    $executionTime = (Get-SpainDateTime).ToString("dd/MM/yyyy HH:mm:ss")
    $totalAsignaciones = $ReportData.Count

    # Agrupar por Tipo para las tarjetas de resumen
    $tiposAgrupados = $ReportData | Group-Object Tipo

    $cardsHtml = ""
    foreach ($group in $tiposAgrupados) {
        $cardsHtml += @"
        <div class="card">
            <div class="card-number">$($group.Count)</div>
            <div class="card-label">$($group.Name)</div>
        </div>
"@
    }

    $tableRows = ""
    $i = 1
    foreach ($row in $ReportData) {
        $badgeClass = switch -Wildcard ($row.Tipo) {
            "*Configuration Profile*" { "badge-blue" }
            "*Settings Catalog*"      { "badge-purple" }
            "*Compliance*"            { "badge-green" }
            "*Application*"           { "badge-orange" }
            "*PowerShell Script*"     { "badge-yellow" }
            "*Proactive Remediation*" { "badge-teal" }
            "*Group Policy*"          { "badge-indigo" }
            default                   { "badge-gray" }
        }

        $tableRows += @"
        <tr>
            <td>$i</td>
            <td><span class="badge $badgeClass">$([System.Web.HttpUtility]::HtmlEncode($row.Tipo))</span></td>
            <td><strong>$([System.Web.HttpUtility]::HtmlEncode($row.Nombre))</strong></td>
            <td><code class="code-id">$([System.Web.HttpUtility]::HtmlEncode($row.ID_Politica))</code></td>
        </tr>
"@
        $i++
    }

    $htmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Reporte de Auditoría - Asignaciones Intune</title>
    <style>
        :root {
            --bg-color: #0f172a;
            --card-bg: #1e293b;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --accent: #38bdf8;
            --border-color: #334155;
        }
        body {
            font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-main);
            margin: 0;
            padding: 2rem;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        .header {
            background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
            border: 1px solid var(--border-color);
            padding: 1.5rem 2rem;
            border-radius: 12px;
            margin-bottom: 2rem;
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3);
        }
        .header h1 {
            margin: 0 0 0.5rem 0;
            color: var(--accent);
            font-size: 1.8rem;
        }
        .header-meta {
            display: flex;
            gap: 2rem;
            color: var(--text-muted);
            font-size: 0.95rem;
            flex-wrap: wrap;
        }
        .header-meta span strong {
            color: var(--text-main);
        }
        .grid-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1rem;
            margin-bottom: 2rem;
        }
        .card {
            background-color: var(--card-bg);
            border: 1px solid var(--border-color);
            padding: 1.25rem;
            border-radius: 10px;
            text-align: center;
        }
        .card-number {
            font-size: 2rem;
            font-weight: bold;
            color: var(--accent);
        }
        .card-label {
            color: var(--text-muted);
            font-size: 0.85rem;
            margin-top: 0.25rem;
        }
        .search-box {
            margin-bottom: 1.5rem;
        }
        .search-box input {
            width: 100%;
            padding: 0.75rem 1rem;
            border-radius: 8px;
            border: 1px solid var(--border-color);
            background-color: var(--card-bg);
            color: var(--text-main);
            font-size: 1rem;
            box-sizing: border-box;
        }
        .search-box input:focus {
            outline: none;
            border-color: var(--accent);
        }
        table {
            width: 100%;
            border-collapse: collapse;
            background-color: var(--card-bg);
            border-radius: 10px;
            overflow: hidden;
            border: 1px solid var(--border-color);
        }
        th, td {
            padding: 1rem;
            text-align: left;
            border-bottom: 1px solid var(--border-color);
        }
        th {
            background-color: #0f172a;
            color: var(--text-muted);
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.75rem;
            letter-spacing: 0.05em;
        }
        tr:hover {
            background-color: #26334d;
        }
        .badge {
            display: inline-block;
            padding: 0.25rem 0.6rem;
            border-radius: 6px;
            font-size: 0.8rem;
            font-weight: 600;
        }
        .badge-blue   { background-color: #1e3a8a; color: #93c5fd; }
        .badge-purple { background-color: #581c87; color: #d8b4fe; }
        .badge-green  { background-color: #14532d; color: #86efac; }
        .badge-orange { background-color: #7c2d12; color: #fdba74; }
        .badge-yellow { background-color: #713f12; color: #fde047; }
        .badge-teal   { background-color: #134e4a; color: #99f6e4; }
        .badge-indigo { background-color: #312e81; color: #c7d2fe; }
        .badge-gray   { background-color: #334155; color: #cbd5e1; }
        .code-id {
            font-family: monospace;
            background-color: #0f172a;
            padding: 0.2rem 0.4rem;
            border-radius: 4px;
            color: #38bdf8;
            font-size: 0.85rem;
        }
        .footer {
            margin-top: 2rem;
            text-align: center;
            color: var(--text-muted);
            font-size: 0.85rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Auditoría de Asignaciones en Intune</h1>
            <div class="header-meta">
                <span>Grupo: <strong>$([System.Web.HttpUtility]::HtmlEncode($GroupInfo.displayName))</strong></span>
                <span>Object ID: <code class="code-id">$($GroupInfo.id)</code></span>
                <span>Total Asignaciones: <strong>$totalAsignaciones</strong></span>
                <span>Fecha: <strong>$executionTime</strong></span>
            </div>
        </div>

        <div class="grid-cards">
            $cardsHtml
        </div>

        <div class="search-box">
            <input type="text" id="searchInput" onkeyup="filterTable()" placeholder="🔍 Buscar por nombre, tipo o ID de política...">
        </div>

        <table id="resultsTable">
            <thead>
                <tr>
                    <th style="width: 50px;">#</th>
                    <th style="width: 220px;">Tipo de Elemento</th>
                    <th>Nombre de Política / Aplicación</th>
                    <th style="width: 320px;">ID de Política Graph</th>
                </tr>
            </thead>
            <tbody>
                $tableRows
            </tbody>
        </table>

        <div class="footer">
            Generado automáticamente por <strong>Microsoft Intune - Auditoria_Asignaciones_Grupo.ps1</strong> (@alexsf93)
        </div>
    </div>

    <script>
        function filterTable() {
            var input = document.getElementById("searchInput");
            var filter = input.value.toLowerCase();
            var table = document.getElementById("resultsTable");
            var tr = table.getElementsByTagName("tr");

            for (var i = 1; i < tr.length; i++) {
                var show = false;
                var td = tr[i].getElementsByTagName("td");
                for (var j = 0; j < td.length; j++) {
                    if (td[j]) {
                        var textValue = td[j].textContent || td[j].innerText;
                        if (textValue.toLowerCase().indexOf(filter) > -1) {
                            show = true;
                            break;
                        }
                    }
                }
                tr[i].style.display = show ? "" : "none";
            }
        }
    </script>
</body>
</html>
"@

    $htmlContent | Out-File -FilePath $FilePath -Encoding utf8 -Force
}

# ---------------------------------------------------------
# PASO 1: Verificación de Módulos y Conexión Microsoft Graph
# ---------------------------------------------------------

Write-StepHeader -StepNumber 1 -TotalSteps 4 -Title "Verificando Requisitos y Sesión en Microsoft Graph"

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-StatusMsg "El módulo 'Microsoft.Graph.Authentication' no está instalado. Instalándolo desde PowerShell Gallery..." "WORKING"
    try {
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-StatusMsg "Módulo 'Microsoft.Graph.Authentication' instalado correctamente." "SUCCESS"
    } catch {
        Write-StatusMsg "Error al instalar el módulo 'Microsoft.Graph.Authentication': $($_.Exception.Message)" "FAIL"
        return
    }
}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$RequiredScopes = @(
    "Group.Read.All",
    "DeviceManagementConfiguration.Read.All",
    "DeviceManagementApps.Read.All",
    "DeviceManagementServiceConfig.Read.All",
    "DeviceManagementScripts.Read.All"
)

$IsConnected = $false
try {
    $CurrentContext = Get-MgContext -ErrorAction SilentlyContinue
    if ($CurrentContext -and (-not $ForceReconnect)) {
        Write-StatusMsg "Sesión activa detectada en Graph: Account=$($CurrentContext.Account), TenantId=$($CurrentContext.TenantId)" "SUCCESS"
        $IsConnected = $true
    }
} catch { }

if (-not $IsConnected -or $ForceReconnect) {
    Write-StatusMsg "Iniciando sesión en Microsoft Graph con permisos de lectura para Intune..." "WORKING"
    try {
        if ($env:ACC_CLOUD -or $env:AZURE_HTTP_USER_AGENT -match 'cloud-shell') {
            Connect-MgGraph -Scopes $RequiredScopes -UseDeviceAuthentication -NoWelcome -ErrorAction Stop
        } else {
            try {
                Connect-MgGraph -Scopes $RequiredScopes -NoWelcome -ErrorAction Stop
            } catch {
                Write-StatusMsg "Conexión interactiva estándar falló, reintentando mediante código de dispositivo..." "WARN"
                Connect-MgGraph -Scopes $RequiredScopes -UseDeviceAuthentication -NoWelcome -ErrorAction Stop
            }
        }
        Write-StatusMsg "Conexión a Microsoft Graph establecida con éxito." "SUCCESS"
    } catch {
        Write-StatusMsg "No se pudo conectar a Microsoft Graph: $($_.Exception.Message)" "FAIL"
        return
    }
}

# Informar del mecanismo anti-riesgo
if ($RequestDelayMs -gt 0) {
    Write-StatusMsg "Control de frecuencia activo: Pausa de ${RequestDelayMs}ms entre peticiones Graph para prevenir alertas en Entra Identity Protection." "INFO"
}

# ---------------------------------------------------------
# PASO 2: Identificación y Selección del Grupo Objetivos
# ---------------------------------------------------------

Write-StepHeader -StepNumber 2 -TotalSteps 4 -Title "Resolución del Grupo en Entra ID"

if ([string]::IsNullOrWhiteSpace($InputGroup)) {
    Write-Host ""
    $InputGroup = Read-Host -Prompt "Introduce el Object ID (GUID) o el Nombre del Grupo"
}

if ([string]::IsNullOrWhiteSpace($InputGroup)) {
    Write-StatusMsg "No se proporcionó ningún parámetro o nombre de grupo. Operación cancelada." "FAIL"
    return
}

$GuidRegex = "^(\{){0,1}[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}(\}){0,1}$"
$SelectedGroup = $null

if ($InputGroup -match $GuidRegex) {
    Write-StatusMsg "Buscando grupo por Object ID (GUID): $InputGroup..." "WORKING"
    try {
        $SelectedGroup = Invoke-MgGraphWithRetry -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$InputGroup"
    } catch {
        Write-StatusMsg "No se encontró ningún grupo con el Object ID '$InputGroup'." "FAIL"
        return
    }
} else {
    Write-StatusMsg "Buscando grupo por Nombre de Mostrar: '$InputGroup'..." "WORKING"
    $EncodedName = [System.Uri]::EscapeDataString($InputGroup)
    try {
        $GroupQuery = Invoke-MgGraphWithRetry -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$EncodedName'"
        $MatchingGroups = $GroupQuery.value

        if (-not $MatchingGroups -or $MatchingGroups.Count -eq 0) {
            # Búsqueda parcial si la búsqueda exacta no devuelve resultados
            Write-StatusMsg "No se encontró coincidencia exacta. Realizando búsqueda parcial..." "WARN"
            $PartialQuery = Invoke-MgGraphWithRetry -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName, '$EncodedName')"
            $MatchingGroups = $PartialQuery.value
        }

        if (-not $MatchingGroups -or $MatchingGroups.Count -eq 0) {
            Write-StatusMsg "No se encontró ningún grupo con el nombre o patrón '$InputGroup'." "FAIL"
            return
        } elseif ($MatchingGroups.Count -eq 1) {
            $SelectedGroup = $MatchingGroups[0]
        } else {
            Write-StatusMsg "Se encontraron $($MatchingGroups.Count) grupos que coinciden con '$InputGroup':" "WARN"
            for ($idx = 0; $idx -lt $MatchingGroups.Count; $idx++) {
                Write-Host "   [$($idx + 1)] $($MatchingGroups[$idx].displayName) (ID: $($MatchingGroups[$idx].id))" -ForegroundColor Cyan
            }
            $Selection = Read-Host -Prompt "Selecciona el número del grupo que deseas auditar (1-$($MatchingGroups.Count))"
            $SelectionInt = 0
            if ([int]::TryParse($Selection, [ref]$SelectionInt) -and $SelectionInt -ge 1 -and $SelectionInt -le $MatchingGroups.Count) {
                $SelectedGroup = $MatchingGroups[$SelectionInt - 1]
            } else {
                Write-StatusMsg "Selección no válida. Operación abortada." "FAIL"
                return
            }
        }
    } catch {
        Write-StatusMsg "Error al consultar la API de grupos en Graph: $($_.Exception.Message)" "FAIL"
        return
    }
}

$TargetGroupId = $SelectedGroup.id
Write-StatusMsg "Grupo Seleccionado: $($SelectedGroup.displayName) [ID: $TargetGroupId]" "SUCCESS"

# ---------------------------------------------------------
# PASO 3: Auditoría Exhaustiva de Áreas de Intune
# ---------------------------------------------------------

Write-StepHeader -StepNumber 3 -TotalSteps 4 -Title "Auditando Asignaciones en Intune (Pautado Anti-Riesgo Activo)"

$Report = [System.Collections.Generic.List[PSCustomObject]]::new()

# 1. Device Configuration Profiles (v1.0)
Write-StatusMsg "1/7 Auditando Configuration Profiles (Clásicos)..." "WORKING"
try {
    $ConfigProfiles = Get-GraphAllItems -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations?`$expand=assignments" -DelayMs $RequestDelayMs
    foreach ($Profile in $ConfigProfiles) {
        if ($Profile.assignments.target.groupId -contains $TargetGroupId) {
            $Report.Add([PSCustomObject]@{
                Tipo        = "Configuration Profile"
                Nombre      = $Profile.displayName
                ID_Politica = $Profile.id
            })
        }
    }
} catch {
    Write-StatusMsg "Excepción evaluando Configuration Profiles: $($_.Exception.Message)" "WARN"
}

if ($RequestDelayMs -gt 0) { Start-Sleep -Milliseconds ($RequestDelayMs * 2) }

# 2. Settings Catalog & Endpoint Security (Beta)
Write-StatusMsg "2/7 Auditando Settings Catalog & Endpoint Security Policies..." "WORKING"
try {
    $SettingsCatalog = Get-GraphAllItems -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$expand=assignments" -DelayMs $RequestDelayMs
    foreach ($Policy in $SettingsCatalog) {
        if ($Policy.assignments.target.groupId -contains $TargetGroupId) {
            $Report.Add([PSCustomObject]@{
                Tipo        = "Settings Catalog / Policy"
                Nombre      = $Policy.name
                ID_Politica = $Policy.id
            })
        }
    }
} catch {
    Write-StatusMsg "Excepción evaluando Settings Catalog: $($_.Exception.Message)" "WARN"
}

if ($RequestDelayMs -gt 0) { Start-Sleep -Milliseconds ($RequestDelayMs * 2) }

# 3. Compliance Policies (v1.0)
Write-StatusMsg "3/7 Auditando Compliance Policies (Cumplimiento)..." "WORKING"
try {
    $CompliancePolicies = Get-GraphAllItems -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies?`$expand=assignments" -DelayMs $RequestDelayMs
    foreach ($Policy in $CompliancePolicies) {
        if ($Policy.assignments.target.groupId -contains $TargetGroupId) {
            $Report.Add([PSCustomObject]@{
                Tipo        = "Compliance Policy"
                Nombre      = $Policy.displayName
                ID_Politica = $Policy.id
            })
        }
    }
} catch {
    Write-StatusMsg "Excepción evaluando Compliance Policies: $($_.Exception.Message)" "WARN"
}

if ($RequestDelayMs -gt 0) { Start-Sleep -Milliseconds ($RequestDelayMs * 2) }

# 4. Applications (v1.0)
Write-StatusMsg "4/7 Auditando Aplicaciones (Móviles / Win32 / M365 Apps)..." "WORKING"
try {
    $Apps = Get-GraphAllItems -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$expand=assignments" -DelayMs $RequestDelayMs
    foreach ($App in $Apps) {
        if ($App.assignments.target.groupId -contains $TargetGroupId) {
            $Report.Add([PSCustomObject]@{
                Tipo        = "Application"
                Nombre      = $App.displayName
                ID_Politica = $App.id
            })
        }
    }
} catch {
    Write-StatusMsg "Excepción evaluando Aplicaciones: $($_.Exception.Message)" "WARN"
}

if ($RequestDelayMs -gt 0) { Start-Sleep -Milliseconds ($RequestDelayMs * 2) }

# 5. Device Management Scripts (Beta)
Write-StatusMsg "5/7 Auditando Scripts PowerShell de Dispositivos..." "WORKING"
try {
    $Scripts = Get-GraphAllItems -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts?`$expand=assignments" -DelayMs $RequestDelayMs
    foreach ($Script in $Scripts) {
        if ($Script.assignments.target.groupId -contains $TargetGroupId) {
            $Report.Add([PSCustomObject]@{
                Tipo        = "PowerShell Script"
                Nombre      = $Script.displayName
                ID_Politica = $Script.id
            })
        }
    }
} catch {
    Write-StatusMsg "Excepción evaluando PowerShell Scripts: $($_.Exception.Message)" "WARN"
}

if ($RequestDelayMs -gt 0) { Start-Sleep -Milliseconds ($RequestDelayMs * 2) }

# 6. Proactive Remediations (Beta)
Write-StatusMsg "6/7 Auditando Proactive Remediations (Health Scripts)..." "WORKING"
try {
    $Remediations = Get-GraphAllItems -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts?`$expand=assignments" -DelayMs $RequestDelayMs
    foreach ($Remediation in $Remediations) {
        if ($Remediation.assignments.target.groupId -contains $TargetGroupId) {
            $Report.Add([PSCustomObject]@{
                Tipo        = "Proactive Remediation"
                Nombre      = $Remediation.displayName
                ID_Politica = $Remediation.id
            })
        }
    }
} catch {
    Write-StatusMsg "Excepción evaluando Proactive Remediations: $($_.Exception.Message)" "WARN"
}

if ($RequestDelayMs -gt 0) { Start-Sleep -Milliseconds ($RequestDelayMs * 2) }

# 7. Group Policy Configurations / Administrative Templates (Beta)
Write-StatusMsg "7/7 Auditando Administrative Templates (Group Policy Configurations)..." "WORKING"
try {
    $GpoConfigs = Get-GraphAllItems -Uri "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations?`$expand=assignments" -DelayMs $RequestDelayMs
    foreach ($Gpo in $GpoConfigs) {
        if ($Gpo.assignments.target.groupId -contains $TargetGroupId) {
            $Report.Add([PSCustomObject]@{
                Tipo        = "Group Policy Configuration"
                Nombre      = $Gpo.displayName
                ID_Politica = $Gpo.id
            })
        }
    }
} catch {
    Write-StatusMsg "Excepción evaluando Group Policy Configurations: $($_.Exception.Message)" "WARN"
}

# ---------------------------------------------------------
# PASO 4: Presentación y Exportación de Resultados
# ---------------------------------------------------------

Write-StepHeader -StepNumber 4 -TotalSteps 4 -Title "Presentación e Exportación del Reporte"

if ($Report.Count -gt 0) {
    Write-StatusMsg "Se encontraron $($Report.Count) asignaciones para el grupo '$($SelectedGroup.displayName)':`n" "SUCCESS"

    $Report | Format-Table -AutoSize

    # Exportación a CSV si se especificó la ruta
    if (-not [string]::IsNullOrWhiteSpace($ExportCsvPath)) {
        try {
            $Report | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding utf8 -Force
            Write-StatusMsg "Informe exportado exitosamente a CSV: $ExportCsvPath" "SUCCESS"
        } catch {
            Write-StatusMsg "Error al exportar a CSV ($ExportCsvPath): $($_.Exception.Message)" "FAIL"
        }
    }

    # Exportación a HTML si se especificó la ruta
    if (-not [string]::IsNullOrWhiteSpace($ExportHtmlPath)) {
        try {
            Export-IntuneAuditHtml -GroupInfo $SelectedGroup -ReportData $Report -FilePath $ExportHtmlPath
            Write-StatusMsg "Informe HTML interactivo generado en: $ExportHtmlPath" "SUCCESS"
        } catch {
            Write-StatusMsg "Error al generar el informe HTML ($ExportHtmlPath): $($_.Exception.Message)" "FAIL"
        }
    }

    # Visualización en Out-GridView si se activó el switch
    if ($ShowGridView) {
        try {
            $Report | Out-GridView -Title "Intune Assignments - $($SelectedGroup.displayName)"
        } catch {
            Write-StatusMsg "No se pudo abrir Out-GridView en este entorno: $($_.Exception.Message)" "WARN"
        }
    }

} else {
    Write-StatusMsg "No se encontraron políticas, perfiles ni aplicaciones asignadas a este grupo en Intune." "WARN"
}

Write-Host "`nProceso finalizado exitosamente.`n" -ForegroundColor Green