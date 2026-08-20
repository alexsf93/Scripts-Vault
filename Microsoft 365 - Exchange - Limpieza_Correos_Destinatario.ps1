<#
.SYNOPSIS
    Exchange online - Limpieza de correos por destinatario y antiguedad con Microsoft graph api (v1.4.0).

.DESCRIPTION
    Script de administracion para Exchange online que escanea un buzon de correo,
    busca mensajes enviados a un destinatario especifico con una antiguedad mayor a N meses (por defecto: 6),
    permite seleccionar la carpeta de origen (Elementos enviados, Bandeja de entrada, Correo no deseado, Elementos eliminados, Borradores, Todas u Otros),
    calcula la cantidad exacta de espacio en MB/GB que se liberara del buzon,
    genera reportes HTML previos y posteriores corporativos estilo Microsoft exchange admin center & fluent ui a pantalla completa sin margenes laterales,
    con resolucion automatica de rutas absolutas e instrucciones nativas de descarga para Azure Cloud Shell,
    solicita confirmacion y realiza la eliminacion segura de los correos.

.PARAMETER Mailbox
    Direccion de correo del buzon objetivo (UPN o email, ej: "cliente@dominio.com").

.PARAMETER RecipientEmail
    Direccion de correo del destinatario objetivo cuyos correos se desean eliminar (ej: "destinatario@empresa.com").

.PARAMETER MonthsOld
    Antiguedad minima en meses de los correos a evaluar (por defecto: 6).

.PARAMETER Folder
    Carpeta del buzon a consultar ('SentItems', 'Inbox', 'JunkEmail', 'DeletedItems', 'Drafts', 'All' o el nombre/ID de una carpeta personalizada).

.PARAMETER TenantId
    ID o dominio del tenant de Microsoft 365 (para autenticacion desatendida).

.PARAMETER ClientId
    ID de la aplicacion (App ID) de Entra id.

.PARAMETER ClientSecret
    Secreto de aplicacion (Client secret).

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
    Version:        1.4.0
    Fecha:          2026-08-11
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
    [string]$DeletionHtmlPath = ".\Reporte_Limpieza_Correos_Ejecutada.html",
    [int]$RequestDelayMs = 250
)

# Validar e instalar modulo requerido si no esta presente
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "  [*] Instalando modulo requerido 'Microsoft.Graph.Authentication' desde PowerShell gallery..." -ForegroundColor Yellow
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
    Write-Host " Paso ${StepNumber} de ${TotalSteps}: $Title" -ForegroundColor White
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

# Obtiene la fecha y hora convertida explícitamente a la zona horaria de España (Romance Standard Time / Europe/Madrid)
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
    if ($RequestDelayMs -gt 0) {
        Start-Sleep -Milliseconds $RequestDelayMs
    }
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
Write-Host "   Limpieza de correos por destinatario y antiguedad - Exchange online   " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Version: 1.3.0 | Graph API | Autor: Alejandro Suarez (@alexsf93)" -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------------------------------
# PASO 1: AUTENTICACION EN MICROSOFT GRAPH
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 1 -TotalSteps 5 -Title "Autenticacion en Microsoft graph"

$Scopes = @("Mail.ReadWrite", "Mail.Read", "User.Read.All")

try {
    if ($TenantId -and $ClientId -and $ClientSecret) {
        Write-StatusMsg "Conectando mediante app registration (Client secret)..." -Status "WORKING"
        $Body = @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "https://graph.microsoft.com/.default"
        }
        $TokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $Body
        Connect-MgGraph -AccessToken ($TokenResponse.access_token | ConvertTo-SecureString -AsPlainText -Force) -ErrorAction Stop
        Write-StatusMsg "Conexion establecida correctamente mediante app registration." -Status "SUCCESS"
    } else {
        $CurrentContext = Get-MgContext -ErrorAction SilentlyContinue
        if ($CurrentContext) {
            Write-StatusMsg "Sesion de Microsoft graph detectada ($($CurrentContext.Account))." -Status "SUCCESS"
        } else {
            Write-StatusMsg "Iniciando sesion con Microsoft graph..." -Status "WORKING"
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
    Write-StatusMsg "Error fatal al conectar a Microsoft graph: $_" -Status "FAIL"
    exit 1
}

# -------------------------------------------------------------------------
# PASO 2: SOLICITUD / VALIDACION DE PARAMETROS OBJETIVO Y SELECTOR DE CARPETAS
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 2 -TotalSteps 5 -Title "Configuracion de buzon y filtros"

if (-not $Mailbox) {
    $Mailbox = Read-Host "`nIngrese el buzon a limpiar (ej. cliente@empresa.com)"
}
if ([string]::IsNullOrWhiteSpace($Mailbox)) {
    Write-StatusMsg "Debe indicar un buzon de correo valido a limpiar." -Status "FAIL"
    exit 1
}

if (-not $RecipientEmail) {
    $RecipientEmail = Read-Host "`nIngrese el correo del destinatario filtro (se eliminaran los correos hacia este destinatario)"
}
if ([string]::IsNullOrWhiteSpace($RecipientEmail)) {
    Write-StatusMsg "Debe indicar un correo de destinatario filtro valido." -Status "FAIL"
    exit 1
}

if (-not $PSBoundParameters.ContainsKey("MonthsOld")) {
    $InputMonths = Read-Host "`nAntiguedad minima en meses de los correos a evaluar? (Por defecto: 6)"
    $ParsedMonths = 6
    if ([int]::TryParse($InputMonths, [ref]$ParsedMonths) -and $ParsedMonths -ge 1) {
        $MonthsOld = $ParsedMonths
    }
}

# Selector interactivo de carpetas de correo
if ([string]::IsNullOrWhiteSpace($Folder)) {
    Write-Host "`nCarpetas de correo disponibles para evaluar:" -ForegroundColor Yellow
    Write-Host " [ 1] Elementos enviados (SentItems) [Predeterminado]" -ForegroundColor Cyan
    Write-Host " [ 2] Bandeja de entrada (Inbox)" -ForegroundColor White
    Write-Host " [ 3] Correo no deseado / Spam (JunkEmail)" -ForegroundColor White
    Write-Host " [ 4] Elementos eliminados (DeletedItems)" -ForegroundColor White
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

# Resolver endpoint segun carpeta elegida
$FolderNameDisplay = ""
$FolderEndpoint = ""

switch -Wildcard ($Folder.ToLower()) {
    "sentitems" {
        $FolderNameDisplay = "Elementos enviados (SentItems)"
        $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/sentitems/messages"
    }
    "inbox" {
        $FolderNameDisplay = "Bandeja de entrada (Inbox)"
        $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/inbox/messages"
    }
    "junkemail" {
        $FolderNameDisplay = "Correo no deseado / Spam (JunkEmail)"
        $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/junkemail/messages"
    }
    "deleteditems" {
        $FolderNameDisplay = "Elementos eliminados (DeletedItems)"
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
                $FolderNameDisplay = "Carpeta personalizada: '$($FolderSearchResp.value[0].displayName)'"
                $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/$FolderId/messages"
            } else {
                Write-StatusMsg "No se encontro la carpeta personalizada '$Folder'. Se utilizara 'Elementos enviados'." -Status "WARN"
                $FolderNameDisplay = "Elementos enviados (SentItems)"
                $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/sentitems/messages"
            }
        } catch {
            Write-StatusMsg "Error al buscar carpeta personalizada '$Folder': $_. Se utilizara 'Elementos enviados'." -Status "WARN"
            $FolderNameDisplay = "Elementos enviados (SentItems)"
            $FolderEndpoint = "v1.0/users/$Mailbox/mailFolders/sentitems/messages"
        }
    }
}

