<#
.SYNOPSIS
    SharePoint online - Auditoria y limpieza del historial de versiones con Microsoft graph api (v1.3.0).

.DESCRIPTION
    Script de administracion para SharePoint online que escanea bibliotecas de documentos,
    analiza el uso de espacio en disco por el historial de versiones de los archivos,
    permite seleccion interactiva simple o multiple de sitios y bibliotecas ('1,2,4' / '1-3' / '0'),
    calcula la cantidad exacta de espacio en MB/GB que se recuperara al conservar solo las N ultimas versiones
    (por defecto: 2), genera reportes HTML corporativos interactivos a pantalla completa estilo SharePoint online & fluent ui
    con soporte para resolucion de rutas absolutas y descarga en Azure Cloud Shell,
    y permite realizar el borrado seguro e interactivo de las versiones obsoletas.

.PARAMETER TenantId
    ID o dominio del tenant de Microsoft 365 (para autenticacion desatendida).

.PARAMETER ClientId
    ID de la aplicacion (App ID) de Entra id.

.PARAMETER ClientSecret
    Secreto de aplicacion (Client secret).

.PARAMETER SiteUrl
    URL completa o fragmento del sitio de SharePoint a analizar (ej. "https://contoso.sharepoint.com/sites/Proyectos").

.PARAMETER SiteName
    Alias para -SiteUrl.

.PARAMETER LibraryName
    Nombre de una biblioteca especifica a auditar (ej. "Documentos"). Si se omite, permite seleccionar una o varias bibliotecas.

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
    Version:  1.3.0
    Fecha:    2026-08-11
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

# Parseador de indices de seleccion (soporta numeros individuales, comas '1,2,4,6', rangos '1-3,5' y '0' para todo)
function Get-SelectionIndices {
    param(
        [string]$InputString,
        [int]$MaxRange,
        [bool]$AllowZeroForAll = $true
    )

    if ([string]::IsNullOrWhiteSpace($InputString)) {
        if ($AllowZeroForAll) { return @(0) }
        return @()
    }

    $rawTokens = $InputString -split ','
    $indices = [System.Collections.Generic.List[int]]::new()
    $hasZero = $false

    foreach ($token in $rawTokens) {
        $t = $token.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }

        if ($t -eq "0") {
            $hasZero = $true
            break
        }

        if ($t -match '^(\d+)\s*-\s*(\d+)$') {
            $start = [int]$Matches[1]
            $end = [int]$Matches[2]
            if ($start -gt $end) { $tmp = $start; $start = $end; $end = $tmp }
            for ($i = $start; $i -le $end; $i++) {
                if ($i -ge 1 -and $i -le $MaxRange -and -not $indices.Contains($i)) {
                    $indices.Add($i)
                }
            }
        }
        elseif ($t -match '^\d+$') {
            $val = [int]$t
            if ($val -ge 1 -and $val -le $MaxRange -and -not $indices.Contains($val)) {
                $indices.Add($val)
            }
        }
    }

    if ($hasZero -or ($indices.Count -eq 0 -and $AllowZeroForAll)) {
        return @(0)
    }

    return $indices.ToArray()
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
Write-Host "   Auditoria y limpieza de historial de versiones - SharePoint online   " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Version: 1.2.0 | Graph API | Autor: Alejandro Suarez (@alexsf93)" -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------------------------------
# PASO 1: AUTENTICACION EN MICROSOFT GRAPH
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 1 -TotalSteps 5 -Title "Autenticacion en Microsoft graph"

$Scopes = @("Files.ReadWrite.All", "Sites.ReadWrite.All", "Sites.Read.All")

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
# PASO 2: SELECCION DEL SITIO Y BIBLIOTECA
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 2 -TotalSteps 5 -Title "Seleccion de sitio y biblioteca"

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
    $MaxShow = $AllSites.Count
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

