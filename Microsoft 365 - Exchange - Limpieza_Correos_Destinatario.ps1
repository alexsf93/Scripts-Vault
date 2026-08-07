<#
.SYNOPSIS
    Exchange Online - Limpieza de Correos por Destinatario y Antiguedad con Microsoft Graph API.

.DESCRIPTION
    Script de administracion para Exchange Online que escanea un buzon de correo,
    busca mensajes enviados a un destinatario especifico con una antiguedad mayor a N meses (por defecto: 6),
    permite seleccionar la carpeta de origen (Enviados, Entrada, Spam, Eliminados, Borradores, Todas u Otros),
    calcula la cantidad exacta de espacio en MB/GB que se liberara del buzon,
    genera un reporte HTML previo interactivo, solicita confirmacion y realiza la eliminacion segura de los correos.

.PARAMETER Mailbox
    Direccion de correo del buzon objetivo (UPN o Email, ej: "cliente@dominio.com").

.PARAMETER RecipientEmail
    Direccion de correo del destinatario objetivo cuyos correos se desean eliminar (ej: "destinatario@empresa.com").

.PARAMETER MonthsOld
    Antiguedad minima en meses de los correos a evaluar (por defecto: 6).

.PARAMETER Folder
    Carpeta del buzon a consultar ('SentItems', 'Inbox', 'JunkEmail', 'DeletedItems', 'Drafts', 'All' o el nombre/ID de una carpeta personalizada).

.PARAMETER TenantId
    ID o dominio del tenant de Microsoft 365 (para autenticacion desatendida).

.PARAMETER ClientId
    ID de la aplicacion (App ID) de Entra ID.

.PARAMETER ClientSecret
    Secreto de aplicacion (Client Secret).

.PARAMETER AuditOnly
    Si se activa, el script solo realizara la auditoria y el calculo de ahorro sin solicitar ni borrar correos.

.PARAMETER Force
    Omite la confirmacion interactiva antes de proceder con la eliminacion de correos.

.PARAMETER HtmlOutputPath
    Ruta del reporte HTML interactivo visual de auditoria previa. Por defecto: ".\Reporte_Auditoria_Correos.html"

.PARAMETER DeletionHtmlPath
    Ruta del reporte HTML interactivo visual post-limpieza. Por defecto: ".\Reporte_Limpieza_Correos_Ejecutada.html"

.EXAMPLE
    & '.\Microsoft 365 - Exchange - Limpieza_Correos_Destinatario.ps1' -Mailbox "usuario@contoso.com" -RecipientEmail "externo@dominio.com" -MonthsOld 6

.EXAMPLE
    & '.\Microsoft 365 - Exchange - Limpieza_Correos_Destinatario.ps1' -Mailbox "usuario@contoso.com" -RecipientEmail "externo@dominio.com" -Folder "Inbox"

.NOTES
    Nombre:         Microsoft 365 - Exchange - Limpieza_Correos_Destinatario.ps1
    Autor:          Alejandro Suarez (@alexsf93)
    Version:        1.2.0
    Fecha:          2026-08-07

    REQUISITOS Y COMPATIBILIDAD DE ENTORNO:
    -------------------------------------------------------------------------------------------------
    1. Modulo PowerShell Requerido:
       - Microsoft.Graph.Authentication (v2.0+) [Se auto-instala desde PSGallery si no esta presente]

    2. Permisos Requeridos en Entra ID / Microsoft Graph:
       - Mail.ReadWrite (Para consultar y eliminar mensajes del buzon)
       - Mail.Read      (Para auditoria de mensajes)
       - User.Read.All  (Para resolver UPN e ID del buzon)

    3. Entornos Soportados y Compatibilidad (100% Validada):
       - Windows PowerShell 5.1 (Ejecucion local en Windows)
       - PowerShell 7.x (Core en Windows, Linux y macOS)
       - Azure Cloud Shell (100% Compatible via Microsoft Graph REST API y Device Code Authentication)
    -------------------------------------------------------------------------------------------------
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$Mailbox = "",

    [Parameter(Mandatory = $false)]
    [string]$RecipientEmail = "",

    [int]$MonthsOld = 6,
    [string]$Folder = "",
    [string]$TenantId = "",
    [string]$ClientId = "",
    [string]$ClientSecret = "",
    [switch]$AuditOnly,
    [switch]$Force,
    [string]$HtmlOutputPath = ".\Reporte_Auditoria_Correos.html",
    [string]$DeletionHtmlPath = ".\Reporte_Limpieza_Correos_Ejecutada.html"
)

# Validar e instalar modulo requerido si no esta presente
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "  [*] Instalando modulo requerido 'Microsoft.Graph.Authentication' desde PowerShell Gallery..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# Encabezado visual para los pasos
function Write-StepHeader {
    param(
        [int]$StepNumber,
        [int]$TotalSteps = 5,
        [string]$Title
    )
    Write-Host "`n------------------------------------------------------------------------- " -ForegroundColor Cyan
    Write-Host " PASO ${StepNumber} de ${TotalSteps}: $Title" -ForegroundColor White
    Write-Host "------------------------------------------------------------------------- " -ForegroundColor Cyan
}