# Calcular la fecha umbral
$ThresholdDate = (Get-SpainDateTime).AddMonths(-$MonthsOld)
$IsoThresholdDate = $ThresholdDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-StatusMsg "Buzon origen       : $Mailbox" -Status "INFO"
Write-StatusMsg "Destinatario filtro: $RecipientEmail" -Status "INFO"
Write-StatusMsg "Carpeta evaluada   : $FolderNameDisplay" -Status "INFO"
Write-StatusMsg "Antiguedad minima  : $MonthsOld meses" -Status "INFO"
Write-StatusMsg "Fecha limite       : Anterior al $($ThresholdDate.ToString('dd/MM/yyyy HH:mm')) (Hora España / $IsoThresholdDate UTC)" -Status "INFO"

# -------------------------------------------------------------------------
# PASO 3: BUSQUEDA Y AUDITORIA DE CORREOS
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 3 -TotalSteps 5 -Title "Auditoria de correos y calculo de espacio"

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
                        Subject        = if ([string]::IsNullOrWhiteSpace($msg.subject)) { "(Sin asunto)" } else { $msg.subject }
                        SentDateTime   = [DateTime]$msg.sentDateTime
                        SentFormatted  = (Get-SpainDateTime ([DateTime]$msg.sentDateTime)).ToString("dd/MM/yyyy HH:mm")
                        RecipientEmail = $RecipientEmail
                        SizeBytes      = $MsgSize
                        SizeFormatted  = Format-Bytes -Bytes $MsgSize
                        HasAttachments = if ($msg.hasAttachments) { "Si" } else { "No" }
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
Write-Host "                       Resumen de auditoria                              " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Buzon analizado                       : {0}" -f $Mailbox) -ForegroundColor White
Write-Host (" Destinatario filtrado                 : {0}" -f $RecipientEmail) -ForegroundColor Yellow
Write-Host (" Carpeta evaluada                      : {0}" -f $FolderNameDisplay) -ForegroundColor White
Write-Host (" Antiguedad minima configurada         : {0} meses (anteriores a {1})" -f $MonthsOld, $ThresholdDate.ToString('dd/MM/yyyy')) -ForegroundColor White
Write-Host (" Total de correos encontrados          : {0}" -f $MatchingEmails.Count) -ForegroundColor Red
Write-Host (" Espacio total estimado a liberar      : {0}" -f (Format-Bytes -Bytes $TotalSizeBytes)) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

# -------------------------------------------------------------------------
# PASO 4: GENERACION DEL REPORTE HTML DE AUDITORIA PREVIA
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 4 -TotalSteps 5 -Title "Generacion de reporte HTML previo"

Ensure-DirectoryExists -FilePath $HtmlOutputPath

