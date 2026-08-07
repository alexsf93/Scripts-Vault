<#
.SYNOPSIS
    SharePoint Online - Auditoria y Limpieza del Historial de Versiones con Microsoft Graph API.

.DESCRIPTION
    Script de administracion para SharePoint Online que escanea bibliotecas de documentos,
    analiza el uso de espacio en disco por el historial de versiones de los archivos,
    calcula la cantidad exacta de espacio en MB/GB que se recuperara al conservar solo las N ultimas versiones
    (por defecto: 2) y permite realizar el borrado seguro e interactivo de las versiones obsoletas.

.PARAMETER TenantId
    ID o dominio del tenant de Microsoft 365 (para autenticacion desatendida).

.PARAMETER ClientId
    ID de la aplicacion (App ID) de Entra ID.

.PARAMETER ClientSecret
    Secreto de aplicacion (Client Secret).

.PARAMETER SiteUrl
    URL completa o fragmento del sitio de SharePoint a analizar (ej. "https://contoso.sharepoint.com/sites/Proyectos").

.PARAMETER SiteName
    Alias para -SiteUrl.

.PARAMETER LibraryName
    Nombre de una biblioteca especifica a auditar (ej. "Documentos"). Si se omite, permite seleccionar o auditar todas.

.PARAMETER KeepVersions
    Numero maximo de versiones recientes a conservar por cada archivo (por defecto: 2).

.PARAMETER AuditOnly
    Si se activa, el script solo realizara la auditoria y el calculo de ahorro sin solicitar ni borrar versiones.

.PARAMETER Force
    Omite la confirmacion interactiva antes de proceder con el borrado de versiones.

.PARAMETER HtmlOutputPath
    Ruta del reporte HTML interactivo visual de auditoria. Por defecto: ".\Reporte_Versiones_SharePoint.html"

.PARAMETER DeletionHtmlPath
    Ruta del reporte HTML interactivo visual post-limpieza. Por defecto: ".\Reporte_Limpieza_Ejecutada.html"

.EXAMPLE
    & '.\Microsoft 365 - SharePoint - Limpieza_Historial_Versiones.ps1'

.EXAMPLE
    & '.\Microsoft 365 - SharePoint - Limpieza_Historial_Versiones.ps1' -SiteUrl "Proyectos" -KeepVersions 2

.EXAMPLE
    & '.\Microsoft 365 - SharePoint - Limpieza_Historial_Versiones.ps1' -SiteUrl "https://contoso.sharepoint.com/sites/Proyectos" -KeepVersions 3 -AuditOnly

.NOTES
    Nombre:   Microsoft 365 - SharePoint - Limpieza_Historial_Versiones.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.1.0
    Fecha:    2026-08-07
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$TenantId = "",
    [string]$ClientId = "",
    [string]$ClientSecret = "",
    [string]$SiteUrl = "",
    [string]$SiteName = "",
    [string]$LibraryName = "",
    [int]$KeepVersions = 2,
    [switch]$AuditOnly,
    [switch]$Force,
    [string]$HtmlOutputPath = ".\Reporte_Versiones_SharePoint.html",
    [string]$DeletionHtmlPath = ".\Reporte_Limpieza_Ejecutada.html"
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
    } catch {
        # Si la ruta es relativa simple en el directorio actual, ignorar
    }
}

Clear-Host
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "   AUDITORIA Y LIMPIEZA DE HISTORIAL DE VERSIONES - SHAREPOINT ONLINE   " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Version: 1.1.0 | Graph API | Autor: Alejandro Suarez (@alexsf93)" -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------------------------------
# PASO 1: AUTENTICACIÓN EN MICROSOFT GRAPH
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 1 -TotalSteps 5 -Title "Autenticacion en Microsoft Graph"

$Scopes = @("Files.ReadWrite.All", "Sites.ReadWrite.All", "Sites.Read.All")

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
        # Verificar si existe una sesion Graph activa
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
# PASO 2: SELECCIÓN DEL SITIO Y BIBLIOTECA
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 2 -TotalSteps 5 -Title "Seleccion de Sitio y Biblioteca"