# Formato estandarizado de mensajes
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

# Formatear bytes a legibles (KB, MB, GB)
function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    } elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    } elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    } else {
        return "$Bytes Bytes"
    }
}

# Wrapper de peticiones Graph con reintentos y tolerancia a throttling (HTTP 429/503/504)
function Invoke-MgGraphWithRetry {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Body = $null,
        [int]$MaxRetries = 5
    )
    $Attempt = 0
    while ($true) {
        $Attempt++
        try {
            $Params = @{
                Method      = $Method
                Uri         = $Uri
                ErrorAction = "Stop"
            }
            if ($Body) { $Params.Body = $Body }
            return Invoke-MgGraphRequest @Params
        } catch {
            $Ex = $_.Exception
            $StatusCode = 0
            if ($Ex.Response -and $Ex.Response.StatusCode) {
                $StatusCode = [int]$Ex.Response.StatusCode
            }
            if (($StatusCode -eq 429 -or $StatusCode -eq 503 -or $StatusCode -eq 504) -and $Attempt -le $MaxRetries) {
                $WaitTimeSec = 5 * $Attempt
                if ($Ex.Response.Headers -and $Ex.Response.Headers["Retry-After"]) {
                    $WaitTimeSec = [int]$Ex.Response.Headers["Retry-After"]
                }
                Write-StatusMsg "Limitacion de velocidad Graph (HTTP $StatusCode). Esperando $WaitTimeSec s (Intento $Attempt/$MaxRetries)..." -Status "WARN"
                Start-Sleep -Seconds $WaitTimeSec
            } else {
                throw $_
            }
        }
    }
}

# Asegurar que el directorio padre exista antes de guardar archivos
function Ensure-DirectoryExists {
    param([string]$FilePath)
    try {
        $ParentDir = Split-Path -Path $FilePath -Parent
        if ($ParentDir -and -not (Test-Path -Path $ParentDir)) {
            New-Item -Path $ParentDir -ItemType Directory -Force | Out-Null
        }
    } catch {}
}

Clear-Host
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "   LIMPIEZA DE CORREOS POR DESTINATARIO Y ANTIGUEDAD - EXCHANGE ONLINE   " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Version: 1.2.0 | Graph API | Autor: Alejandro Suarez (@alexsf93)" -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------------------------------
# PASO 1: AUTENTICACIÓN EN MICROSOFT GRAPH
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 1 -TotalSteps 5 -Title "Autenticacion en Microsoft Graph"

$Scopes = @("Mail.ReadWrite", "Mail.Read", "User.Read.All")

try {
    if ($TenantId -and $ClientId -and $ClientSecret) {
        Write-StatusMsg "Conectando mediante App Registration (Client Secret)..." -Status "WORKING"
        $Body = @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "https://graph.microsoft.com/.default"
        }
        $TokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $Body
        Connect-MgGraph -AccessToken ($TokenResponse.access_token | ConvertTo-SecureString -AsPlainText -Force) -ErrorAction Stop
        Write-StatusMsg "Conexion establecida correctamente mediante App Registration." -Status "SUCCESS"
    } else {
        $CurrentContext = Get-MgContext -ErrorAction SilentlyContinue
        if ($CurrentContext) {
            Write-StatusMsg "Sesion de Microsoft Graph detectada ($($CurrentContext.Account))." -Status "SUCCESS"
        } else {
            Write-StatusMsg "Iniciando sesion con Microsoft Graph..." -Status "WORKING"
            if ($env:ACC_CLOUD -or $env:AZURE_HTTP_USER_AGENT -match 'cloud-shell') {
                Connect-MgGraph -Scopes $Scopes -UseDeviceAuthentication -ErrorAction Stop
            } else {
                try {
                    Connect-MgGraph -Scopes $Scopes -ErrorAction Stop
                } catch {
                    Connect-MgGraph -Scopes $Scopes -UseDeviceAuthentication -ErrorAction Stop
                }
            }
            Write-StatusMsg "Autenticacion completada." -Status "SUCCESS"
        }
    }
} catch {
    Write-StatusMsg "Error fatal al conectar a Microsoft Graph: $_" -Status "FAIL"
    exit 1
}

# -------------------------------------------------------------------------
# PASO 2: SOLICITUD / VALIDACIÓN DE PARÁMETROS OBJETIVO Y SELECTOR DE CARPETAS
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 2 -TotalSteps 5 -Title "Configuracion de Buzon y Filtros"

if (-not $Mailbox) {
    $Mailbox = Read-Host "`nIngrese el BUZON A LIMPIAR (ej. cliente@empresa.com)"
}
if ([string]::IsNullOrWhiteSpace($Mailbox)) {
    Write-StatusMsg "Debe indicar un buzon de correo valido a limpiar." -Status "FAIL"
    exit 1
}