try {
    $FormattedTotalSpace = Format-Bytes -Bytes $TotalSizeBytes
    $MailboxEnc = [System.Net.WebUtility]::HtmlEncode($Mailbox)
    $RecipientEnc = [System.Net.WebUtility]::HtmlEncode($RecipientEmail)
    $FolderEnc = [System.Net.WebUtility]::HtmlEncode($FolderNameDisplay)
    $DateNowStr = (Get-SpainDateTime).ToString("yyyy-MM-dd HH:mm:ss")

    $EmailRowsHtml = [System.Text.StringBuilder]::new()
    foreach ($em in $MatchingEmails) {
        $SubjectEnc = [System.Net.WebUtility]::HtmlEncode($em.Subject)
        $RecipEnc = [System.Net.WebUtility]::HtmlEncode($em.RecipientEmail)
        $AttachBadgeClass = if ($em.HasAttachments -eq "Si") { "badge-blue" } else { "badge-generic" }

        [void]$EmailRowsHtml.AppendLine("
        <tr>
            <td style=`"color: var(--text-secondary); font-size: 0.84rem;`">$($em.SentFormatted)</td>
            <td><strong>$SubjectEnc</strong></td>
            <td>$RecipEnc</td>
            <td><span class=`"badge $AttachBadgeClass`">$($em.HasAttachments)</span></td>
            <td style=`"color: var(--accent-green); font-weight: 600;`">$($em.SizeFormatted)</td>
        </tr>")
    }

    $HtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Informe de auditoria de limpieza de correos - Microsoft exchange online</title>
    <style>
        :root {
            /* Microsoft fluent ui design tokens - Exchange admin center light mode */
            --ex-brand: #0078d4;
            --ex-brand-hover: #106ebe;
            --ex-brand-dark: #005a9e;
            --m365-suite-bg: #005a9e;
            
            --bg-main: #faf9f8;
            --bg-card: #ffffff;
            --bg-header: #ffffff;
            --bg-table-header: #faf9f8;
            --bg-table-hover: #f3f2f1;
            --bg-input: #ffffff;
            
            --text-primary: #201f1e;
            --text-secondary: #605e5c;
            --text-heading: #11100f;
            --text-link: #0078d4;
            
            --border-color: #edebe9;
            --border-subtle: #e1dfdd;
            --accent-green: #107c41;
            --accent-red: #d13438;
            
            --shadow-card: 0 1.6px 3.6px 0 rgba(0,0,0,0.132), 0 0.3px 0.9px 0 rgba(0,0,0,0.108);
            
            --badge-generic-bg: #f3f2f1; --badge-generic-txt: #605e5c; --badge-generic-border: #e1dfdd;
            --badge-blue-bg: #deecf9; --badge-blue-txt: #005a9e; --badge-blue-border: #106ebe;
        }

        [data-theme="dark"] {
            /* Microsoft fluent ui dark mode */
            --ex-brand: #2899f5;
            --ex-brand-hover: #70baff;
            --ex-brand-dark: #0f172a;
            --m365-suite-bg: #0f172a;
            
            --bg-main: #11100f;
            --bg-card: #1b1a19;
            --bg-header: #1b1a19;
            --bg-table-header: #1b1a19;
            --bg-table-hover: #292827;
            --bg-input: #252423;
            
            --text-primary: #f3f2f1;
            --text-secondary: #a19f9d;
            --text-heading: #ffffff;
            --text-link: #2899f5;
            
            --border-color: #292827;
            --border-subtle: #323130;
            --accent-green: #4ade80;
            --accent-red: #f87171;
            
            --shadow-card: 0 2px 8px rgba(0, 0, 0, 0.4);
            
            --badge-generic-bg: rgba(161, 159, 157, 0.2); --badge-generic-txt: #d2d0ce; --badge-generic-border: rgba(161, 159, 157, 0.4);
            --badge-blue-bg: rgba(40, 153, 245, 0.2); --badge-blue-txt: #70baff; --badge-blue-border: rgba(40, 153, 245, 0.4);
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Roboto', 'Helvetica Neue', sans-serif;
            background-color: var(--bg-main);
            color: var(--text-primary);
            padding-bottom: 40px;
            line-height: 1.5;
            transition: background-color 0.2s ease, color 0.2s ease;
        }

        /* Top suite bar Microsoft 365 Exchange */
        .m365-suite-bar {
            background-color: var(--m365-suite-bg);
            color: #ffffff;
            height: 48px;
            padding: 0 24px;
            width: 100%;
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 0.9rem;
            box-shadow: 0 2px 4px rgba(0,0,0,0.14);
            margin-bottom: 24px;
        }
        .suite-left { display: flex; align-items: center; gap: 12px; }
        .waffle-icon { opacity: 0.95; cursor: default; }
        .ex-icon { display: flex; align-items: center; }
        .suite-title { font-weight: 700; font-size: 1.05rem; letter-spacing: 0.2px; }
        .suite-subtitle { opacity: 0.85; font-size: 0.88rem; font-weight: 400; }
        
        .suite-right { display: flex; align-items: center; gap: 18px; font-size: 0.82rem; }
        .suite-meta-item { display: flex; gap: 6px; }
        .meta-label { opacity: 0.75; }
        .meta-value { font-weight: 600; }

        .container { width: 100%; max-width: 100%; margin: 0; padding: 0 24px; }
        
        .page-header {
            margin-bottom: 20px;
            display: flex;
            justify-content: space-between;
            align-items: flex-end;
            flex-wrap: wrap;
            gap: 16px;
        }
        .page-header h1 {
            font-size: 1.5rem;
            font-weight: 600;
            color: var(--text-heading);
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .page-header p { color: var(--text-secondary); font-size: 0.9rem; margin-top: 2px; }

        .theme-toggle-btn {
            background: var(--bg-input);
            color: var(--text-primary);
            border: 1px solid var(--border-subtle);
            padding: 7px 14px;
            border-radius: 2px;
            font-size: 0.84rem;
            font-weight: 600;
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 6px;
            white-space: nowrap;
            transition: all 0.15s ease;
        }
        .theme-toggle-btn:hover { border-color: var(--ex-brand); color: var(--ex-brand); background: var(--bg-table-hover); }

        .ms-message-bar {
            background: var(--bg-card);
            border: 1px solid var(--border-subtle);
            border-left: 4px solid var(--ex-brand);
            border-radius: 4px;
            padding: 14px 18px;
            margin-bottom: 24px;
            font-size: 0.88rem;
            color: var(--text-primary);
            display: flex;
            align-items: center;
            gap: 12px;
            box-shadow: var(--shadow-card);
        }
        .ms-message-bar svg { color: var(--ex-brand); flex-shrink: 0; }

        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }
        .metric-card {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            padding: 16px 20px;
            box-shadow: var(--shadow-card);
            position: relative;
            overflow: hidden;
        }
        .metric-card::before {
            content: '';
            position: absolute;
            top: 0; left: 0;
            width: 4px; height: 100%;
            background-color: var(--ex-brand);
        }
        .metric-card.card-green::before { background-color: var(--accent-green); }
        .metric-card.card-red::before { background-color: var(--accent-red); }
        .metric-card.card-blue::before { background-color: var(--ex-brand); }

        .metric-card .title {
            font-size: 0.78rem;
            color: var(--text-secondary);
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .metric-card .value {
            font-size: 1.9rem;
            font-weight: 700;
            color: var(--text-heading);
            margin-top: 4px;
            line-height: 1.2;
        }
        .metric-card .subtext { font-size: 0.78rem; color: var(--text-secondary); margin-top: 4px; }

        .section-title {
            font-size: 1.15rem;
            font-weight: 600;
            color: var(--text-heading);
            margin-bottom: 14px;
            border-left: 4px solid var(--ex-brand);
            padding-left: 10px;
        }

        .table-card {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            overflow: hidden;
            box-shadow: var(--shadow-card);
            margin-bottom: 32px;
        }
        .table-container { overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; text-align: left; }
        th {
            background: var(--bg-table-header);
            padding: 10px 16px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
            color: var(--text-secondary);
            border-bottom: 1px solid var(--border-color);
            letter-spacing: 0.5px;
        }
        td {
            padding: 10px 16px;
            border-bottom: 1px solid var(--border-subtle);
            font-size: 0.85rem;
            vertical-align: middle;
            color: var(--text-primary);
        }
        tr:hover { background-color: var(--bg-table-hover); }

        .badge {
            display: inline-block;
            padding: 3px 10px;
            border-radius: 12px;
            font-size: 0.75rem;
            font-weight: 600;
        }
        .badge-generic { background: var(--badge-generic-bg); color: var(--badge-generic-txt); border: 1px solid var(--badge-generic-border); }
        .badge-blue { background: var(--badge-blue-bg); color: var(--badge-blue-txt); border: 1px solid var(--badge-blue-border); }

        .footer {
            margin-top: 40px;
            padding-top: 20px;
            border-top: 1px solid var(--border-color);
            text-align: center;
            font-size: 0.82rem;
            color: var(--text-secondary);
        }
        .footer-content { display: flex; align-items: center; justify-content: center; gap: 10px; flex-wrap: wrap; }
        .footer-separator { opacity: 0.4; }
    </style>
</head>
<body>
    <!-- Top suite bar Microsoft 365 Exchange -->
    <div class="m365-suite-bar">
        <div class="suite-left">
            <svg class="waffle-icon" viewBox="0 0 20 20" width="20" height="20" fill="currentColor">
                <circle cx="4" cy="4" r="1.8"/>
                <circle cx="10" cy="4" r="1.8"/>
                <circle cx="16" cy="4" r="1.8"/>
                <circle cx="4" cy="10" r="1.8"/>
                <circle cx="10" cy="10" r="1.8"/>
                <circle cx="16" cy="10" r="1.8"/>
                <circle cx="4" cy="16" r="1.8"/>
                <circle cx="10" cy="16" r="1.8"/>
                <circle cx="16" cy="16" r="1.8"/>
            </svg>
            <div class="ex-icon">
                <svg viewBox="0 0 24 24" width="22" height="22" fill="none">
                    <rect width="24" height="24" rx="4" fill="#0078D4"/>
                    <path d="M4 6.5L12 12.5L20 6.5V17.5C20 18.05 19.55 18.5 19 18.5H5C4.45 18.5 4 18.05 4 17.5V6.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M20 5.5H4C3.45 5.5 3 5.95 3 6.5V7L12 13.5L21 7V6.5C21 5.95 20.55 5.5 20 5.5Z" fill="white"/>
                </svg>
            </div>
            <span class="suite-title">Exchange</span>
            <span class="suite-subtitle">| Limpieza de correos</span>
        </div>
        <div class="suite-right">
            <div class="suite-meta-item">
                <span class="meta-label">Buzon:</span>
                <span class="meta-value">$MailboxEnc</span>
            </div>
            <div class="suite-meta-item">
                <span class="meta-label">Fecha:</span>
                <span class="meta-value">$DateNowStr</span>
            </div>
        </div>
    </div>

    <div class="container">
        <div class="page-header">
            <div>
                <h1>Informe de auditoria de limpieza de correos</h1>
                <p>Auditoria previa para el buzon <strong>$MailboxEnc</strong></p>
            </div>
            <button id="themeToggleBtn" class="theme-toggle-btn" onclick="toggleTheme()" title="Cambiar tema de color">
                <span id="themeIcon"><svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor"><path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z"/></svg></span> <span id="themeText">Modo oscuro</span>
            </button>
        </div>

        <div class="ms-message-bar">
            <svg width="20" height="20" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd"/>
            </svg>
            <div>
                <strong>Criterios de auditoria aplicados:</strong>
                <span>Destinatario objetivo: <b>$RecipientEnc</b> | Carpeta evaluada: <b>$FolderEnc</b> | Antiguedad minima: <b>$MonthsOld meses</b></span>
            </div>
        </div>

        <div class="metrics-grid">
            <div class="metric-card card-blue">
                <div class="title">Antiguedad minima</div>
                <div class="value">$MonthsOld meses</div>
                <div class="subtext">Filtro de evaluacion</div>
            </div>
            <div class="metric-card card-red">
                <div class="title">Correos encontrados</div>
                <div class="value">$($MatchingEmails.Count)</div>
                <div class="subtext">Candidatos a eliminacion</div>
            </div>
            <div class="metric-card card-green">
                <div class="title">Espacio total a liberar</div>
                <div class="value">$FormattedTotalSpace</div>
                <div class="subtext">Estimacion de espacio liberado</div>
            </div>
        </div>

        <div class="section-title">Detalle de correos candidatos a eliminacion</div>
        <div class="table-card">
            <div class="table-container">
                <table>
                    <thead>
                        <tr>
                            <th>Fecha de envio</th>
                            <th>Asunto</th>
                            <th>Destinatario</th>
                            <th>Adjuntos</th>
                            <th>Espacio estimado</th>
                        </tr>
                    </thead>
                    <tbody>
                        $($EmailRowsHtml.ToString())
                    </tbody>
                </table>
            </div>
        </div>

        <div class="footer">
            <div class="footer-content">
                <svg viewBox="0 0 24 24" width="16" height="16" fill="none">
                    <rect width="24" height="24" rx="4" fill="#0078D4"/>
                    <path d="M4 6.5L12 12.5L20 6.5V17.5C20 18.05 19.55 18.5 19 18.5H5C4.45 18.5 4 18.05 4 17.5V6.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M20 5.5H4C3.45 5.5 3 5.95 3 6.5V7L12 13.5L21 7V6.5C21 5.95 20.55 5.5 20 5.5Z" fill="white"/>
                </svg>
                <span>Microsoft 365 - Exchange online limpieza de correos</span>
                <span class="footer-separator">&bull;</span>
                <span>Autor: Alejandro Suarez (@alexsf93)</span>
            </div>
        </div>
    </div>

    <script>
        function toggleTheme() {
            var currentTheme = document.documentElement.getAttribute('data-theme') || 'light';
            var newTheme = currentTheme === 'dark' ? 'light' : 'dark';
            setTheme(newTheme);
        }

        function setTheme(theme) {
            document.documentElement.setAttribute('data-theme', theme);
            try { localStorage.setItem('exo_audit_theme', theme); } catch (e) {}
            var themeIcon = document.getElementById('themeIcon');
            var themeText = document.getElementById('themeText');
            var moonSvg = '<svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor"><path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z"/></svg>';
            var sunSvg = '<svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M10 2a1 1 0 011 1v1a1 1 0 11-2 0V3a1 1 0 011-1zm4 8a4 4 0 11-8 0 4 4 0 018 0zm-.464 4.95l.707.707a1 1 0 001.414-1.414l-.707-.707a1 1 0 00-1.414 1.414zm2.12-10.607a1 1 0 010 1.414l-.706.707a1 1 0 11-1.414-1.414l.707-.707a1 1 0 011.414 0zM17 11a1 1 0 100-2h-1a1 1 0 100 2h1zm-7 4a1 1 0 011 1v1a1 1 0 11-2 0v-1a1 1 0 011-1zM5.05 6.464A1 1 0 106.465 5.05l-.708-.707a1 1 0 00-1.414 1.414l.707.707zm1.414 8.486l-.707.707a1 1 0 01-1.414-1.414l.707-.707a1 1 0 011.414 1.414zM4 11a1 1 0 100-2H3a1 1 0 100 2h1z" clip-rule="evenodd"/></svg>';
            if (theme === 'dark') {
                if (themeIcon) themeIcon.innerHTML = sunSvg;
                if (themeText) themeText.textContent = 'Modo claro';
            } else {
                if (themeIcon) themeIcon.innerHTML = moonSvg;
                if (themeText) themeText.textContent = 'Modo oscuro';
            }
        }

        (function() {
            var savedTheme = 'light';
            try { savedTheme = localStorage.getItem('exo_audit_theme') || 'light'; } catch (e) {}
            setTheme(savedTheme);
        })();
    </script>
</body>
</html>
"@

    $resolvedHtmlPath = if ([System.IO.Path]::IsPathRooted($HtmlOutputPath)) { $HtmlOutputPath } else { [System.IO.Path]::Combine($PWD.Path, $HtmlOutputPath) }
    [System.IO.File]::WriteAllText($resolvedHtmlPath, $HtmlContent, [System.Text.Encoding]::UTF8)
    Write-StatusMsg "Reporte HTML de auditoria guardado en la ruta absoluta: '$resolvedHtmlPath'" -Status "SUCCESS"

    if ($env:ACC_CLOUD_SHELL -or $env:AZURE_HTTP_USER_AGENT -or ($PSVersionTable.Platform -eq 'Unix')) {
        Write-Host "  [i] Entorno Azure Cloud Shell / Linux detectado. Para descargar a tu equipo local:" -ForegroundColor Cyan
        Write-Host "      download `"$resolvedHtmlPath`"`n" -ForegroundColor Yellow
    }
} catch {
    Write-StatusMsg "No se pudo generar el reporte HTML previo: $_" -Status "WARN"
}

# Presentar el informe previo en consola sin abrir navegador
Write-Host "`n-------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host " Informe previo de auditoria disponible para revision" -ForegroundColor White
Write-Host "-------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host " Se ha generado el informe HTML con el detalle de correos y espacio a liberar:" -ForegroundColor White
Write-Host " -> $((Resolve-Path $HtmlOutputPath -ErrorAction SilentlyContinue).Path)" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# PASO 5: EJECUCION DE LIMPIEZA DE CORREOS (CONFIRMACION & BORRADO)
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 5 -TotalSteps 5 -Title "Ejecucion de limpieza de correos"

if ($AuditOnly) {
    Write-StatusMsg "Modo '-AuditOnly' activado. El informe se ha generado sin realizar cambios en el buzon." -Status "INFO"
    Write-Host "`nProceso completado exitosamente (solo auditoria).`n" -ForegroundColor Green
    exit 0
}

if ($MatchingEmails.Count -eq 0) {
    Write-StatusMsg "No se encontraron correos que cumplan con los criterios especificados." -Status "SUCCESS"
    Write-Host "`nProceso completado.`n" -ForegroundColor Green
    exit 0
}

# Confirmacion tras ver el informe
$Confirm = $false
if ($Force) {
    $Confirm = $true
} else {
    Write-Host "`n[!] Por favor, revise el informe HTML previo generado en el archivo antes de tomar una decision." -ForegroundColor DarkYellow
    Write-Host "    El informe detalla los $($MatchingEmails.Count) correos a eliminar enviados a '$RecipientEmail'.`n" -ForegroundColor DarkYellow
    
    Write-Host "Atencion: Esta accion eliminara de forma irreversible $($MatchingEmails.Count) correos" -ForegroundColor Red
    Write-Host "para liberar un espacio estimado de $(Format-Bytes -Bytes $TotalSizeBytes) de su buzon.`n" -ForegroundColor Red
    
    $Answer = Read-Host "Tras revisar el informe, desea proceder con la eliminacion real de estos correos del buzon? (S/N)"
    if ($Answer -eq "S" -or $Answer -eq "s" -or $Answer -eq "SI" -or $Answer -eq "si") {
        $Confirm = $true
    }
}

if (-not $Confirm) {
    Write-StatusMsg "Operacion cancelada por el usuario. No se elimino ningun correo." -Status "WARN"
    Write-Host "`nProceso finalizado sin cambios.`n" -ForegroundColor Yellow
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
# GENERACION DEL REPORTE HTML POST-LIMPIEZA (RESULTADOS REALES)
# -------------------------------------------------------------------------
Write-StatusMsg "Generando informe final HTML post-limpieza..." -Status "WORKING"

Ensure-DirectoryExists -FilePath $DeletionHtmlPath

try {
    $FormattedRealFreed = Format-Bytes -Bytes $FreedBytes
    $MailboxEnc = [System.Net.WebUtility]::HtmlEncode($Mailbox)
    $RecipientEnc = [System.Net.WebUtility]::HtmlEncode($RecipientEmail)
    $FolderEnc = [System.Net.WebUtility]::HtmlEncode($FolderNameDisplay)
    $DateNowStr = (Get-SpainDateTime).ToString("yyyy-MM-dd HH:mm:ss")

    $PostRowsHtml = [System.Text.StringBuilder]::new()
    foreach ($log in $DeletionLogList) {
        $BadgeClass = if ($log.Status -eq "Eliminado") { "badge-green" } else { "badge-red" }
        $SubjEnc = [System.Net.WebUtility]::HtmlEncode($log.Subject)
        $RecEnc = [System.Net.WebUtility]::HtmlEncode($log.RecipientEmail)

        [void]$PostRowsHtml.AppendLine("
        <tr>
            <td style=`"color: var(--text-secondary); font-size: 0.84rem;`">$($log.SentFormatted)</td>
            <td><strong>$SubjEnc</strong></td>
            <td>$RecEnc</td>
            <td style=`"color: var(--accent-green); font-weight: 600;`">$($log.SizeFormatted)</td>
            <td><span class=`"badge $BadgeClass`">$($log.Status)</span></td>
        </tr>")
    }

    $PostHtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Informe de limpieza ejecutada - Microsoft exchange online</title>
    <style>
        :root {
            /* Microsoft fluent ui design tokens - Exchange admin center light mode */
            --ex-brand: #0078d4;
            --ex-brand-hover: #106ebe;
            --ex-brand-dark: #005a9e;
            --m365-suite-bg: #005a9e;
            
            --bg-main: #faf9f8;
            --bg-card: #ffffff;
            --bg-header: #ffffff;
            --bg-table-header: #faf9f8;
            --bg-table-hover: #f3f2f1;
            --bg-input: #ffffff;
            
            --text-primary: #201f1e;
            --text-secondary: #605e5c;
            --text-heading: #11100f;
            --text-link: #0078d4;
            
            --border-color: #edebe9;
            --border-subtle: #e1dfdd;
            --accent-green: #107c41;
            --accent-red: #d13438;
            
            --shadow-card: 0 1.6px 3.6px 0 rgba(0,0,0,0.132), 0 0.3px 0.9px 0 rgba(0,0,0,0.108);
            
            --badge-green-bg: #dff6dd; --badge-green-txt: #107c41; --badge-green-border: #92e08f;
            --badge-red-bg: #fde8e8; --badge-red-txt: #a80000; --badge-red-border: #f8c2c2;
        }

        [data-theme="dark"] {
            /* Microsoft fluent ui dark mode */
            --ex-brand: #2899f5;
            --ex-brand-hover: #70baff;
            --ex-brand-dark: #0f172a;
            --m365-suite-bg: #0f172a;
            
            --bg-main: #11100f;
            --bg-card: #1b1a19;
            --bg-header: #1b1a19;
            --bg-table-header: #1b1a19;
            --bg-table-hover: #292827;
            --bg-input: #252423;
            
            --text-primary: #f3f2f1;
            --text-secondary: #a19f9d;
            --text-heading: #ffffff;
            --text-link: #2899f5;
            
            --border-color: #292827;
            --border-subtle: #323130;
            --accent-green: #4ade80;
            --accent-red: #f87171;
            
            --shadow-card: 0 2px 8px rgba(0, 0, 0, 0.4);
            
            --badge-green-bg: rgba(16, 124, 65, 0.25); --badge-green-txt: #4ade80; --badge-green-border: rgba(16, 124, 65, 0.5);
            --badge-red-bg: rgba(209, 52, 56, 0.25); --badge-red-txt: #f87171; --badge-red-border: rgba(209, 52, 56, 0.5);
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Roboto', 'Helvetica Neue', sans-serif;
            background-color: var(--bg-main);
            color: var(--text-primary);
            padding-bottom: 40px;
            line-height: 1.5;
            transition: background-color 0.2s ease, color 0.2s ease;
        }

        /* Top suite bar Microsoft 365 Exchange */
        .m365-suite-bar {
            background-color: var(--m365-suite-bg);
            color: #ffffff;
            height: 48px;
            padding: 0 24px;
            width: 100%;
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 0.9rem;
            box-shadow: 0 2px 4px rgba(0,0,0,0.14);
            margin-bottom: 24px;
        }
        .suite-left { display: flex; align-items: center; gap: 12px; }
        .waffle-icon { opacity: 0.95; cursor: default; }
        .ex-icon { display: flex; align-items: center; }
        .suite-title { font-weight: 700; font-size: 1.05rem; letter-spacing: 0.2px; }
        .suite-subtitle { opacity: 0.85; font-size: 0.88rem; font-weight: 400; }
        
        .suite-right { display: flex; align-items: center; gap: 18px; font-size: 0.82rem; }
        .suite-meta-item { display: flex; gap: 6px; }
        .meta-label { opacity: 0.75; }
        .meta-value { font-weight: 600; }

        .container { width: 100%; max-width: 100%; margin: 0; padding: 0 24px; }
        
        .page-header {
            margin-bottom: 20px;
            display: flex;
            justify-content: space-between;
            align-items: flex-end;
            flex-wrap: wrap;
            gap: 16px;
        }
        .page-header h1 {
            font-size: 1.5rem;
            font-weight: 600;
            color: var(--text-heading);
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .page-header p { color: var(--text-secondary); font-size: 0.9rem; margin-top: 2px; }

        .theme-toggle-btn {
            background: var(--bg-input);
            color: var(--text-primary);
            border: 1px solid var(--border-subtle);
            padding: 7px 14px;
            border-radius: 2px;
            font-size: 0.84rem;
            font-weight: 600;
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 6px;
            white-space: nowrap;
            transition: all 0.15s ease;
        }
        .theme-toggle-btn:hover { border-color: var(--ex-brand); color: var(--ex-brand); background: var(--bg-table-hover); }

        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }
        .metric-card {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            padding: 16px 20px;
            box-shadow: var(--shadow-card);
            position: relative;
            overflow: hidden;
        }
        .metric-card::before {
            content: '';
            position: absolute;
            top: 0; left: 0;
            width: 4px; height: 100%;
            background-color: var(--ex-brand);
        }
        .metric-card.card-green::before { background-color: var(--accent-green); }
        .metric-card.card-blue::before { background-color: var(--ex-brand); }

        .metric-card .title {
            font-size: 0.78rem;
            color: var(--text-secondary);
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .metric-card .value {
            font-size: 1.9rem;
            font-weight: 700;
            color: var(--text-heading);
            margin-top: 4px;
            line-height: 1.2;
        }
        .metric-card .subtext { font-size: 0.78rem; color: var(--text-secondary); margin-top: 4px; }

        .section-title {
            font-size: 1.15rem;
            font-weight: 600;
            color: var(--text-heading);
            margin-bottom: 14px;
            border-left: 4px solid var(--ex-brand);
            padding-left: 10px;
        }

        .table-card {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            overflow: hidden;
            box-shadow: var(--shadow-card);
            margin-bottom: 32px;
        }
        .table-container { overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; text-align: left; }
        th {
            background: var(--bg-table-header);
            padding: 10px 16px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
            color: var(--text-secondary);
            border-bottom: 1px solid var(--border-color);
            letter-spacing: 0.5px;
        }
        td {
            padding: 10px 16px;
            border-bottom: 1px solid var(--border-subtle);
            font-size: 0.85rem;
            vertical-align: middle;
            color: var(--text-primary);
        }
        tr:hover { background-color: var(--bg-table-hover); }

        .badge {
            display: inline-block;
            padding: 3px 10px;
            border-radius: 12px;
            font-size: 0.75rem;
            font-weight: 600;
        }
        .badge-green { background: var(--badge-green-bg); color: var(--badge-green-txt); border: 1px solid var(--badge-green-border); }
        .badge-red { background: var(--badge-red-bg); color: var(--badge-red-txt); border: 1px solid var(--badge-red-border); }

        .footer {
            margin-top: 40px;
            padding-top: 20px;
            border-top: 1px solid var(--border-color);
            text-align: center;
            font-size: 0.82rem;
            color: var(--text-secondary);
        }
        .footer-content { display: flex; align-items: center; justify-content: center; gap: 10px; flex-wrap: wrap; }
        .footer-separator { opacity: 0.4; }
    </style>
</head>
<body>
    <!-- Top suite bar Microsoft 365 Exchange -->
    <div class="m365-suite-bar">
        <div class="suite-left">
            <svg class="waffle-icon" viewBox="0 0 20 20" width="20" height="20" fill="currentColor">
                <circle cx="4" cy="4" r="1.8"/>
                <circle cx="10" cy="4" r="1.8"/>
                <circle cx="16" cy="4" r="1.8"/>
                <circle cx="4" cy="10" r="1.8"/>
                <circle cx="10" cy="10" r="1.8"/>
                <circle cx="16" cy="10" r="1.8"/>
                <circle cx="4" cy="16" r="1.8"/>
                <circle cx="10" cy="16" r="1.8"/>
                <circle cx="16" cy="16" r="1.8"/>
            </svg>
            <div class="ex-icon">
                <svg viewBox="0 0 24 24" width="22" height="22" fill="none">
                    <rect width="24" height="24" rx="4" fill="#0078D4"/>
                    <path d="M4 6.5L12 12.5L20 6.5V17.5C20 18.05 19.55 18.5 19 18.5H5C4.45 18.5 4 18.05 4 17.5V6.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M20 5.5H4C3.45 5.5 3 5.95 3 6.5V7L12 13.5L21 7V6.5C21 5.95 20.55 5.5 20 5.5Z" fill="white"/>
                </svg>
            </div>
            <span class="suite-title">Exchange</span>
            <span class="suite-subtitle">| Limpieza de correos</span>
        </div>
        <div class="suite-right">
            <div class="suite-meta-item">
                <span class="meta-label">Buzon:</span>
                <span class="meta-value">$MailboxEnc</span>
            </div>
            <div class="suite-meta-item">
                <span class="meta-label">Ejecutado el:</span>
                <span class="meta-value">$DateNowStr</span>
            </div>
        </div>
    </div>

    <div class="container">
        <div class="page-header">
            <div>
                <h1>Informe de limpieza ejecutada</h1>
                <p>Resultado final para el buzon <strong>$MailboxEnc</strong> | Destinatario: <strong>$RecipientEnc</strong> | Carpeta: <strong>$FolderEnc</strong></p>
            </div>
            <button id="themeToggleBtn" class="theme-toggle-btn" onclick="toggleTheme()" title="Cambiar tema de color">
                <span id="themeIcon"><svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor"><path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z"/></svg></span> <span id="themeText">Modo oscuro</span>
            </button>
        </div>

        <div class="metrics-grid">
            <div class="metric-card card-blue">
                <div class="title">Correos eliminados</div>
                <div class="value">$DeletedCount</div>
                <div class="subtext">Mensajes procesados</div>
            </div>
            <div class="metric-card card-green">
                <div class="title">Espacio real liberado del buzon</div>
                <div class="value">$FormattedRealFreed</div>
                <div class="subtext">Espacio recuperado</div>
            </div>
        </div>

        <div class="section-title">Registro detallado de correos eliminados</div>
        <div class="table-card">
            <div class="table-container">
                <table>
                    <thead>
                        <tr>
                            <th>Fecha de envio</th>
                            <th>Asunto</th>
                            <th>Destinatario</th>
                            <th>Espacio liberado</th>
                            <th>Estado</th>
                        </tr>
                    </thead>
                    <tbody>
                        $($PostRowsHtml.ToString())
                    </tbody>
                </table>
            </div>
        </div>

        <div class="footer">
            <div class="footer-content">
                <svg viewBox="0 0 24 24" width="16" height="16" fill="none">
                    <rect width="24" height="24" rx="4" fill="#0078D4"/>
                    <path d="M4 6.5L12 12.5L20 6.5V17.5C20 18.05 19.55 18.5 19 18.5H5C4.45 18.5 4 18.05 4 17.5V6.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M20 5.5H4C3.45 5.5 3 5.95 3 6.5V7L12 13.5L21 7V6.5C21 5.95 20.55 5.5 20 5.5Z" fill="white"/>
                </svg>
                <span>Microsoft 365 - Exchange online limpieza de correos</span>
                <span class="footer-separator">&bull;</span>
                <span>Autor: Alejandro Suarez (@alexsf93)</span>
            </div>
        </div>
    </div>

    <script>
        function toggleTheme() {
            var currentTheme = document.documentElement.getAttribute('data-theme') || 'light';
            var newTheme = currentTheme === 'dark' ? 'light' : 'dark';
            setTheme(newTheme);
        }

        function setTheme(theme) {
            document.documentElement.setAttribute('data-theme', theme);
            try { localStorage.setItem('exo_audit_theme', theme); } catch (e) {}
            var themeIcon = document.getElementById('themeIcon');
            var themeText = document.getElementById('themeText');
            var moonSvg = '<svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor"><path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z"/></svg>';
            var sunSvg = '<svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M10 2a1 1 0 011 1v1a1 1 0 11-2 0V3a1 1 0 011-1zm4 8a4 4 0 11-8 0 4 4 0 018 0zm-.464 4.95l.707.707a1 1 0 001.414-1.414l-.707-.707a1 1 0 00-1.414 1.414zm2.12-10.607a1 1 0 010 1.414l-.706.707a1 1 0 11-1.414-1.414l.707-.707a1 1 0 011.414 0zM17 11a1 1 0 100-2h-1a1 1 0 100 2h1zm-7 4a1 1 0 011 1v1a1 1 0 11-2 0v-1a1 1 0 011-1zM5.05 6.464A1 1 0 106.465 5.05l-.708-.707a1 1 0 00-1.414 1.414l.707.707zm1.414 8.486l-.707.707a1 1 0 01-1.414-1.414l.707-.707a1 1 0 011.414 1.414zM4 11a1 1 0 100-2H3a1 1 0 100 2h1z" clip-rule="evenodd"/></svg>';
            if (theme === 'dark') {
                if (themeIcon) themeIcon.innerHTML = sunSvg;
                if (themeText) themeText.textContent = 'Modo claro';
            } else {
                if (themeIcon) themeIcon.innerHTML = moonSvg;
                if (themeText) themeText.textContent = 'Modo oscuro';
            }
        }

        (function() {
            var savedTheme = 'light';
            try { savedTheme = localStorage.getItem('exo_audit_theme') || 'light'; } catch (e) {}
            setTheme(savedTheme);
        })();
    </script>
</body>
</html>
"@

    $resolvedDelPath = if ([System.IO.Path]::IsPathRooted($DeletionHtmlPath)) { $DeletionHtmlPath } else { [System.IO.Path]::Combine($PWD.Path, $DeletionHtmlPath) }
    [System.IO.File]::WriteAllText($resolvedDelPath, $PostHtmlContent, [System.Text.Encoding]::UTF8)
    Write-StatusMsg "Informe HTML final post-limpieza generado en la ruta absoluta: '$resolvedDelPath'" -Status "SUCCESS"

    if ($env:ACC_CLOUD_SHELL -or $env:AZURE_HTTP_USER_AGENT -or ($PSVersionTable.Platform -eq 'Unix')) {
        Write-Host "  [i] Entorno Azure Cloud Shell / Linux detectado. Para descargar a tu equipo local:" -ForegroundColor Cyan
        Write-Host "      download `"$resolvedDelPath`"`n" -ForegroundColor Yellow
    }
} catch {
    Write-StatusMsg "No se pudo generar el reporte HTML post-limpieza: $_" -Status "WARN"
}

Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                       Resumen de limpieza realizada                     " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Total de correos eliminados          : {0}" -f $DeletedCount) -ForegroundColor Green
Write-Host (" Espacio total liberado real del buzon : {0}" -f (Format-Bytes -Bytes $FreedBytes)) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

Write-StatusMsg "Script finalizado con exito." -Status "SUCCESS"