if (-not $SiteUrl -and $SiteName) {
    $SiteUrl = $SiteName
}

$TargetSite = $null

if ($SiteUrl) {
    Write-StatusMsg "Buscando sitio especifico: '$SiteUrl'..." -Status "WORKING"
    if ($SiteUrl -notlike "http*") {
        $SiteUrl = "https://$SiteUrl"
    }
    
    try {
        $Uri = [System.Uri]$SiteUrl
        $HostName = $Uri.Host
        $Path = $Uri.AbsolutePath
        $SiteGraphUri = "v1.0/sites/$HostName`:$Path"
        $TargetSite = Invoke-MgGraphWithRetry -Method GET -Uri $SiteGraphUri
    } catch {
        Write-StatusMsg "No se pudo obtener el sitio por URL directa. Buscando por termino..." -Status "WARN"
    }

    if (-not $TargetSite) {
        try {
            $SearchTerm = $SiteUrl.TrimEnd('/').Split('/')[-1]
            $SearchUri = "v1.0/sites?search=$SearchTerm"
            $SearchResults = Invoke-MgGraphWithRetry -Method GET -Uri $SearchUri
            if ($SearchResults.value -and $SearchResults.value.Count -gt 0) {
                $TargetSite = $SearchResults.value[0]
            }
        } catch {
            Write-StatusMsg "Error al buscar el sitio por termino: $_" -Status "WARN"
        }
    }
}

if (-not $TargetSite) {
    Write-StatusMsg "Obteniendo lista de sitios disponibles..." -Status "WORKING"
    try {
        $AllSites = (Invoke-MgGraphWithRetry -Method GET -Uri "v1.0/sites?search=*").value
    } catch {
        Write-StatusMsg "Error al obtener lista de sitios de SharePoint: $_" -Status "FAIL"
        exit 1
    }

    if (-not $AllSites -or $AllSites.Count -eq 0) {
        Write-StatusMsg "No se encontraron sitios de SharePoint en el tenant." -Status "FAIL"
        exit 1
    }
    
    Write-Host "`nSitios disponibles:" -ForegroundColor Yellow
    $MaxShow = [Math]::Min(20, $AllSites.Count)
    for ($i = 0; $i -lt $MaxShow; $i++) {
        Write-Host (" [{0,2}] {1} ({2})" -f ($i + 1), $AllSites[$i].displayName, $AllSites[$i].webUrl) -ForegroundColor White
    }
    
    $Selection = Read-Host "`nIngrese el numero del sitio objetivo (1-$MaxShow)"
    $ParsedIndex = 0
    if ([int]::TryParse($Selection, [ref]$ParsedIndex)) {
        $Index = $ParsedIndex - 1
        if ($Index -ge 0 -and $Index -lt $AllSites.Count) {
            $TargetSite = $AllSites[$Index]
        }
    }
    
    if (-not $TargetSite) {
        Write-StatusMsg "Seleccion invalida de sitio." -Status "FAIL"
        exit 1
    }
}

Write-StatusMsg "Sitio seleccionado: $($TargetSite.displayName) ($($TargetSite.webUrl))" -Status "SUCCESS"
$SiteId = $TargetSite.id

# Obtener bibliotecas de documentos (Drives) del sitio con paginación
Write-StatusMsg "Cargando bibliotecas de documentos del sitio..." -Status "WORKING"
$Drives = @()
$DrivesUri = "v1.0/sites/$SiteId/drives"
try {
    do {
        $Response = Invoke-MgGraphWithRetry -Method GET -Uri $DrivesUri
        $Drives += $Response.value
        $DrivesUri = $Response.'@odata.nextLink'
    } while ($DrivesUri)
} catch {
    Write-StatusMsg "Error al consultar bibliotecas del sitio: $_" -Status "FAIL"
    exit 1
}

$DocDrives = $Drives | Where-Object { $_.driveType -eq "documentLibrary" -and $_.name -ne "Form Templates" -and $_.name -ne "Style Library" }

if (-not $DocDrives -or $DocDrives.Count -eq 0) {
    Write-StatusMsg "No se encontraron bibliotecas de documentos en este sitio." -Status "FAIL"
    exit 1
}