# Obtener bibliotecas de documentos (Drives) del sitio con paginacion
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
    
    $LibChoice = Read-Host "`nSeleccione la biblioteca a auditar (varias separadas por comas ej. 1,2 o 1-3, o 0 para TODAS)"
    $chosenLibIndices = Get-SelectionIndices -InputString $LibChoice -MaxRange $DocDrives.Count -AllowZeroForAll $true

    if ($chosenLibIndices.Count -eq 1 -and $chosenLibIndices[0] -eq 0) {
        $SelectedDrives = $DocDrives
        Write-StatusMsg "Procesando TODAS las bibliotecas del sitio." -Status "INFO"
    } else {
        $SelectedDrives = @()
        foreach ($idx in $chosenLibIndices) {
            $SelectedDrives += $DocDrives[$idx - 1]
        }
        Write-StatusMsg "Bibliotecas seleccionadas ($($SelectedDrives.Count)): $(($SelectedDrives.name) -join ', ')" -Status "SUCCESS"
    }
}

# Consultar / solicitar el umbral de versiones si no se ha especificado explicitamente por CLI
if (-not $PSBoundParameters.ContainsKey("KeepVersions")) {
    $InputVersions = Read-Host "`nCuantas versiones mas recientes desea conservar por archivo? (Por defecto: 2)"
    $ParsedVers = 2
    if ([int]::TryParse($InputVersions, [ref]$ParsedVers) -and $ParsedVers -ge 1) {
        $KeepVersions = $ParsedVers
    } else {
        $KeepVersions = 2
    }
}

Write-StatusMsg "Umbral configurado: Se conservaran las $KeepVersions versiones mas recientes por archivo." -Status "INFO"

# -------------------------------------------------------------------------
# PASO 3: AUDITORIA Y CALCULO DE ESPACIO A RECUPERAR
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 3 -TotalSteps 5 -Title "Auditoria de archivos y calculo de ahorro"

$AuditResults = [System.Collections.Generic.List[PSObject]]::new()
$GlobalStats = @{
    TotalFilesScanned     = 0
    FilesWithExtraVersions= 0
    TotalVersionsFound    = 0
    VersionsToDelete      = 0
    TotalSpaceBytes       = 0L
    RedundantSpaceBytes   = 0L
}

# Funcion recursiva robusta para escanear elementos de carpetas en SharePoint
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

# Presentar informe consolidado de auditoria por consola
Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                       Resumen de auditoria                              " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Total de archivos analizados          : {0}" -f $GlobalStats.TotalFilesScanned) -ForegroundColor White
Write-Host (" Archivos con versiones excedentes     : {0}" -f $GlobalStats.FilesWithExtraVersions) -ForegroundColor Yellow
Write-Host (" Total de versiones encontradas        : {0}" -f $GlobalStats.TotalVersionsFound) -ForegroundColor White
Write-Host (" Total de versiones a eliminar         : {0}" -f $GlobalStats.VersionsToDelete) -ForegroundColor Red
Write-Host (" Umbral de versiones a conservar       : {0}" -f $KeepVersions) -ForegroundColor Cyan
Write-Host (" Espacio total estimado a recuperar    : {0}" -f (Format-Bytes -Bytes $GlobalStats.RedundantSpaceBytes)) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

# -------------------------------------------------------------------------
# PASO 4: GENERACION DE REPORTE HTML DE AUDITORIA PREVIA
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 4 -TotalSteps 5 -Title "Generacion de reporte HTML previo"

Ensure-DirectoryExists -FilePath $HtmlOutputPath