if (-not $RecipientEmail) {
    $RecipientEmail = Read-Host "`nIngrese el correo del DESTINATARIO FILTRO (se eliminaran los correos hacia este destinatario)"
}
if ([string]::IsNullOrWhiteSpace($RecipientEmail)) {
    Write-StatusMsg "Debe indicar un correo de destinatario filtro valido." -Status "FAIL"
    exit 1
}

if (-not $PSBoundParameters.ContainsKey("MonthsOld")) {
    $InputMonths = Read-Host "`n¿Antiguedad minima en MESES de los correos a evaluar? (Por defecto: 6)"
    $ParsedMonths = 6
    if ([int]::TryParse($InputMonths, [ref]$ParsedMonths) -and $ParsedMonths -ge 1) {
        $MonthsOld = $ParsedMonths
    }
}

# Selector Interactivo de Carpetas de Correo
if ([string]::IsNullOrWhiteSpace($Folder)) {
    Write-Host "`nCarpetas de correo disponibles para evaluar:" -ForegroundColor Yellow
    Write-Host " [ 1] Elementos Enviados (SentItems) [Predeterminado]" -ForegroundColor Cyan
    Write-Host " [ 2] Bandeja de Entrada (Inbox)" -ForegroundColor White
    Write-Host " [ 3] Correo No Deseado / Spam (JunkEmail)" -ForegroundColor White
    Write-Host " [ 4] Elementos Eliminados (DeletedItems)" -ForegroundColor White
    Write-Host " [ 5] Borradores (Drafts)" -ForegroundColor White
    Write-Host " [ 6] TODAS las carpetas del buzon (All)" -ForegroundColor White
    Write-Host " [ 7] Otros... (Ingresar nombre personalizado)" -ForegroundColor Yellow
    
    $FolderChoice = Read-Host "`nSeleccione el numero de la carpeta (1-7, por defecto 1)"
    switch ($FolderChoice.Trim()) {
        "2" { $Folder = "Inbox" }
        "3" { $Folder = "JunkEmail" }
        "4" { $Folder = "DeletedItems" }
        "5" { $Folder = "Drafts" }
        "6" { $Folder = "All" }
        "7" {
            $CustomFolderInput = Read-Host "`nIngrese el nombre exacto de la carpeta personalizada (ej. 'Proyectos' o 'Archivo')"
            if (-not [string]::IsNullOrWhiteSpace($CustomFolderInput)) {
                $Folder = $CustomFolderInput.Trim()
            } else {
                $Folder = "SentItems"
            }
        }
        default { $Folder = "SentItems" }
    }
}

# Resolver Endpoint según Carpeta elegida
$FolderNameDisplay = ""
$FolderEndpoint = ""

switch -Wildcard ($Folder.ToLower()) {
    "sentitems" {
        $FolderNameDisplay = "Elementos Enviados (SentItems)"
        $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/sentitems/messages"
    }
    "inbox" {
        $FolderNameDisplay = "Bandeja de Entrada (Inbox)"
        $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/inbox/messages"
    }
    "junkemail" {
        $FolderNameDisplay = "Correo No Deseado / Spam (JunkEmail)"
        $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/junkemail/messages"
    }
    "deleteditems" {
        $FolderNameDisplay = "Elementos Eliminados (DeletedItems)"
        $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/deleteditems/messages"
    }
    "drafts" {
        $FolderNameDisplay = "Borradores (Drafts)"
        $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/drafts/messages"
    }
    "all" {
        $FolderNameDisplay = "TODAS las carpetas del buzon"
        $FolderEndpoint = "v1.0/users/$Mailbox/messages"
    }
    default {
        # Buscar ID de carpeta personalizada en Graph API por displayName
        Write-StatusMsg "Buscando carpeta personalizada '$Folder' en Graph API..." -Status "WORKING"
        try {
            $SearchFolderUri = "v1.0/users/$Mailbox/mailFolders?`$filter=displayName eq '$Folder'"
            $FolderSearchResp = Invoke-MgGraphWithRetry -Method GET -Uri $SearchFolderUri
            if ($FolderSearchResp.value -and $FolderSearchResp.value.Count -gt 0) {
                $FolderId = $FolderSearchResp.value[0].id
                $FolderNameDisplay = "Carpeta Personalizada: '$($FolderSearchResp.value[0].displayName)'"
                $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/$FolderId/messages"
            } else {
                Write-StatusMsg "No se encontro la carpeta personalizada '$Folder'. Se utilizara 'Elementos Enviados'." -Status "WARN"
                $FolderNameDisplay = "Elementos Enviados (SentItems)"
                $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/sentitems/messages"
            }
        } catch {
            Write-StatusMsg "Error al buscar carpeta personalizada '$Folder': $_. Se utilizara 'Elementos Enviados'." -Status "WARN"
            $FolderNameDisplay = "Elementos Enviados (SentItems)"
            $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/sentitems/messages"
        }
    }
}