$SelectedDrives = @()

if ($LibraryName) {
    $Matched = $DocDrives | Where-Object { $_.name -like "*$LibraryName*" }
    if ($Matched) {
        $SelectedDrives = $Matched
    } else {
        Write-StatusMsg "No se encontro la biblioteca '$LibraryName'. Se utilizaran todas las bibliotecas." -Status "WARN"
        $SelectedDrives = $DocDrives
    }
} else {
    Write-Host "`nBibliotecas de documentos encontradas:" -ForegroundColor Yellow
    Write-Host " [ 0] TODAS las bibliotecas del sitio" -ForegroundColor Cyan
    for ($i = 0; $i -lt $DocDrives.Count; $i++) {
        Write-Host (" [{0,2}] {1}" -f ($i + 1), $DocDrives[$i].name) -ForegroundColor White
    }
    
    $LibChoice = Read-Host "`nSeleccione la biblioteca a auditar (0 para TODAS)"
    $ParsedLibChoice = 0
    if ($LibChoice -eq "0" -or [string]::IsNullOrWhiteSpace($LibChoice)) {
        $SelectedDrives = $DocDrives
    } elseif ([int]::TryParse($LibChoice, [ref]$ParsedLibChoice)) {
        $LibIdx = $ParsedLibChoice - 1
        if ($LibIdx -ge 0 -and $LibIdx -lt $DocDrives.Count) {
            $SelectedDrives = @($DocDrives[$LibIdx])
        } else {
            Write-StatusMsg "Seleccion invalida. Procesando todas las bibliotecas." -Status "WARN"
            $SelectedDrives = $DocDrives
        }
    } else {
        Write-StatusMsg "Opcion no numerica. Procesando todas las bibliotecas." -Status "WARN"
        $SelectedDrives = $DocDrives
    }
}

# Consultar / solicitar el umbral de versiones si no se ha especificado explícitamente por CLI
if (-not $PSBoundParameters.ContainsKey("KeepVersions")) {
    $InputVersions = Read-Host "`n¿Cuantas versiones mas recientes desea CONSERVAR por archivo? (Por defecto: 2)"
    $ParsedVers = 2
    if ([int]::TryParse($InputVersions, [ref]$ParsedVers) -and $ParsedVers -ge 1) {
        $KeepVersions = $ParsedVers
    } else {
        $KeepVersions = 2
    }
}

Write-StatusMsg "Umbral configurado: Se conservaran las $KeepVersions versiones mas recientes por archivo." -Status "INFO"

# -------------------------------------------------------------------------
# PASO 3: AUDITORÍA Y CÁLCULO DE ESPACIO A RECUPERAR
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 3 -TotalSteps 5 -Title "Auditoria de Archivos y Calculo de Ahorro"

$AuditResults = [System.Collections.Generic.List[PSObject]]::new()
$GlobalStats = @{
    TotalFilesScanned     = 0
    FilesWithExtraVersions= 0
    TotalVersionsFound    = 0
    VersionsToDelete      = 0
    TotalSpaceBytes       = 0L
    RedundantSpaceBytes   = 0L
}

# Función recursiva robusta para escanear elementos de carpetas en SharePoint
function Get-DriveItemsRecursive {
    param(
        [string]$SiteId,
        [string]$DriveId,
        [string]$FolderId = "root",
        [string]$CurrentPath = ""
    )

    $ResultList = [System.Collections.Generic.List[PSObject]]::new()
    $ItemsUri = if ($FolderId -eq "root") {
        "v1.0/sites/$SiteId/drives/$DriveId/root/children?`$top=200"
    } else {
        "v1.0/sites/$SiteId/drives/$DriveId/items/$FolderId/children?`$top=200"
    }

    $Items = @()
    try {
        do {
            $Response = Invoke-MgGraphWithRetry -Method GET -Uri $ItemsUri
            if ($Response -and $Response.value) {
                $Items += $Response.value
            }
            $ItemsUri = $Response.'@odata.nextLink'
        } while ($ItemsUri)
    } catch {
        Write-StatusMsg "  Error al explorar carpeta '$CurrentPath': $_" -Status "WARN"
        return $ResultList
    }

    foreach ($item in $Items) {
        $ItemPath = "$CurrentPath/$($item.name)"
        if ($item.folder) {
            $SubItems = Get-DriveItemsRecursive -SiteId $SiteId -DriveId $DriveId -FolderId $item.id -CurrentPath $ItemPath
            $ResultList.AddRange($SubItems)
        } elseif ($item.file) {
            $ResultList.Add([PSCustomObject]@{
                Id          = $item.id
                Name        = $item.name
                Path        = $ItemPath
                Size        = if ($item.size) { [int64]$item.size } else { 0L }
                DriveId     = $DriveId
                WebUrl      = $item.webUrl
            })
        }
    }
    return $ResultList
}