try {
    $FormattedSavings = Format-Bytes -Bytes $GlobalStats.RedundantSpaceBytes
    $SiteNameEncoded = [System.Net.WebUtility]::HtmlEncode($TargetSite.displayName)
    $DateNowStr = (Get-SpainDateTime).ToString("yyyy-MM-dd HH:mm:ss")

    $AuditRowsHtml = [System.Text.StringBuilder]::new()
    foreach ($item in $AuditResults) {
        $LibNameEnc = [System.Net.WebUtility]::HtmlEncode($item.LibraryName)
        $FileNameEnc = [System.Net.WebUtility]::HtmlEncode($item.FileName)
        $PathEnc = [System.Net.WebUtility]::HtmlEncode($item.Path)
        
        [void]$AuditRowsHtml.AppendLine("
        <tr>
            <td>$LibNameEnc</td>
            <td><strong>$FileNameEnc</strong></td>
            <td style=`"color: var(--text-secondary); font-size: 0.84rem;`">$PathEnc</td>
            <td>$($item.TotalVersions)</td>
            <td>$($item.VersionsToKeep)</td>
            <td style=`"color: var(--accent-red); font-weight: 600;`">$($item.VersionsToDelete)</td>
            <td style=`"color: var(--accent-green); font-weight: 600;`">$($item.RecoverableSpace)</td>
        </tr>")
    }

    $HtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Informe de auditoria de historial de versiones - SharePoint online</title>
    <style>
        :root {
            /* Microsoft fluent ui design tokens - SharePoint online light mode */
            --spo-brand: #03787c;
            --spo-brand-hover: #004e52;
            --spo-brand-dark: #004e52;
            --m365-suite-bg: #03787c;
            
            --bg-main: #faf9f8;
            --bg-card: #ffffff;
            --bg-header: #ffffff;
            --bg-table-header: #faf9f8;
            --bg-table-hover: #f3f2f1;
            --bg-input: #ffffff;
            
            --text-primary: #201f1e;
            --text-secondary: #605e5c;
            --text-heading: #11100f;
            --text-link: #03787c;
            
            --border-color: #edebe9;
            --border-subtle: #e1dfdd;
            --accent-green: #107c41;
            --accent-red: #d13438;
            
            --shadow-card: 0 1.6px 3.6px 0 rgba(0,0,0,0.132), 0 0.3px 0.9px 0 rgba(0,0,0,0.108);
        }

        [data-theme="dark"] {
            /* Microsoft fluent ui dark mode */
            --spo-brand: #479ef5;
            --spo-brand-hover: #70baff;
            --spo-brand-dark: #0f172a;
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
            --text-link: #479ef5;
            
            --border-color: #292827;
            --border-subtle: #323130;
            --accent-green: #4ade80;
            --accent-red: #f87171;
            
            --shadow-card: 0 2px 8px rgba(0, 0, 0, 0.4);
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

        /* Top suite bar Microsoft 365 SharePoint */
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
        .spo-icon { display: flex; align-items: center; }
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
        .theme-toggle-btn:hover { border-color: var(--spo-brand); color: var(--spo-brand); background: var(--bg-table-hover); }

        .ms-message-bar {
            background: var(--bg-card);
            border: 1px solid var(--border-subtle);
            border-left: 4px solid var(--spo-brand);
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
        .ms-message-bar svg { color: var(--spo-brand); flex-shrink: 0; }

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
            background-color: var(--spo-brand);
        }
        .metric-card.card-green::before { background-color: var(--accent-green); }
        .metric-card.card-red::before { background-color: var(--accent-red); }
        .metric-card.card-blue::before { background-color: var(--spo-brand); }

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
            border-left: 4px solid var(--spo-brand);
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
    <!-- Top suite bar Microsoft 365 SharePoint -->
    <div class="m365-suite-bar">
        <div class="suite-left">
            <svg class="waffle-icon" viewBox="0 0 20 20" width="20" height="20" fill="currentColor">
                <circle cx="4" cy="4" r="1.8"/><circle cx="10" cy="4" r="1.8"/><circle cx="16" cy="4" r="1.8"/>
                <circle cx="4" cy="10" r="1.8"/><circle cx="10" cy="10" r="1.8"/><circle cx="16" cy="10" r="1.8"/>
                <circle cx="4" cy="16" r="1.8"/><circle cx="10" cy="16" r="1.8"/><circle cx="16" cy="16" r="1.8"/>
            </svg>
            <div class="spo-icon">
                <svg viewBox="0 0 24 24" width="22" height="22" fill="none">
                    <rect width="24" height="24" rx="4" fill="#03787C"/>
                    <path d="M12 4C7.58 4 4 7.58 4 12C4 16.42 7.58 20 12 20C16.42 20 20 16.42 20 12C20 7.58 16.42 4 12 4ZM12 17.5C8.96 17.5 6.5 15.04 6.5 12C6.5 8.96 8.96 6.5 12 6.5C15.04 6.5 17.5 8.96 17.5 12C17.5 15.04 15.04 17.5 12 17.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M14.5 12C14.5 13.38 13.38 14.5 12 14.5C10.62 14.5 9.5 13.38 9.5 12C9.5 10.62 10.62 9.5 12 9.5C13.38 9.5 14.5 10.62 14.5 12Z" fill="white"/>
                </svg>
            </div>
            <span class="suite-title">SharePoint</span>
            <span class="suite-subtitle">| Limpieza de historial de versiones</span>
        </div>
        <div class="suite-right">
            <div class="suite-meta-item">
                <span class="meta-label">Sitio:</span>
                <span class="meta-value">$SiteNameEncoded</span>
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
                <h1>Informe de auditoria de historial de versiones</h1>
                <p>Analisis detallado para el sitio <strong>$SiteNameEncoded</strong></p>
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
                <span>Se conservaran las <b>$KeepVersions versiones mas recientes</b> por archivo. Las versiones sobrantes son candidatas a eliminacion.</span>
            </div>
        </div>

        <div class="metrics-grid">
            <div class="metric-card card-blue">
                <div class="title">Archivos analizados</div>
                <div class="value">$($GlobalStats.TotalFilesScanned)</div>
                <div class="subtext">Elementos evaluados</div>
            </div>
            <div class="metric-card card-blue">
                <div class="title">Archivos con excedente</div>
                <div class="value">$($GlobalStats.FilesWithExtraVersions)</div>
                <div class="subtext">Con historial a limpiar</div>
            </div>
            <div class="metric-card card-red">
                <div class="title">Versiones a eliminar</div>
                <div class="value">$($GlobalStats.VersionsToDelete)</div>
                <div class="subtext">Candidatas a borrado</div>
            </div>
            <div class="metric-card card-green">
                <div class="title">Espacio recuperable</div>
                <div class="value">$FormattedSavings</div>
                <div class="subtext">Estimacion de espacio a liberar</div>
            </div>
        </div>

        <div class="section-title">Detalle de archivos con historial excedente</div>
        <div class="table-card">
            <div class="table-container">
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
                        $($AuditRowsHtml.ToString())
                    </tbody>
                </table>
            </div>
        </div>

        <div class="footer">
            <div class="footer-content">
                <svg viewBox="0 0 24 24" width="16" height="16" fill="none">
                    <rect width="24" height="24" rx="4" fill="#03787C"/>
                    <path d="M12 4C7.58 4 4 7.58 4 12C4 16.42 7.58 20 12 20C16.42 20 20 16.42 20 12C20 7.58 16.42 4 12 4ZM12 17.5C8.96 17.5 6.5 15.04 6.5 12C6.5 8.96 8.96 6.5 12 6.5C15.04 6.5 17.5 8.96 17.5 12C17.5 15.04 15.04 17.5 12 17.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M14.5 12C14.5 13.38 13.38 14.5 12 14.5C10.62 14.5 9.5 13.38 9.5 12C9.5 10.62 10.62 9.5 12 9.5C13.38 9.5 14.5 10.62 14.5 12Z" fill="white"/>
                </svg>
                <span>Microsoft 365 - SharePoint online limpieza de historial de versiones</span>
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
            try { localStorage.setItem('spo_vers_theme', theme); } catch (e) {}
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
            try { savedTheme = localStorage.getItem('spo_vers_theme') || 'light'; } catch (e) {}
            setTheme(savedTheme);
        })();
    </script>
</body>
</html>
"@

    $utf8Encoding = [System.Text.UTF8Encoding]::new($true)
    $resolvedHtmlPath = if ([System.IO.Path]::IsPathRooted($HtmlOutputPath)) { $HtmlOutputPath } else { [System.IO.Path]::Combine($PWD.Path, $HtmlOutputPath) }
    [System.IO.File]::WriteAllText($resolvedHtmlPath, $HtmlContent, $utf8Encoding)
    Write-StatusMsg "Reporte HTML guardado correctamente en la ruta absoluta: '$resolvedHtmlPath'" -Status "SUCCESS"

    if ($env:ACC_CLOUD_SHELL -or $env:AZURE_HTTP_USER_AGENT -or ($PSVersionTable.Platform -eq 'Unix')) {
        Write-Host "  [i] Entorno Azure Cloud Shell / Linux detectado. Para descargar a tu equipo local:" -ForegroundColor Cyan
        Write-Host "      download `"$resolvedHtmlPath`"`n" -ForegroundColor Yellow
    }
} catch {
    Write-StatusMsg "No se pudo generar el reporte HTML de auditoria: $_" -Status "WARN"
}