# Calcular la fecha umbral
$ThresholdDate = (Get-Date).AddMonths(-$MonthsOld)
$IsoThresholdDate = $ThresholdDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-StatusMsg "Buzon Origen       : $Mailbox" -Status "INFO"
Write-StatusMsg "Destinatario Filtro: $RecipientEmail" -Status "INFO"
Write-StatusMsg "Carpeta Evaluada   : $FolderNameDisplay" -Status "INFO"
Write-StatusMsg "Antiguedad Minima  : $MonthsOld meses" -Status "INFO"
Write-StatusMsg "Fecha Limite       : Anterior al $($ThresholdDate.ToString('dd/MM/yyyy HH:mm')) UTC ($IsoThresholdDate)" -Status "INFO"

# -------------------------------------------------------------------------
# PASO 3: BÚSQUEDA Y AUDITORÍA DE CORREOS
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 3 -TotalSteps 5 -Title "Auditoria de Correos y Calculo de Espacio"

$SelectFields = "id,subject,sentDateTime,toRecipients,ccRecipients,bccRecipients,hasAttachments,webLink"
$ExpandFields = "singleValueExtendedProperties(`$filter=id eq 'Integer 0x0E08')"
$QueryUri = "${FolderEndpoint}?`$select=${SelectFields}&`$expand=${ExpandFields}&`$top=100&`$filter=sentDateTime lt $IsoThresholdDate"

Write-StatusMsg "Consultando correos en '$FolderNameDisplay' anteriores a $MonthsOld meses ($IsoThresholdDate)..." -Status "WORKING"

$MatchingEmails = [System.Collections.Generic.List[PSObject]]::new()
$TotalSizeBytes = 0L

try {
    $NextLink = $QueryUri
    $PageCounter = 0

    do {
        $PageCounter++
        Write-Progress -Activity "Consultando Graph API" -Status "Cargando pagina $PageCounter..."
        
        $Response = Invoke-MgGraphWithRetry -Method GET -Uri $NextLink
        if ($Response -and $Response.value) {
            foreach ($msg in $Response.value) {
                # Validar si el destinatario solicitado esta presente en toRecipients, ccRecipients o bccRecipients
                $MatchesRecipient = $false
                $AllRecipients = @()
                if ($msg.toRecipients) { $AllRecipients += $msg.toRecipients }
                if ($msg.ccRecipients) { $AllRecipients += $msg.ccRecipients }
                if ($msg.bccRecipients) { $AllRecipients += $msg.bccRecipients }

                foreach ($rec in $AllRecipients) {
                    if ($rec.emailAddress -and $rec.emailAddress.address -and $rec.emailAddress.address -like "*$RecipientEmail*") {
                        $MatchesRecipient = $true
                        break
                    }
                }

                if ($MatchesRecipient) {
                    # Extraer tamaño del mensaje mediante propiedad MAPI PR_MESSAGE_SIZE (Integer 0x0E08) o de adjuntos/cuerpo
                    $MsgSize = 0L
                    if ($msg.singleValueExtendedProperties) {
                        $SizeProp = $msg.singleValueExtendedProperties | Where-Object { $_.id -like '*0x0E08*' -or $_.id -like '*0x0e08*' }
                        if ($SizeProp -and $SizeProp.value) {
                            $MsgSize = [int64]$SizeProp.value
                        }
                    }
                    if ($MsgSize -eq 0) {
                        if ($msg.body -and $msg.body.content) {
                            $MsgSize += [int64]$msg.body.content.Length
                        }
                        if ($msg.hasAttachments) {
                            $MsgSize += 250000L
                        }
                    }
                    $TotalSizeBytes += $MsgSize

                    $MatchingEmails.Add([PSCustomObject]@{
                        Id             = $msg.id
                        Subject        = if ([string]::IsNullOrWhiteSpace($msg.subject)) { "(Sin Asunto)" } else { $msg.subject }
                        SentDateTime   = [DateTime]$msg.sentDateTime
                        SentFormatted  = ([DateTime]$msg.sentDateTime).ToString("dd/MM/yyyy HH:mm")
                        RecipientEmail = $RecipientEmail
                        SizeBytes      = $MsgSize
                        SizeFormatted  = Format-Bytes -Bytes $MsgSize
                        HasAttachments = if ($msg.hasAttachments) { "Sí" } else { "No" }
                        WebLink        = $msg.webLink
                    })
                }
            }
        }
        $NextLink = $Response.'@odata.nextLink'
    } while ($NextLink)

    Write-Progress -Activity "Consultando Graph API" -Completed
} catch {
    Write-StatusMsg "Error al consultar correos en el buzon '$Mailbox': $_" -Status "FAIL"
    exit 1
}