foreach ($drive in $SelectedDrives) {
    Write-StatusMsg "Escaneando biblioteca: '$($drive.name)'..." -Status "WORKING"
    
    $Files = Get-DriveItemsRecursive -SiteId $SiteId -DriveId $drive.id -CurrentPath "$($drive.name)"
    Write-StatusMsg "  Archivos encontrados en '$($drive.name)': $($Files.Count)" -Status "INFO"

    $FileCounter = 0
    foreach ($file in $Files) {
        $FileCounter++
        $GlobalStats.TotalFilesScanned++

        Write-Progress -Activity "Auditando historial de versiones" `
                       -Status "Procesando $($file.Name)" `
                       -PercentComplete (($FileCounter / [Math]::Max(1, $Files.Count)) * 100)

        # Consultar versiones del archivo con reintentos
        $VersionsUri = "v1.0/sites/$SiteId/drives/$($file.DriveId)/items/$($file.Id)/versions"
        try {
            $VersResponse = Invoke-MgGraphWithRetry -Method GET -Uri $VersionsUri
            $Versions = $VersResponse.value
        } catch {
            $Versions = @()
        }

        $TotalVersCount = if ($Versions) { $Versions.Count } else { 1 }
        $GlobalStats.TotalVersionsFound += $TotalVersCount

        if ($TotalVersCount -gt $KeepVersions) {
            # Ordenar versiones por fecha de modificacion descendente (mas reciente primero)
            $SortedVersions = $Versions | Sort-Object { [DateTime]$_.lastModifiedDateTime } -Descending
            
            # Las primeras $KeepVersions se mantienen, el resto son candidatas a eliminacion
            $VersionsToKeepList = $SortedVersions | Select-Object -First $KeepVersions
            $VersionsToDeleteList = $SortedVersions | Select-Object -Skip $KeepVersions

            $RedundantBytesForFile = 0L
            foreach ($vToDelete in $VersionsToDeleteList) {
                if ($vToDelete.size) {
                    $RedundantBytesForFile += [int64]$vToDelete.size
                }
            }

            $GlobalStats.FilesWithExtraVersions++
            $GlobalStats.VersionsToDelete += $VersionsToDeleteList.Count
            $GlobalStats.RedundantSpaceBytes += $RedundantBytesForFile
            $GlobalStats.TotalSpaceBytes += [int64]$file.Size + $RedundantBytesForFile

            $AuditResults.Add([PSCustomObject]@{
                LibraryName           = $drive.name
                FileName              = $file.Name
                Path                  = $file.Path
                CurrentFileSize       = Format-Bytes -Bytes $file.Size
                TotalVersions         = $TotalVersCount
                VersionsToKeep        = $KeepVersions
                VersionsToDelete      = $VersionsToDeleteList.Count
                RecoverableSpaceBytes = $RedundantBytesForFile
                RecoverableSpace      = Format-Bytes -Bytes $RedundantBytesForFile
                FileId                = $file.Id
                DriveId               = $file.DriveId
                VersionsToDeleteObj   = $VersionsToDeleteList
                WebUrl                = $file.WebUrl
            })
        } else {
            $GlobalStats.TotalSpaceBytes += [int64]$file.Size
        }
    }
}
Write-Progress -Activity "Auditando historial de versiones" -Completed