# Presentar el informe en consola sin abrir navegador
Write-Host "`n-------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host " Informe de auditoria disponible para revision" -ForegroundColor White
Write-Host "-------------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host " Se ha generado el informe HTML interactivo en:" -ForegroundColor White
Write-Host " -> $((Resolve-Path $HtmlOutputPath -ErrorAction SilentlyContinue).Path)" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# PASO 5: EJECUCION DE LIMPIEZA DE VERSIONES (CONFIRMACION & BORRADO)
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 5 -TotalSteps 5 -Title "Ejecucion de limpieza de versiones"

if ($AuditOnly) {
    Write-StatusMsg "Modo '-AuditOnly' activado. El informe se ha generado sin realizar cambios en SharePoint." -Status "INFO"
    Write-Host "`nProceso completado exitosamente (solo auditoria).`n" -ForegroundColor Green
    exit 0
}

if ($GlobalStats.VersionsToDelete -eq 0) {
    Write-StatusMsg "No hay versiones obsoletas que eliminar segun el umbral especificado ($KeepVersions)." -Status "SUCCESS"
    Write-Host "`nProceso completado.`n" -ForegroundColor Green
    exit 0
}

# Confirmacion tras ver el informe
$Confirm = $false
if ($Force) {
    $Confirm = $true
} else {
    Write-Host "`n[!] Por favor, revise el informe HTML generado antes de tomar una decision." -ForegroundColor DarkYellow
    Write-Host "    El informe incluye la lista de $($GlobalStats.FilesWithExtraVersions) archivos afectados y sus $($GlobalStats.VersionsToDelete) versiones candidatas a borrado.`n" -ForegroundColor DarkYellow
    
    Write-Host "Atencion: Esta accion eliminara de forma irreversible $($GlobalStats.VersionsToDelete) versiones de archivos" -ForegroundColor Red
    Write-Host "para liberar un total estimado de $(Format-Bytes -Bytes $GlobalStats.RedundantSpaceBytes) de almacenamiento.`n" -ForegroundColor Red
    
    $Answer = Read-Host "Tras revisar el informe, desea proceder con la eliminacion real de estas versiones? (S/N)"
    if ($Answer -eq "S" -or $Answer -eq "s" -or $Answer -eq "SI" -or $Answer -eq "si") {
        $Confirm = $true
    }
}