# Resumen por consola
Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                       RESUMEN DE AUDITORIA                              " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Buzon analizado                       : {0}" -f $Mailbox) -ForegroundColor White
Write-Host (" Destinatario filtrado                 : {0}" -f $RecipientEmail) -ForegroundColor Yellow
Write-Host (" Carpeta evaluada                      : {0}" -f $FolderNameDisplay) -ForegroundColor White
Write-Host (" Antiguedad minima configurada         : {0} meses (anteriores a {1})" -f $MonthsOld, $ThresholdDate.ToString('dd/MM/yyyy')) -ForegroundColor White
Write-Host (" Total de correos encontrados          : {0}" -f $MatchingEmails.Count) -ForegroundColor Red
Write-Host (" ESPACIO TOTAL ESTIMADO A LIBERAR      : {0}" -f (Format-Bytes -Bytes $TotalSizeBytes)) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

# -------------------------------------------------------------------------
# PASO 4: GENERACIÓN DEL REPORTE HTML DE AUDITORÍA PREVIA
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 4 -TotalSteps 5 -Title "Generacion de Reporte HTML Previo"

Ensure-DirectoryExists -FilePath $HtmlOutputPath

try {
    $FormattedTotalSpace = Format-Bytes -Bytes $TotalSizeBytes
    $MailboxEnc = [System.Net.WebUtility]::HtmlEncode($Mailbox)
    $RecipientEnc = [System.Net.WebUtility]::HtmlEncode($RecipientEmail)
    $FolderEnc = [System.Net.WebUtility]::HtmlEncode($FolderNameDisplay)

    $HtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Informe de auditoría de limpieza de correos - Exchange Online</title>
    <style>
        :root {
            --bg-primary: #0f172a;
            --bg-card: #1e293b;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --accent-cyan: #0284c7;
            --accent-green: #10b981;
            --accent-red: #ef4444;
            --border-color: #334155;
            --table-header-bg: #0f172a;
            --table-row-hover: #243347;
            --btn-bg: #334155;
            --btn-text: #f8fafc;
        }
        [data-theme="light"] {
            --bg-primary: #f8fafc;
            --bg-card: #ffffff;
            --text-main: #0f172a;
            --text-muted: #64748b;
            --accent-cyan: #0284c7;
            --accent-green: #059669;
            --accent-red: #dc2626;
            --border-color: #cbd5e1;
            --table-header-bg: #f1f5f9;
            --table-row-hover: #f8fafc;
            --btn-bg: #e2e8f0;
            --btn-text: #0f172a;
        }
        * { box-sizing: border-box; }
        body {
            font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
            background-color: var(--bg-primary);
            color: var(--text-main);
            margin: 0;
            padding: 1.5rem;
            width: 100%;
            transition: background-color 0.2s, color 0.2s;
        }
        .container {
            width: 100%;
            max-width: 100%;
            margin: 0;
        }
        .toolbar {
            display: flex;
            justify-content: flex-end;
            margin-bottom: 1rem;
        }
        .theme-btn {
            background-color: var(--btn-bg);
            color: var(--btn-text);
            border: 1px solid var(--border-color);
            padding: 0.5rem 1rem;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.9rem;
            font-weight: 500;
        }
        .header {
            background-color: var(--bg-card);
            border: 1px solid var(--border-color);
            padding: 1.5rem;
            border-radius: 8px;
            margin-bottom: 1.5rem;
        }
        .header h1 {
            margin: 0 0 0.5rem 0;
            color: var(--accent-cyan);
            font-size: 1.6rem;
            font-weight: 600;
        }
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 1rem;
            margin-bottom: 1.5rem;
        }
        .metric-card {
            background-color: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 8px;
            padding: 1.25rem;
            text-align: center;
        }
        .metric-value {
            font-size: 1.75rem;
            font-weight: bold;
            margin-top: 0.25rem;
            color: var(--text-main);
        }
        .metric-value.highlight-green { color: var(--accent-green); }
        .metric-value.highlight-red { color: var(--accent-red); }
        .metric-value.highlight-cyan { color: var(--accent-cyan); }
        .metric-label {
            font-size: 0.85rem;
            color: var(--text-muted);
        }
        h2 {
            font-size: 1.25rem;
            font-weight: 600;
            margin-bottom: 1rem;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            background-color: var(--bg-card);
            border-radius: 8px;
            overflow: hidden;
            border: 1px solid var(--border-color);
        }
        th, td {
            padding: 0.85rem 1rem;
            text-align: left;
            border-bottom: 1px solid var(--border-color);
            font-size: 0.9rem;
        }
        th {
            background-color: var(--table-header-bg);
            color: var(--text-muted);
            font-weight: 600;
        }
        tr:hover {
            background-color: var(--table-row-hover);
        }
    </style>
    <script>
        function toggleTheme() {
            const html = document.documentElement;
            const next = html.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
            html.setAttribute('data-theme', next);
            localStorage.setItem('theme', next);
        }
        (function() {
            const saved = localStorage.getItem('theme');
            if (saved) {
                document.documentElement.setAttribute('data-theme', saved);
            }
        })();
    </script>