# Presentar informe consolidado de auditoría por consola
Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                       RESUMEN DE AUDITORIA                              " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Total de archivos analizados          : {0}" -f $GlobalStats.TotalFilesScanned) -ForegroundColor White
Write-Host (" Archivos con versiones excedentes     : {0}" -f $GlobalStats.FilesWithExtraVersions) -ForegroundColor Yellow
Write-Host (" Total de versiones encontradas        : {0}" -f $GlobalStats.TotalVersionsFound) -ForegroundColor White
Write-Host (" Total de versiones a eliminar         : {0}" -f $GlobalStats.VersionsToDelete) -ForegroundColor Red
Write-Host (" Umbral de versiones a conservar       : {0}" -f $KeepVersions) -ForegroundColor Cyan
Write-Host (" Espacio total estimado a RECUPERAR    : {0}" -f (Format-Bytes -Bytes $GlobalStats.RedundantSpaceBytes)) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

# -------------------------------------------------------------------------
# PASO 4: GENERACIÓN DE REPORTE HTML DE AUDITORÍA
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 4 -TotalSteps 5 -Title "Generacion de Reporte HTML"

Ensure-DirectoryExists -FilePath $HtmlOutputPath

try {
    $FormattedSavings = Format-Bytes -Bytes $GlobalStats.RedundantSpaceBytes
    $SiteNameEncoded = [System.Net.WebUtility]::HtmlEncode($TargetSite.displayName)
    
    $HtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Informe de auditoría de versiones - SharePoint Online</title>
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
            <h1>Informe de auditoría de historial de versiones</h1>
            <p style="color: var(--text-muted); margin: 0;">Sitio: <strong>$SiteNameEncoded</strong> | Fecha: $(Get-Date -Format 'dd/MM/yyyy HH:mm')</p>
        </div>

        <div class="metrics-grid">
            <div class="metric-card">
                <div class="metric-label">Archivos analizados</div>
                <div class="metric-value">$($GlobalStats.TotalFilesScanned)</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Archivos con excedente</div>
                <div class="metric-value highlight-cyan">$($GlobalStats.FilesWithExtraVersions)</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Versiones a eliminar</div>
                <div class="metric-value highlight-red">$($GlobalStats.VersionsToDelete)</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Espacio recuperable</div>
                <div class="metric-value highlight-green">$FormattedSavings</div>
            </div>
        </div>

        <h2>Detalle de archivos con historial excedente</h2>
        <table>
            <thead>
                <tr>
                    <th>Biblioteca</th>
                    <th>Archivo</th>
                    <th>Ruta</th>
                    <th>Versiones totales</th>
                    <th>A conservar</th>
                    <th>A eliminar</th>
                    <th>Espacio liberable</th>
                </tr>
            </thead>
            <tbody>
"@

    foreach ($item in $AuditResults) {
        $LibNameEnc = [System.Net.WebUtility]::HtmlEncode($item.LibraryName)
        $FileNameEnc = [System.Net.WebUtility]::HtmlEncode($item.FileName)
        $PathEnc = [System.Net.WebUtility]::HtmlEncode($item.Path)
        
        $HtmlContent += @"
                <tr>
                    <td>$LibNameEnc</td>
                    <td><strong>$FileNameEnc</strong></td>
                    <td style="color: var(--text-muted); font-size: 0.85rem;">$PathEnc</td>
                    <td>$($item.TotalVersions)</td>
                    <td>$($item.VersionsToKeep)</td>
                    <td style="color: var(--accent-red); font-weight: bold;">$($item.VersionsToDelete)</td>
                    <td style="color: var(--accent-green); font-weight: bold;">$($item.RedundantSpaceFormatted)</td>
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
    Write-StatusMsg "Reporte HTML guardado correctamente en: '$HtmlOutputPath'" -Status "SUCCESS"
} catch {
    Write-StatusMsg "No se pudo generar el reporte HTML de auditoria: $_" -Status "WARN"
}

# Presentar el informe en consola sin abrir navegador
Write-Host "`n-------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host " INFORME DE AUDITORIA DISPONIBLE PARA REVISION" -ForegroundColor White
Write-Host "-------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host " Se ha generado el informe HTML interactivo en:" -ForegroundColor White
Write-Host " -> $((Resolve-Path $HtmlOutputPath -ErrorAction SilentlyContinue).Path)" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# PASO 5: EJECUCIÓN DE LIMPIEZA DE VERSIONES (CONFIRMACIÓN & BORRADO)
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 5 -TotalSteps 5 -Title "Ejecucion de Limpieza de Versiones"

if ($AuditOnly) {
    Write-StatusMsg "Modo '-AuditOnly' activado. El informe se ha generado sin realizar cambios en SharePoint." -Status "INFO"
    Write-Host "`nPROCESO COMPLETADO EXITOSAMENTE (Solo Auditoria).`n" -ForegroundColor Green
    exit 0
}

if ($GlobalStats.VersionsToDelete -eq 0) {
    Write-StatusMsg "No hay versiones obsoletas que eliminar segun el umbral especificado ($KeepVersions)." -Status "SUCCESS"
    Write-Host "`nPROCESO COMPLETADO.`n" -ForegroundColor Green
    exit 0
}

# Confirmación tras ver el informe
$Confirm = $false
if ($Force) {
    $Confirm = $true
} else {
    Write-Host "`n[!] Por favor, revise el informe HTML generado antes de tomar una decision." -ForegroundColor DarkYellow
    Write-Host "    El informe incluye la lista de $($GlobalStats.FilesWithExtraVersions) archivos afectados y sus $($GlobalStats.VersionsToDelete) versiones candidatas a borrado.`n" -ForegroundColor DarkYellow
    
    Write-Host "ATENCION: Esta accion eliminara de forma IRREVERSIBLE $($GlobalStats.VersionsToDelete) versiones de archivos" -ForegroundColor Red
    Write-Host "para liberar un total estimado de $(Format-Bytes -Bytes $GlobalStats.RedundantSpaceBytes) de almacenamiento.`n" -ForegroundColor Red
    
    $Answer = Read-Host "¿Tras revisar el informe, desea proceder con la eliminacion real de estas versiones? (S/N)"
    if ($Answer -eq "S" -or $Answer -eq "s" -or $Answer -eq "SI" -or $Answer -eq "si") {
        $Confirm = $true
    }
}

if (-not $Confirm) {
    Write-StatusMsg "Operacion cancelada por el usuario. No se elimino ninguna version." -Status "WARN"
    Write-Host "`nPROCESO FINALIZADO SIN CAMBIOS.`n" -ForegroundColor Yellow
    exit 0
}

# Proceso de borrado
Write-StatusMsg "Iniciando borrado de versiones obsoletas con tolerancia a fallos..." -Status "WORKING"

$DeletedCount = 0
$FreedBytes = 0L
$ItemCounter = 0
$DeletionLogList = [System.Collections.Generic.List[PSObject]]::new()
$CleanedFilesSet = [System.Collections.Generic.HashSet[string]]::new()

foreach ($res in $AuditResults) {
    $ItemCounter++
    Write-Progress -Activity "Eliminando versiones obsoletas" `
                   -Status "Archivo: $($res.FileName)" `
                   -PercentComplete (($ItemCounter / $AuditResults.Count) * 100)

    foreach ($v in $res.VersionsToDeleteObj) {
        $DeleteUri = "v1.0/sites/$SiteId/drives/$($res.DriveId)/items/$($res.FileId)/versions/$($v.id)"
        
        if ($PSCmdlet.ShouldProcess("Archivo '$($res.FileName)' - Version '$($v.id)'", "Eliminar version de SharePoint")) {
            try {
                Invoke-MgGraphWithRetry -Method DELETE -Uri $DeleteUri
                $DeletedCount++
                $VSize = if ($v.size) { [int64]$v.size } else { 0L }
                $FreedBytes += $VSize

                $DeletionLogList.Add([PSCustomObject]@{
                    LibraryName      = $res.LibraryName
                    FileName         = $res.FileName
                    Path             = $res.Path
                    VersionId        = $v.id
                    VersionModified  = $v.lastModifiedDateTime
                    FreedBytes       = $VSize
                    FreedFormatted   = Format-Bytes -Bytes $VSize
                    Status           = "Éxito"
                    ErrorMessage     = ""
                })
                $CleanedFilesSet.Add($res.FileId) | Out-Null
            } catch {
                $ErrDetails = $_.Exception.Message
                Write-StatusMsg "  No se pudo eliminar version $($v.id) de '$($res.FileName)': $ErrDetails" -Status "WARN"
                $DeletionLogList.Add([PSCustomObject]@{
                    LibraryName      = $res.LibraryName
                    FileName         = $res.FileName
                    Path             = $res.Path
                    VersionId        = $v.id
                    VersionModified  = $v.lastModifiedDateTime
                    FreedBytes       = 0L
                    FreedFormatted   = "0 Bytes"
                    Status           = "Error"
                    ErrorMessage     = $ErrDetails
                })
            }
        }
    }
}
Write-Progress -Activity "Eliminando versiones obsoletas" -Completed

# -------------------------------------------------------------------------
# GENERACIÓN DEL INFORME HTML POST-LIMPIEZA (RESULTADOS REALES)
# -------------------------------------------------------------------------
Write-StatusMsg "Generando informe final HTML post-limpieza con los resultados..." -Status "WORKING"

Ensure-DirectoryExists -FilePath $DeletionHtmlPath

try {
    $FormattedRealFreed = Format-Bytes -Bytes $FreedBytes
    $SiteNameEncoded = [System.Net.WebUtility]::HtmlEncode($TargetSite.displayName)
    
    $PostHtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Informe de limpieza ejecutada - SharePoint Online</title>
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
            <p style="color: var(--text-muted); margin: 0;">Sitio: <strong>$SiteNameEncoded</strong> | Ejecutado el: $(Get-Date -Format 'dd/MM/yyyy HH:mm')</p>
        </div>

        <div class="metrics-grid">
            <div class="metric-card">
                <div class="metric-label">Archivos limpiados</div>
                <div class="metric-value highlight-cyan">$($CleanedFilesSet.Count)</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Versiones eliminadas</div>
                <div class="metric-value highlight-green">$DeletedCount</div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Espacio liberado real</div>
                <div class="metric-value highlight-green">$FormattedRealFreed</div>
            </div>
        </div>

        <h2>Registro detallado de versiones eliminadas</h2>
        <table>
            <thead>
                <tr>
                    <th>Biblioteca</th>
                    <th>Archivo</th>
                    <th>ID de versión</th>
                    <th>Fecha de modificación</th>
                    <th>Espacio liberado</th>
                    <th>Estado</th>
                </tr>
            </thead>
            <tbody>
"@

    foreach ($log in $DeletionLogList) {
        $BadgeClass = if ($log.Status -eq "Éxito") { "badge-green" } else { "badge-red" }
        $LibEnc = [System.Net.WebUtility]::HtmlEncode($log.LibraryName)
        $FileEnc = [System.Net.WebUtility]::HtmlEncode($log.FileName)
        $VersIdEnc = [System.Net.WebUtility]::HtmlEncode($log.VersionId)
        
        $PostHtmlContent += @"
                <tr>
                    <td>$LibEnc</td>
                    <td><strong>$FileEnc</strong></td>
                    <td style="font-family: monospace; font-size: 0.85rem;">$VersIdEnc</td>
                    <td style="color: var(--text-muted); font-size: 0.85rem;">$($log.VersionModified)</td>
                    <td style="color: var(--accent-green); font-weight: bold;">$($log.FreedFormatted)</td>
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
    Write-StatusMsg "Informe HTML post-limpieza generado en: '$DeletionHtmlPath'" -Status "SUCCESS"
} catch {
    Write-StatusMsg "No se pudo generar el informe HTML post-limpieza: $_" -Status "WARN"
}

Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                       RESUMEN DE LIMPIEZA REALIZADA                     " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Total de Versiones eliminadas         : {0}" -f $DeletedCount) -ForegroundColor Green
Write-Host (" Espacio total liberado REAL           : {0}" -f (Format-Bytes -Bytes $FreedBytes)) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

Write-StatusMsg "Script finalizado con exito." -Status "SUCCESS"