if (-not $Confirm) {
    Write-StatusMsg "Operacion cancelada por el usuario. No se elimino ninguna version." -Status "WARN"
    Write-Host "`nProceso finalizado sin cambios.`n" -ForegroundColor Yellow
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
                    VersionModified  = (Get-SpainDateTime ([DateTime]$v.lastModifiedDateTime)).ToString("yyyy-MM-dd HH:mm:ss")
                    FreedBytes       = $VSize
                    FreedFormatted   = Format-Bytes -Bytes $VSize
                    Status           = "Exito"
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
                    VersionModified  = (Get-SpainDateTime ([DateTime]$v.lastModifiedDateTime)).ToString("yyyy-MM-dd HH:mm:ss")
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
# GENERACION DEL INFORME HTML POST-LIMPIEZA (RESULTADOS REALES)
# -------------------------------------------------------------------------
Write-StatusMsg "Generando informe final HTML post-limpieza con los resultados..." -Status "WORKING"

Ensure-DirectoryExists -FilePath $DeletionHtmlPath

try {
    $FormattedRealFreed = Format-Bytes -Bytes $FreedBytes
    $SiteNameEncoded = [System.Net.WebUtility]::HtmlEncode($TargetSite.displayName)
    $DateNowStr = (Get-SpainDateTime).ToString("yyyy-MM-dd HH:mm:ss")

    $PostRowsHtml = [System.Text.StringBuilder]::new()
    foreach ($log in $DeletionLogList) {
        $BadgeClass = if ($log.Status -eq "Exito") { "badge-green" } else { "badge-red" }
        $LibEnc = [System.Net.WebUtility]::HtmlEncode($log.LibraryName)
        $FileEnc = [System.Net.WebUtility]::HtmlEncode($log.FileName)
        $VersIdEnc = [System.Net.WebUtility]::HtmlEncode($log.VersionId)

        [void]$PostRowsHtml.AppendLine("
        <tr>
            <td>$LibEnc</td>
            <td><strong>$FileEnc</strong></td>
            <td style=`"font-family: monospace; font-size: 0.85rem;`">$VersIdEnc</td>
            <td style=`"color: var(--text-secondary); font-size: 0.84rem;`">$($log.VersionModified)</td>
            <td style=`"color: var(--accent-green); font-weight: 600;`">$($log.FreedFormatted)</td>
            <td><span class=`"badge $BadgeClass`">$($log.Status)</span></td>
        </tr>")
    }

    $PostHtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Informe de limpieza ejecutada - SharePoint online</title>
    <style>
        :root {
            /* Microsoft fluent ui design tokens - SharePoint online light mode */
            --spo-brand: #03787c;
            --spo-brand-hover: #004e52;
            --spo-brand-dark: #004e52;
            --m365-suite-bg: #03787c;
            
            --bg-main: #faf9f8;
            --bg-card: #ffffff;
            --bg-header: #ffffff;
            --bg-table-header: #faf9f8;
            --bg-table-hover: #f3f2f1;
            --bg-input: #ffffff;
            
            --text-primary: #201f1e;
            --text-secondary: #605e5c;
            --text-heading: #11100f;
            --text-link: #03787c;
            
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
            --spo-brand: #479ef5;
            --spo-brand-hover: #70baff;
            --spo-brand-dark: #0f172a;
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
            --text-link: #479ef5;
            
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

        /* Top suite bar Microsoft 365 SharePoint */
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
        .spo-icon { display: flex; align-items: center; }
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
        .theme-toggle-btn:hover { border-color: var(--spo-brand); color: var(--spo-brand); background: var(--bg-table-hover); }

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
            background-color: var(--spo-brand);
        }
        .metric-card.card-green::before { background-color: var(--accent-green); }
        .metric-card.card-blue::before { background-color: var(--spo-brand); }

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
            border-left: 4px solid var(--spo-brand);
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
    <!-- Top suite bar Microsoft 365 SharePoint -->
    <div class="m365-suite-bar">
        <div class="suite-left">
            <svg class="waffle-icon" viewBox="0 0 20 20" width="20" height="20" fill="currentColor">
                <circle cx="4" cy="4" r="1.8"/><circle cx="10" cy="4" r="1.8"/><circle cx="16" cy="4" r="1.8"/>
                <circle cx="4" cy="10" r="1.8"/><circle cx="10" cy="10" r="1.8"/><circle cx="16" cy="10" r="1.8"/>
                <circle cx="4" cy="16" r="1.8"/><circle cx="10" cy="16" r="1.8"/><circle cx="16" cy="16" r="1.8"/>
            </svg>
            <div class="spo-icon">
                <svg viewBox="0 0 24 24" width="22" height="22" fill="none">
                    <rect width="24" height="24" rx="4" fill="#03787C"/>
                    <path d="M12 4C7.58 4 4 7.58 4 12C4 16.42 7.58 20 12 20C16.42 20 20 16.42 20 12C20 7.58 16.42 4 12 4ZM12 17.5C8.96 17.5 6.5 15.04 6.5 12C6.5 8.96 8.96 6.5 12 6.5C15.04 6.5 17.5 8.96 17.5 12C17.5 15.04 15.04 17.5 12 17.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M14.5 12C14.5 13.38 13.38 14.5 12 14.5C10.62 14.5 9.5 13.38 9.5 12C9.5 10.62 10.62 9.5 12 9.5C13.38 9.5 14.5 10.62 14.5 12Z" fill="white"/>
                </svg>
            </div>
            <span class="suite-title">SharePoint</span>
            <span class="suite-subtitle">| Limpieza de historial de versiones</span>
        </div>
        <div class="suite-right">
            <div class="suite-meta-item">
                <span class="meta-label">Sitio:</span>
                <span class="meta-value">$SiteNameEncoded</span>
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
                <p>Resultado final para el sitio <strong>$SiteNameEncoded</strong></p>
            </div>
            <button id="themeToggleBtn" class="theme-toggle-btn" onclick="toggleTheme()" title="Cambiar tema de color">
                <span id="themeIcon"><svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor"><path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z"/></svg></span> <span id="themeText">Modo oscuro</span>
            </button>
        </div>

        <div class="metrics-grid">
            <div class="metric-card card-blue">
                <div class="title">Archivos limpiados</div>
                <div class="value">$($CleanedFilesSet.Count)</div>
                <div class="subtext">Elementos procesados</div>
            </div>
            <div class="metric-card card-green">
                <div class="title">Versiones eliminadas</div>
                <div class="value">$DeletedCount</div>
                <div class="subtext">Historial purgado</div>
            </div>
            <div class="metric-card card-green">
                <div class="title">Espacio real liberado</div>
                <div class="value">$FormattedRealFreed</div>
                <div class="subtext">Almacenamiento recuperado</div>
            </div>
        </div>

        <div class="section-title">Registro detallado de versiones eliminadas</div>
        <div class="table-card">
            <div class="table-container">
                <table>
                    <thead>
                        <tr>
                            <th>Biblioteca</th>
                            <th>Archivo</th>
                            <th>ID de version</th>
                            <th>Fecha de modificacion</th>
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
                    <rect width="24" height="24" rx="4" fill="#03787C"/>
                    <path d="M12 4C7.58 4 4 7.58 4 12C4 16.42 7.58 20 12 20C16.42 20 20 16.42 20 12C20 7.58 16.42 4 12 4ZM12 17.5C8.96 17.5 6.5 15.04 6.5 12C6.5 8.96 8.96 6.5 12 6.5C15.04 6.5 17.5 8.96 17.5 12C17.5 15.04 15.04 17.5 12 17.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M14.5 12C14.5 13.38 13.38 14.5 12 14.5C10.62 14.5 9.5 13.38 9.5 12C9.5 10.62 10.62 9.5 12 9.5C13.38 9.5 14.5 10.62 14.5 12Z" fill="white"/>
                </svg>
                <span>Microsoft 365 - SharePoint online limpieza de historial de versiones</span>
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
            try { localStorage.setItem('spo_vers_theme', theme); } catch (e) {}
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
            try { savedTheme = localStorage.getItem('spo_vers_theme') || 'light'; } catch (e) {}
            setTheme(savedTheme);
        })();
    </script>
</body>
</html>
"@

    $utf8Encoding = [System.Text.UTF8Encoding]::new($true)
    $resolvedDelPath = if ([System.IO.Path]::IsPathRooted($DeletionHtmlPath)) { $DeletionHtmlPath } else { [System.IO.Path]::Combine($PWD.Path, $DeletionHtmlPath) }
    [System.IO.File]::WriteAllText($resolvedDelPath, $PostHtmlContent, $utf8Encoding)
    Write-StatusMsg "Informe HTML post-limpieza generado en la ruta absoluta: '$resolvedDelPath'" -Status "SUCCESS"

    if ($env:ACC_CLOUD_SHELL -or $env:AZURE_HTTP_USER_AGENT -or ($PSVersionTable.Platform -eq 'Unix')) {
        Write-Host "  [i] Entorno Azure Cloud Shell / Linux detectado. Para descargar a tu equipo local:" -ForegroundColor Cyan
        Write-Host "      download `"$resolvedDelPath`"`n" -ForegroundColor Yellow
    }
} catch {
    Write-StatusMsg "No se pudo generar el informe HTML post-limpieza: $_" -Status "WARN"
}

Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                       Resumen de limpieza realizada                     " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Total de versiones eliminadas         : {0}" -f $DeletedCount) -ForegroundColor Green
Write-Host (" Espacio total liberado real           : {0}" -f (Format-Bytes -Bytes $FreedBytes)) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

Write-StatusMsg "Script finalizado con exito." -Status "SUCCESS"