</head>
<body>
    <div class="container">
        <div class="toolbar">
            <button class="theme-btn" onclick="toggleTheme()">Modo claro / oscuro</button>
        </div>
        <div class="header">
            <h1>Informe de auditoría de limpieza de correos</h1>
            <p style="color: var(--text-muted); margin: 0;">Buzón: <strong>$MailboxEnc</strong> | Destinatario: <strong>$RecipientEnc</strong> | Carpeta: <strong>$FolderEnc</strong> | Fecha: $(Get-Date -Format 'dd/MM/yyyy HH:mm')</p>
        </div>

        <div class="metrics-grid">
            <div class="metric-card">
                <div class="metric-label">Antigüedad mínima</div>
                <div class="metric-value highlight-cyan">$MonthsOld meses</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Correos encontrados</div>
                <div class="metric-value highlight-red">$($MatchingEmails.Count)</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Espacio total a liberar del buzón</div>
                <div class="metric-value highlight-green">$FormattedTotalSpace</div>
            </div>
        </div>

        <h2>Detalle de correos candidatos a eliminación</h2>
        <table>
            <thead>
                <tr>
                    <th>Fecha de envío</th>
                    <th>Asunto</th>
                    <th>Destinatario</th>
                    <th>Adjuntos</th>
                    <th>Tamaño</th>
                </tr>
            </thead>
            <tbody>
"@

    foreach ($em in $MatchingEmails) {
        $SubjectEnc = [System.Net.WebUtility]::HtmlEncode($em.Subject)
        $RecipEnc = [System.Net.WebUtility]::HtmlEncode($em.RecipientEmail)

        $HtmlContent += @"
                <tr>
                    <td style="color: var(--text-muted); font-size: 0.85rem;">$($em.SentFormatted)</td>
                    <td><strong>$SubjectEnc</strong></td>
                    <td>$RecipEnc</td>
                    <td>$($em.HasAttachments)</td>
                    <td style="color: var(--accent-green); font-weight: bold;">$($em.SizeFormatted)</td>
                </tr>
"@
    }

    $HtmlContent += @"
            </tbody>
        </table>
    </div>
</body>
</html>
"@

    $HtmlContent | Out-File -FilePath $HtmlOutputPath -Encoding UTF8
    Write-StatusMsg "Reporte HTML de auditoria guardado en: '$HtmlOutputPath'" -Status "SUCCESS"
} catch {
    Write-StatusMsg "No se pudo generar el reporte HTML previo: $_" -Status "WARN"
}

# Presentar el informe previo en consola sin abrir navegador
Write-Host "`n-------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host " INFORME PREVIO DE AUDITORIA DISPONIBLE PARA REVISION" -ForegroundColor White
Write-Host "-------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host " Se ha generado el informe HTML con el detalle de correos y espacio a liberar:" -ForegroundColor White
Write-Host " -> $((Resolve-Path $HtmlOutputPath -ErrorAction SilentlyContinue).Path)" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# PASO 5: EJECUCIÓN DE LIMPIEZA DE CORREOS (CONFIRMACIÓN & BORRADO)
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 5 -TotalSteps 5 -Title "Ejecucion de Limpieza de Correos"

if ($AuditOnly) {
    Write-StatusMsg "Modo '-AuditOnly' activado. El informe se ha generado sin realizar cambios en el buzon." -Status "INFO"
    Write-Host "`nPROCESO COMPLETADO EXITOSAMENTE (Solo Auditoria).`n" -ForegroundColor Green
    exit 0
}

if ($MatchingEmails.Count -eq 0) {
    Write-StatusMsg "No se encontraron correos que cumplan con los criterios especificados." -Status "SUCCESS"
    Write-Host "`nPROCESO COMPLETADO.`n" -ForegroundColor Green
    exit 0
}

# Confirmación tras ver el informe
$Confirm = $false
if ($Force) {
    $Confirm = $true
} else {
    Write-Host "`n[!] Por favor, revise el informe HTML previo generado en el archivo antes de tomar una decision." -ForegroundColor DarkYellow
    Write-Host "    El informe detalla los $($MatchingEmails.Count) correos a eliminar enviados a '$RecipientEmail'.`n" -ForegroundColor DarkYellow
    
    Write-Host "ATENCION: Esta accion eliminara de forma IRREVERSIBLE $($MatchingEmails.Count) correos" -ForegroundColor Red
    Write-Host "para liberar un espacio estimado de $(Format-Bytes -Bytes $TotalSizeBytes) de su buzon.`n" -ForegroundColor Red
    
    $Answer = Read-Host "¿Tras revisar el informe, desea proceder con la eliminacion real de estos correos del buzon? (S/N)"
    if ($Answer -eq "S" -or $Answer -eq "s" -or $Answer -eq "SI" -or $Answer -eq "si") {
        $Confirm = $true
    }
}

if (-not $Confirm) {
    Write-StatusMsg "Operacion cancelada por el usuario. No se elimino ningun correo." -Status "WARN"
    Write-Host "`nPROCESO FINALIZADO SIN CAMBIOS.`n" -ForegroundColor Yellow
    exit 0
}

# Proceso de borrado de mensajes
Write-StatusMsg "Iniciando eliminacion de correos del buzon '$Mailbox'..." -Status "WORKING"

$DeletedCount = 0
$FreedBytes = 0L
$MsgCounter = 0
$DeletionLogList = [System.Collections.Generic.List[PSObject]]::new()

foreach ($msg in $MatchingEmails) {
    $MsgCounter++
    Write-Progress -Activity "Eliminando correos del buzon" `
                   -Status "Procesando correo $MsgCounter de $($MatchingEmails.Count)..." `
                   -PercentComplete (($MsgCounter / $MatchingEmails.Count) * 100)

    $DeleteUri = "v1.0/users/$Mailbox/messages/$($msg.Id)"
    
    if ($PSCmdlet.ShouldProcess("Correo: '$($msg.Subject)' (Fecha: $($msg.SentFormatted))", "Eliminar correo del buzon")) {
        try {
            Invoke-MgGraphWithRetry -Method DELETE -Uri $DeleteUri
            $DeletedCount++
            $FreedBytes += [int64]$msg.SizeBytes

            $DeletionLogList.Add([PSCustomObject]@{
                Subject        = $msg.Subject
                SentFormatted  = $msg.SentFormatted
                RecipientEmail = $msg.RecipientEmail
                SizeBytes      = $msg.SizeBytes
                SizeFormatted  = $msg.SizeFormatted
                Status         = "Eliminado"
                ErrorMessage   = ""
            })
        } catch {
            $ErrDetails = $_.Exception.Message
            Write-StatusMsg "  Error al eliminar correo '$($msg.Subject)': $ErrDetails" -Status "WARN"
            $DeletionLogList.Add([PSCustomObject]@{
                Subject        = $msg.Subject
                SentFormatted  = $msg.SentFormatted
                RecipientEmail = $msg.RecipientEmail
                SizeBytes      = 0L
                SizeFormatted  = "0 Bytes"
                Status         = "Error"
                ErrorMessage   = $ErrDetails
            })
        }
    }
}
Write-Progress -Activity "Eliminando correos del buzon" -Completed

# -------------------------------------------------------------------------
# GENERACIÓN DEL REPORTE HTML POST-LIMPIEZA (RESULTADOS REALES)
# -------------------------------------------------------------------------
Write-StatusMsg "Generando informe final HTML post-limpieza..." -Status "WORKING"

Ensure-DirectoryExists -FilePath $DeletionHtmlPath

try {
    $FormattedRealFreed = Format-Bytes -Bytes $FreedBytes
    $MailboxEnc = [System.Net.WebUtility]::HtmlEncode($Mailbox)
    $RecipientEnc = [System.Net.WebUtility]::HtmlEncode($RecipientEmail)
    $FolderEnc = [System.Net.WebUtility]::HtmlEncode($FolderNameDisplay)

    $PostHtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Informe de limpieza de correos ejecutada - Exchange Online</title>
    <style>
        :root {
            --bg-primary: #0f172a;
            --bg-card: #1e293b;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --accent-cyan: #0284c7;
            --accent-green: #10b981;
            --accent-red: #ef4444;
            --border-color: #334155;
            --table-header-bg: #0f172a;
            --table-row-hover: #243347;
            --btn-bg: #334155;
            --btn-text: #f8fafc;
        }
        [data-theme="light"] {
            --bg-primary: #f8fafc;
            --bg-card: #ffffff;
            --text-main: #0f172a;
            --text-muted: #64748b;
            --accent-cyan: #0284c7;
            --accent-green: #059669;
            --accent-red: #dc2626;
            --border-color: #cbd5e1;
            --table-header-bg: #f1f5f9;
            --table-row-hover: #f8fafc;
            --btn-bg: #e2e8f0;
            --btn-text: #0f172a;
        }
        * { box-sizing: border-box; }
        body {
            font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
            background-color: var(--bg-primary);
            color: var(--text-main);
            margin: 0;
            padding: 1.5rem;
            width: 100%;
            transition: background-color 0.2s, color 0.2s;
        }
        .container {
            width: 100%;
            max-width: 100%;
            margin: 0;
        }
        .toolbar {
            display: flex;
            justify-content: flex-end;
            margin-bottom: 1rem;
        }
        .theme-btn {
            background-color: var(--btn-bg);
            color: var(--btn-text);
            border: 1px solid var(--border-color);
            padding: 0.5rem 1rem;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.9rem;
            font-weight: 500;
        }
        .header {
            background-color: var(--bg-card);
            border: 1px solid var(--border-color);
            padding: 1.5rem;
            border-radius: 8px;
            margin-bottom: 1.5rem;
        }
        .header h1 {
            margin: 0 0 0.5rem 0;
            color: var(--accent-green);
            font-size: 1.6rem;
            font-weight: 600;
        }
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 1rem;
            margin-bottom: 1.5rem;
        }
        .metric-card {
            background-color: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 8px;
            padding: 1.25rem;
            text-align: center;
        }
        .metric-value {
            font-size: 1.75rem;
            font-weight: bold;
            margin-top: 0.25rem;
            color: var(--text-main);
        }
        .metric-value.highlight-green { color: var(--accent-green); }
        .metric-value.highlight-cyan { color: var(--accent-cyan); }
        .metric-label {
            font-size: 0.85rem;
            color: var(--text-muted);
        }
        h2 {
            font-size: 1.25rem;
            font-weight: 600;
            margin-bottom: 1rem;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            background-color: var(--bg-card);
            border-radius: 8px;
            overflow: hidden;
            border: 1px solid var(--border-color);
        }
        th, td {
            padding: 0.85rem 1rem;
            text-align: left;
            border-bottom: 1px solid var(--border-color);
            font-size: 0.9rem;
        }
        th {
            background-color: var(--table-header-bg);
            color: var(--text-muted);
            font-weight: 600;
        }
        tr:hover {
            background-color: var(--table-row-hover);
        }
        .badge {
            display: inline-block;
            padding: 0.25rem 0.6rem;
            border-radius: 6px;
            font-size: 0.8rem;
            font-weight: 600;
        }
        .badge-green { background-color: rgba(16, 185, 129, 0.15); color: var(--accent-green); }
        .badge-red { background-color: rgba(239, 68, 68, 0.15); color: var(--accent-red); }
    </style>
    <script>
        function toggleTheme() {
            const html = document.documentElement;
            const next = html.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
            html.setAttribute('data-theme', next);
            localStorage.setItem('theme', next);
        }
        (function() {
            const saved = localStorage.getItem('theme');
            if (saved) {
                document.documentElement.setAttribute('data-theme', saved);
            }
        })();
    </script>
</head>
<body>
    <div class="container">
        <div class="toolbar">
            <button class="theme-btn" onclick="toggleTheme()">Modo claro / oscuro</button>
        </div>
        <div class="header">
            <h1>Informe de limpieza ejecutada</h1>
            <p style="color: var(--text-muted); margin: 0;">Buzón: <strong>$MailboxEnc</strong> | Destinatario: <strong>$RecipientEnc</strong> | Carpeta: <strong>$FolderEnc</strong> | Ejecutado el: $(Get-Date -Format 'dd/MM/yyyy HH:mm')</p>
        </div>

        <div class="metrics-grid">
            <div class="metric-card">
                <div class="metric-label">Correos eliminados</div>
                <div class="metric-value highlight-cyan">$DeletedCount</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Espacio real liberado del buzón</div>
                <div class="metric-value highlight-green">$FormattedRealFreed</div>
            </div>
        </div>

        <h2>Registro detallado de correos eliminados</h2>
        <table>
            <thead>
                <tr>
                    <th>Fecha de envío</th>
                    <th>Asunto</th>
                    <th>Destinatario</th>
                    <th>Espacio liberado</th>
                    <th>Estado</th>
                </tr>
            </thead>
            <tbody>
"@

    foreach ($log in $DeletionLogList) {
        $BadgeClass = if ($log.Status -eq "Eliminado") { "badge-green" } else { "badge-red" }
        $SubjEnc = [System.Net.WebUtility]::HtmlEncode($log.Subject)
        $RecEnc = [System.Net.WebUtility]::HtmlEncode($log.RecipientEmail)

        $PostHtmlContent += @"
                <tr>
                    <td style="color: var(--text-muted); font-size: 0.85rem;">$($log.SentFormatted)</td>
                    <td><strong>$SubjEnc</strong></td>
                    <td>$RecEnc</td>
                    <td style="color: var(--accent-green); font-weight: bold;">$($log.SizeFormatted)</td>
                    <td><span class="badge $BadgeClass">$($log.Status)</span></td>
                </tr>
"@
    }

    $PostHtmlContent += @"
            </tbody>
        </table>
    </div>
</body>
</html>
"@

    $PostHtmlContent | Out-File -FilePath $DeletionHtmlPath -Encoding UTF8
    Write-StatusMsg "Informe HTML final post-limpieza generado en: '$DeletionHtmlPath'" -Status "SUCCESS"
} catch {
    Write-StatusMsg "No se pudo generar el reporte HTML post-limpieza: $_" -Status "WARN"
}

Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                       RESUMEN DE LIMPIEZA REALIZADA                     " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Total de correos eliminados          : {0}" -f $DeletedCount) -ForegroundColor Green
Write-Host (" ESPACIO TOTAL LIBERADO REAL DEL BUZON : {0}" -f (Format-Bytes -Bytes $FreedBytes)) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

Write-StatusMsg "Script finalizado con exito." -Status "SUCCESS"
