<#
.SYNOPSIS
    SharePoint Online - Auditoria completa de almacenamiento no productivo con Microsoft Graph API y Entra ID.

.DESCRIPTION
    Audita, cuantifica y clasifica el espacio consumido por tres fuentes principales de almacenamiento no productivo en SharePoint Online:
    1. PreservationHoldLibrary: archivos retenidos obligatoriamente por directivas de Microsoft Purview, retencion o eDiscovery/Litigation Hold.
    2. Papelera de Reciclaje (1ª y 2ª etapa): elementos eliminados pendientes de purga definitiva.
    3. Historial de Versiones: espacio acumulado por versiones antiguas de documentos en bibliotecas.

    Capacidades y Caracteristicas:
    - Autenticacion desatendida con App Registration de Entra ID (Client Secret o Certificado digital).
    - Soporte para autenticacion delegada interactiva en navegador (usuario administrador).
    - Descubrimiento multicanal exhaustivo de sitios (sitio raiz, getAllSites, busqueda global, grupos M365/Teams).
    - Resolucion automatica del dominio de SharePoint del tenant.
    - Soporte para entrada directa por parametro (-SiteUrl, -SiteName) o por archivo CSV (-CsvPath).
    - Control avanzado de throttling (HTTP 429/503) con reintentos exponenciales y respeto a cabeceras Retry-After.
    - Resiliencia por sitio: si un sitio individual presenta un error (ej. permisos insuficientes), se registra en la lista de fallos y el script continua con los demas.
    - Generacion de informe HTML interactivo corporativo con Fluent UI, buscador instantaneo, ordenacion, modo claro/oscuro y exportacion CSV integrada.

.PARAMETER TenantId
    ID del Directorio (Tenant ID) de Microsoft 365 / Entra ID (formato GUID o dominio 'contoso.onmicrosoft.com').
    Acepta el alias -Tenant o variables de entorno AZURE_TENANT_ID, ENTRA_TENANT_ID, TENANT_ID.

.PARAMETER ClientId
    ID de la Aplicacion (Client ID / App ID) del App Registration registrado en Entra ID.
    Acepta los alias -AppId, -ApplicationId o variables de entorno AZURE_CLIENT_ID, ENTRA_CLIENT_ID, CLIENT_ID.

.PARAMETER ClientSecret
    Secreto del cliente (Client Secret) generado en el App Registration.
    Acepta el alias -Secret o variables de entorno AZURE_CLIENT_SECRET, ENTRA_CLIENT_SECRET, CLIENT_SECRET.

.PARAMETER CertificateThumbprint
    Huella digital (Thumbprint) de un certificado instalado en el almacen local (Cert:\CurrentUser\My o Cert:\LocalMachine\My).
    Acepta los alias -Thumbprint, -CertificateThumb o variable AZURE_CERTIFICATE_THUMBPRINT.

.PARAMETER CertificatePath
    Ruta a un archivo de certificado digital (.pfx o .cer) para autenticacion por certificado.
    Acepta el alias -CertPath o variable AZURE_CERTIFICATE_PATH.

.PARAMETER CertificatePassword
    Contrasena para abrir el certificado en caso de estar protegido.

.PARAMETER TenantHost
    Dominio raiz de SharePoint Online del tenant (ej. "contoso.sharepoint.com").
    Si se omite, se detecta automaticamente mediante Microsoft Graph.

.PARAMETER SiteUrl
    Nombre, ruta relativa o URL completa del sitio a auditar (ej. "Finanzas", "/sites/Finanzas" o "https://contoso.sharepoint.com/sites/Finanzas").
    Acepta el alias -Url.

.PARAMETER SiteName
    Alias alternativo para -SiteUrl.
    Acepta el alias -Name.

.PARAMETER CsvPath
    Ruta a un archivo CSV con listado de URLs de sitios a auditar (una URL por fila).
    Acepta el alias -Csv.

.PARAMETER HtmlOutputPath
    Ruta donde se guardara el informe HTML interactivo. Por defecto se guarda en 'Reportes/'.
    Acepta los alias -Output, -ReportPath.

.PARAMETER CsvOutputPath
    Ruta del archivo CSV con el inventario detallado de todos los elementos auditados.

.PARAMETER ExportCsv
    Indica si se debe generar el archivo CSV con el inventario completo ($true por defecto).

.PARAMETER ExcludePersonalSites
    Omite OneDrives personales (/personal/*) durante el descubrimiento global ($true por defecto).

.PARAMETER AuditVersionHistory
    Audita el espacio ocupado por versiones antiguas de documentos ($true por defecto).

.PARAMETER MaxVersionFilesPerSite
    Maximo de archivos a inspeccionar versiones por sitio (2000 por defecto; 0 = sin limite).

.PARAMETER ExcludedSitePatterns
    Patrones o palabras clave de URL para excluir sitios de sistema (appcatalog, search, delve, etc.).

.NOTES
    Nombre:                  Microsoft 365 - SharePoint - Auditoria_PreservationHoldLibrary.ps1
    Versión:                 3.1.0
    Autor:                   Alejandro Suarez (@alexsf93)
    Fecha de revisión:       2026-09-30
    Modo de autenticación:   Entra ID App Registration (App-Only) / Sesión interactiva delegada

    Permisos requeridos en Entra ID App Registration:
    Para la ejecución del script, la aplicación registrada en Microsoft Entra ID debe disponer
    de permisos de solo lectura acordes al principio de mínimo privilegio (Least Privilege) con consentimiento
    de administrador concedido:

    1. Microsoft Graph API (Permisos de tipo aplicación / Application permissions):
       - Sites.Read.All          (Requerido: lectura del inventario de sitios, drives y biblioteca PreservationHoldLibrary)
       - Files.Read.All          (Requerido: lectura de metadatos de archivos y análisis del historial de versiones)
       - Group.Read.All          (Requerido: descubrimiento de sitios vinculados a grupos de Microsoft 365 y Teams)
       - Organization.Read.All   (Opcional: detección automática del nombre de dominio raíz de SharePoint del tenant)

    2. SharePoint Online API (Office 365 SharePoint Online - Permisos de tipo aplicación):
       - Sites.Read.All          (Requerido: consulta de lectura de la papelera de reciclaje y configuración de bibliotecas)

    Nota sobre Sites.FullControl.All:
    Este script realiza exclusivamente tareas de auditoría y extracción de métricas de almacenamiento (100% solo lectura).
    Por tanto, NO requiere permisos de control total (Sites.FullControl.All) ni permisos de escritura (Sites.ReadWrite.All).
    El uso de Sites.Read.All garantiza el cumplimiento de las políticas de seguridad y mínimo privilegio corporativas.

    Consentimiento de administración:
    Los permisos de tipo aplicación requieren que un administrador de Entra ID pulse en
    "Conceder consentimiento de administrador para [Organización]" (Grant admin consent).

.EXAMPLE
    # 1. Ejecucion desatendida con Client Secret (o leyendo variables de entorno):
    .\Microsoft 365 - SharePoint - Auditoria_PreservationHoldLibrary.ps1 -TenantId "00000000-0000-0000-0000-000000000000" -ClientId "11111111-1111-1111-1111-111111111111" -ClientSecret "MiSecretoSeguro"

.EXAMPLE
    # 2. Auditar un sitio especifico:
    .\Microsoft 365 - SharePoint - Auditoria_PreservationHoldLibrary.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/Legal"

.EXAMPLE
    # 3. Auditar lista de sitios desde un archivo CSV:
    .\Microsoft 365 - SharePoint - Auditoria_PreservationHoldLibrary.ps1 -CsvPath ".\sitios_auditar.csv"
#>

[CmdletBinding()]
param(
    # --- Credenciales de Entra ID App Registration ---
    [Alias("Tenant", "DirectoryId")]
    [string]$TenantId = $(if ($env:AZURE_TENANT_ID) { $env:AZURE_TENANT_ID } elseif ($env:ENTRA_TENANT_ID) { $env:ENTRA_TENANT_ID } elseif ($env:TENANT_ID) { $env:TENANT_ID } else { "" }),

    [Alias("AppId", "ApplicationId")]
    [string]$ClientId = $(if ($env:AZURE_CLIENT_ID) { $env:AZURE_CLIENT_ID } elseif ($env:ENTRA_CLIENT_ID) { $env:ENTRA_CLIENT_ID } elseif ($env:CLIENT_ID) { $env:CLIENT_ID } else { "" }),

    [Alias("Secret")]
    [string]$ClientSecret = $(if ($env:AZURE_CLIENT_SECRET) { $env:AZURE_CLIENT_SECRET } elseif ($env:ENTRA_CLIENT_SECRET) { $env:ENTRA_CLIENT_SECRET } elseif ($env:CLIENT_SECRET) { $env:CLIENT_SECRET } else { "" }),

    [Alias("CertificateThumb", "Thumbprint")]
    [string]$CertificateThumbprint = $(if ($env:AZURE_CERTIFICATE_THUMBPRINT) { $env:AZURE_CERTIFICATE_THUMBPRINT } elseif ($env:CERTIFICATE_THUMBPRINT) { $env:CERTIFICATE_THUMBPRINT } else { "" }),

    [Alias("CertPath")]
    [string]$CertificatePath = $(if ($env:AZURE_CERTIFICATE_PATH) { $env:AZURE_CERTIFICATE_PATH } elseif ($env:CERTIFICATE_PATH) { $env:CERTIFICATE_PATH } else { "" }),

    [string]$CertificatePassword = "",

    # --- Dominio y seleccion de sitios ---
    [Alias("SharePointDomain", "Domain")]
    [string]$TenantHost = $(if ($env:SHAREPOINT_DOMAIN) { $env:SHAREPOINT_DOMAIN } elseif ($env:TENANT_HOST) { $env:TENANT_HOST } else { "" }),

    [Alias("Url")]
    [string]$SiteUrl = "",

    [Alias("Name")]
    [string]$SiteName = "",

    [Alias("Csv")]
    [string]$CsvPath = "",

    # --- Rutas de salida y opciones de reporte ---
    [Alias("Output", "ReportPath")]
    [string]$HtmlOutputPath = "",

    [string]$CsvOutputPath = "",

    [bool]$ExportCsv = $true,

    [bool]$ExcludePersonalSites = $true,

    [bool]$AuditVersionHistory = $true,

    [int]$MaxVersionFilesPerSite = 2000,

    [string[]]$ExcludedSitePatterns = @(
        "contentTypeHub",
        "portals/hub",
        "portals/community",
        "groupforanswersinvivaengage",
        "search",
        "appcatalog",
        "redirect",
        "delve"
    )
)

# =========================================================================
# SECCION 1: FUNCIONES DE UI, FORMATO Y UTILIDADES
# =========================================================================

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Write-StepHeader {
    param(
        [int]$StepNumber,
        [int]$TotalSteps = 5,
        [string]$Title
    )
    Write-Host ""
    Write-Host "  --------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  Paso {0} de {1}: {2}" -f $StepNumber, $TotalSteps, $Title) -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------------------------------" -ForegroundColor DarkGray
}

function Write-StatusMsg {
    param(
        [string]$Message,
        [string]$Status = "INFO"
    )
    switch ($Status) {
        "SUCCESS" {
            Write-Host "  [OK]   " -ForegroundColor Green -NoNewline
            Write-Host $Message -ForegroundColor White
        }
        "WORKING" {
            Write-Host "  [..]   " -ForegroundColor Yellow -NoNewline
            Write-Host $Message -ForegroundColor Gray
        }
        "INFO"    {
            Write-Host "  [INFO] " -ForegroundColor Cyan -NoNewline
            Write-Host $Message -ForegroundColor White
        }
        "WARN"    {
            Write-Host "  [WARN] " -ForegroundColor DarkYellow -NoNewline
            Write-Host $Message -ForegroundColor Yellow
        }
        "FAIL"    {
            Write-Host "  [ERR]  " -ForegroundColor Red -NoNewline
            Write-Host $Message -ForegroundColor Red
        }
        default   {
            Write-Host "  [--]   " -ForegroundColor Gray -NoNewline
            Write-Host $Message -ForegroundColor Gray
        }
    }
}

function Format-FileSize {
    param([double]$Bytes)
    if ($null -eq $Bytes -or $Bytes -le 0) { return "0 B" }
    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return ("{0:N0} B" -f $Bytes)
}

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

function Clear-FileNameString {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $t = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($c in [char[]]$t) {
        $uc = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($uc -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            $sb.Append($c) | Out-Null
        }
    }
    $clean = $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
    $clean = $clean -replace '[^a-zA-Z0-9_-]', ''
    return $clean
}

function Get-ReportFileName {
    param(
        [string]$SiteNameInput,
        [string]$Extension = "html"
    )
    if ([string]::IsNullOrWhiteSpace($SiteNameInput)) {
        $raw = "todos_los_sites"
    } else {
        $raw = $SiteNameInput
    }
    if ($raw -match "https?://[^/]+/(sites|teams)/([^/]+)") {
        $raw = $Matches[2]
    } elseif ($raw -match "https?://[^/]+/?") {
        $raw = "RootSite"
    }
    $raw = $raw -replace '\s+', '_' -replace '[-]+', '_'
    $clean = Clear-FileNameString -Text $raw
    if ([string]::IsNullOrWhiteSpace($clean)) {
        $clean = "todos_los_sites"
    }
    return "Report_Preservation_Papelera_${clean}.${Extension}"
}

function Get-SpainDate {
    param([datetime]$InputDate = [datetime]::UtcNow)
    
    $utcDate = if ($InputDate.Kind -eq [System.DateTimeKind]::Utc) { 
        $InputDate 
    } else { 
        $InputDate.ToUniversalTime() 
    }

    $spainTzi = $null
    $possibleIds = @("Europe/Madrid", "Romance Standard Time", "W. Europe Standard Time")
    
    foreach ($tz in $possibleIds) {
        try {
            $spainTzi = [System.TimeZoneInfo]::FindSystemTimeZoneById($tz)
            if ($spainTzi) { break }
        } catch {
            Write-Verbose "Zona horaria '$tz' no disponible en este sistema."
        }
    }

    if ($spainTzi) {
        return [System.TimeZoneInfo]::ConvertTimeFromUtc($utcDate, $spainTzi)
    } else {
        return $utcDate.AddHours(2)
    }
}

# =========================================================================
# SECCION 2: MOTOR DE LLAMADAS Y PAGINACION GRAPH / REST
# =========================================================================

function Invoke-GraphRequestWithRetry {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [int]$MaxRetries = 4,
        [int]$BaseDelaySeconds = 2
    )
    $attempt = 0
    while ($attempt -le $MaxRetries) {
        try {
            $response = Invoke-MgGraphRequest -Method $Method -Uri $Uri -ErrorAction Stop
            return $response
        } catch {
            $ex = $_.Exception
            $statusCode = 0
            if ($ex.Response -and $ex.Response.StatusCode) {
                $statusCode = [int]$ex.Response.StatusCode
            }

            $isThrottled = ($statusCode -eq 429 -or $statusCode -eq 503 -or $statusCode -eq 504 -or 
                            $ex.Message -like "*429*" -or $ex.Message -like "*503*" -or $ex.Message -like "*TooManyRequests*")
            
            if ($isThrottled) {
                $attempt++
                if ($attempt -gt $MaxRetries) {
                    Write-StatusMsg -Message "Superado el limite maximo de reintentos ($MaxRetries) para la peticion." -Status "FAIL"
                    throw $_
                }
                
                $retryAfter = [int]($BaseDelaySeconds * [math]::Pow(2, $attempt - 1))
                if ($ex.Response -and $ex.Response.Headers -and $ex.Response.Headers["Retry-After"]) {
                    $headerVal = $ex.Response.Headers["Retry-After"]
                    $parsedSec = 0
                    if ([int]::TryParse($headerVal, [ref]$parsedSec) -and $parsedSec -gt 0) {
                        $retryAfter = $parsedSec
                    }
                }

                $jitter = Get-Random -Minimum 1 -Maximum 3
                $totalWait = $retryAfter + $jitter

                Write-StatusMsg -Message "Control de peticiones activo (HTTP $statusCode). Pausa de ${totalWait}s (Intento $attempt de $MaxRetries)..." -Status "WARN"
                Start-Sleep -Seconds $totalWait
            } else {
                throw $_
            }
        }
    }
}

function Invoke-GraphPaginatedRequest {
    param(
        [string]$Uri,
        [int]$MaxPages = 0
    )
    $results = [System.Collections.Generic.List[PSObject]]::new()
    $nextUri = $Uri
    $pageCount = 0
    $seenUrls = @{}

    while ($nextUri) {
        if ($seenUrls.ContainsKey($nextUri)) {
            Write-Verbose "Bucle de paginacion detectado en $nextUri. Deteniendo consulta."
            break
        }
        $seenUrls[$nextUri] = $true
        $pageCount++

        try {
            $response = Invoke-GraphRequestWithRetry -Uri $nextUri
            if ($response -and $response.value) {
                foreach ($val in $response.value) {
                    $results.Add($val)
                }
            }

            $nextUri = $null
            if ($response) {
                $nextUri = $response | Select-Object -ExpandProperty '@odata.nextLink' -ErrorAction SilentlyContinue
            }

            if ($nextUri) {
                if ($nextUri -match "^https://[^/]+/(v1\.0|beta)/(.*)$") {
                    $nextUri = "$($Matches[1])/$($Matches[2])"
                }
            }

            if ($MaxPages -gt 0 -and $pageCount -ge $MaxPages) {
                Write-Verbose "Alcanzado limite maximo de paginas ($MaxPages)."
                break
            }
        } catch {
            Write-Verbose "Error en consulta paginada a $nextUri : $($_.Exception.Message)"
            break
        }
    }
    return $results
}

# Cache de token para SharePoint REST
$script:spAccessToken = $null

function Get-SharePointDirectToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$TenantHost
    )
    if ($script:spAccessToken) { return $script:spAccessToken }
    if (-not $TenantId -or -not $ClientId -or -not $ClientSecret -or -not $TenantHost) { return $null }

    $secPlain = if ($ClientSecret -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new("", $ClientSecret).Password
    } else {
        [string]$ClientSecret
    }

    # Intento 1: OAuth2 v2.0 (scope .default)
    try {
        $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $body = @{
            client_id     = $ClientId
            client_secret = $secPlain
            scope         = "https://${TenantHost}/.default"
            grant_type    = "client_credentials"
        }
        $resp = Invoke-RestMethod -Uri $tokenUri -Method POST -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        if ($resp -and $resp.access_token) {
            $script:spAccessToken = $resp.access_token
            return $script:spAccessToken
        }
    } catch {
        Write-Verbose "OAuth v2 fallo para SharePoint: $($_.Exception.Message)"
    }

    # Intento 2: OAuth v1.0 legacy (resource)
    try {
        $tokenUri1 = "https://login.microsoftonline.com/$TenantId/oauth2/token"
        $body1 = @{
            client_id     = $ClientId
            client_secret = $secPlain
            resource      = "https://${TenantHost}"
            grant_type    = "client_credentials"
        }
        $resp1 = Invoke-RestMethod -Uri $tokenUri1 -Method POST -Body $body1 -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        if ($resp1 -and $resp1.access_token) {
            $script:spAccessToken = $resp1.access_token
            return $script:spAccessToken
        }
    } catch {
        Write-Verbose "OAuth v1 fallo para SharePoint: $($_.Exception.Message)"
    }

    return $null
}

function Get-GraphSiteByUrl {
    param(
        [string]$UrlOrPath,
        [string]$TenantHost
    )
    if ([string]::IsNullOrWhiteSpace($UrlOrPath)) { return $null }

    $cleanInput = $UrlOrPath.Trim().Trim('"').Trim("'")
    $targetHost = if ($TenantHost) { $TenantHost } else { "" }
    $relPath = ""

    if ($cleanInput -match "^https?://([^/]+)(/.*)?$") {
        $targetHost = $Matches[1]
        $relPath = if ($Matches[2]) { $Matches[2].TrimEnd('/') } else { "" }
    } else {
        $rawPath = $cleanInput.TrimEnd('/')
        if ($rawPath.StartsWith("/")) {
            $relPath = $rawPath
        } else {
            $relPath = "/sites/$rawPath"
        }
    }

    $possibleUris = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($relPath) -or $relPath -eq "/") {
        if ($targetHost) { $possibleUris.Add("v1.0/sites/${targetHost}:/") }
        if ($TenantHost -and $TenantHost -ne $targetHost) { $possibleUris.Add("v1.0/sites/${TenantHost}:/") }
    } else {
        if ($targetHost) {
            $possibleUris.Add("v1.0/sites/${targetHost}:${relPath}")
            $possibleUris.Add("v1.0/sites/${targetHost}:${relPath}:")
        }
        if ($TenantHost -and $TenantHost -ne $targetHost) {
            $possibleUris.Add("v1.0/sites/${TenantHost}:${relPath}")
            $possibleUris.Add("v1.0/sites/${TenantHost}:${relPath}:")
        }
        
        $decodedPath = [System.Uri]::UnescapeDataString($relPath)
        if ($decodedPath -ne $relPath) {
            if ($targetHost) {
                $possibleUris.Add("v1.0/sites/${targetHost}:${decodedPath}")
                $possibleUris.Add("v1.0/sites/${targetHost}:${decodedPath}:")
            }
        }
    }

    foreach ($gUri in ($possibleUris | Select-Object -Unique)) {
        try {
            $siteObj = Invoke-GraphRequestWithRetry -Uri $gUri
            if ($siteObj -and ($siteObj.id -or $siteObj.webUrl)) {
                return $siteObj
            }
        } catch {
            Write-Verbose "No se pudo resolver sitio en $gUri : $($_.Exception.Message)"
        }
    }

    try {
        $searchTerm = if ($relPath) { ($relPath -split '/')[-1] } else { $cleanInput }
        if ($searchTerm) {
            $searchResults = Invoke-GraphPaginatedRequest -Uri "v1.0/sites?search=$searchTerm"
            foreach ($s in $searchResults) {
                $sWebUrl = if ($s.webUrl) { $s.webUrl } else { $s.WebUrl }
                if ($sWebUrl -and ($sWebUrl.TrimEnd('/').ToLower() -eq $cleanInput.TrimEnd('/').ToLower() -or $sWebUrl -like "*$searchTerm*")) {
                    return $s
                }
            }
        }
    } catch {
        Write-Verbose "Fallo busqueda por nombre para '$searchTerm': $($_.Exception.Message)"
    }

    return $null
}

function Get-DriveItemsRecursive {
    param(
        [string]$SiteId,
        [string]$DriveId,
        [string]$ItemId = "root",
        [int]$CurrentDepth = 0,
        [int]$MaxDepth = 15
    )
    $res = [System.Collections.Generic.List[PSObject]]::new()
    if ($CurrentDepth -ge $MaxDepth) {
        Write-Verbose "Alcanzada profundidad maxima de recursion ($MaxDepth) en DriveId: $DriveId"
        return $res
    }

    try {
        $chUri = if ($ItemId -eq "root") { 
            "v1.0/sites/$SiteId/drives/$DriveId/root/children" 
        } else { 
            "v1.0/sites/$SiteId/drives/$DriveId/items/$ItemId/children" 
        }
        $children = Invoke-GraphPaginatedRequest -Uri $chUri
        foreach ($c in $children) {
            $res.Add($c)
            if ($c.folder -and $c.folder.childCount -gt 0) {
                $sub = Get-DriveItemsRecursive -SiteId $SiteId -DriveId $DriveId -ItemId $c.id -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth
                foreach ($sItem in $sub) { $res.Add($sItem) }
            }
        }
    } catch {
        Write-Verbose "Error recorriendo drive recursivo (ItemId $ItemId): $($_.Exception.Message)"
    }
    return $res
}

# =========================================================================
# SECCION 3: FUNCIONES DE EXTRACCION DE DATOS DE ALMACENAMIENTO
# =========================================================================

function Get-SiteRecycleBinItems {
    param(
        [string]$SiteId,
        [string]$SiteWebUrl,
        [string]$TenantHost,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    $results = [System.Collections.Generic.List[PSObject]]::new()
    $seenMap = @{}

    # Metodo A: SharePoint REST API (/_api/web/recyclebin y /_api/site/recyclebin)
    $spToken = Get-SharePointDirectToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -TenantHost $TenantHost
    if ($spToken -and $SiteWebUrl) {
        $headers = @{
            "Authorization" = "Bearer $spToken"
            "Accept"        = "application/json;odata=verbose"
        }

        $restUrls = @(
            "$($SiteWebUrl.TrimEnd('/'))/_api/web/recyclebin?`$top=5000",
            "$($SiteWebUrl.TrimEnd('/'))/_api/site/recyclebin?`$top=5000"
        )

        foreach ($rUrl in $restUrls) {
            try {
                $restResp = Invoke-RestMethod -Uri $rUrl -Method GET -Headers $headers -ErrorAction Stop
                $entries = $null
                if ($restResp -and $restResp.d -and $restResp.d.results) {
                    $entries = $restResp.d.results
                } elseif ($restResp -and $restResp.value) {
                    $entries = $restResp.value
                }

                if ($entries) {
                    foreach ($e in $entries) {
                        $eId = if ($e.Id) { $e.Id } else { "$($e.LeafName)_$($e.Size)" }
                        if (-not $seenMap.ContainsKey($eId.ToString())) {
                            $seenMap[$eId.ToString()] = $true
                            
                            $itemName = if ($e.LeafName) { $e.LeafName } elseif ($e.Title) { $e.Title } else { "Archivo eliminado" }
                            $itemSize = if ($null -ne $e.Size) { [double]$e.Size } else { 0 }
                            $deletedDate = if ($e.DeletedDate) { [datetime]$e.DeletedDate } else { $null }
                            $origLoc = if ($e.DirName) { $e.DirName } else { "/" }
                            $delUser = if ($e.DeletedByName) { $e.DeletedByName } elseif ($e.AuthorName) { $e.AuthorName } else { "Desconocido" }

                            $results.Add([PSCustomObject]@{
                                name                = $itemName
                                size                = $itemSize
                                deletedDateTime     = $deletedDate
                                deletedFromLocation = $origLoc
                                deletedBy           = @{ user = @{ displayName = $delUser } }
                                webUrl              = "$($SiteWebUrl.TrimEnd('/'))/$origLoc/$itemName"
                            })
                        }
                    }
                }
            } catch {
                Write-Verbose "SharePoint REST no disponible en $rUrl : $($_.Exception.Message)"
            }
        }
    }

    # Metodo B: Microsoft Graph API (/recycleBin/items)
    $canonicalId = $SiteId
    if (-not $canonicalId -or $canonicalId -like "*:*" -or $canonicalId -notmatch "^[^,]+,[^,]+,[^,]+$") {
        $resolved = Get-GraphSiteByUrl -UrlOrPath $(if ($SiteWebUrl) { $SiteWebUrl } else { $SiteId }) -TenantHost $TenantHost
        if ($resolved -and $resolved.id) {
            $canonicalId = $resolved.id
        }
    }

    $urisToTry = [System.Collections.Generic.List[string]]::new()
    if ($canonicalId -and $canonicalId -match "^[^,]+,[^,]+,[^,]+$") {
        $urisToTry.Add("beta/sites/$canonicalId/recycleBin/items?`$top=999")
        $urisToTry.Add("v1.0/sites/$canonicalId/recycleBin/items?`$top=999")
    }

    if ($SiteWebUrl -match "https?://[^/]+(/.*)") {
        $rel = $Matches[1].TrimEnd('/')
        $urisToTry.Add("beta/sites/${TenantHost}:${rel}:/recycleBin/items?`$top=999")
        $urisToTry.Add("v1.0/sites/${TenantHost}:${rel}:/recycleBin/items?`$top=999")
    }

    foreach ($uri in ($urisToTry | Select-Object -Unique)) {
        try {
            $items = Invoke-GraphPaginatedRequest -Uri $uri
            if ($items -and $items.Count -gt 0) {
                foreach ($it in $items) {
                    $itId = if ($it.id) { $it.id } else { $it.name }
                    if (-not $seenMap.ContainsKey($itId.ToString())) {
                        $seenMap[$itId.ToString()] = $true
                        $results.Add($it)
                    }
                }
            }
        } catch {
            Write-Verbose "Fallo Graph en $uri : $($_.Exception.Message)"
        }
    }

    return $results
}

function Get-SiteLibraryVersionSettings {
    param(
        [string]$SiteId,
        [string]$SiteWebUrl,
        [string]$TenantHost,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    $results = [System.Collections.Generic.List[PSObject]]::new()

    $spToken = Get-SharePointDirectToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -TenantHost $TenantHost
    if ($spToken -and $SiteWebUrl) {
        $headers = @{
            "Authorization" = "Bearer $spToken"
            "Accept"        = "application/json;odata=verbose"
        }
        $restUrl = "$($SiteWebUrl.TrimEnd('/'))/_api/web/lists?`$filter=BaseTemplate eq 101 and Hidden eq false&`$select=Title,EnableVersioning,MajorVersionLimit,EnableMinorVersions,MajorWithMinorVersionsLimit,ItemCount"
        try {
            $resp = Invoke-RestMethod -Uri $restUrl -Method GET -Headers $headers -ErrorAction Stop
            $items = $null
            if ($resp -and $resp.d -and $resp.d.results) {
                $items = $resp.d.results
            } elseif ($resp -and $resp.value) {
                $items = $resp.value
            }
            if ($items) {
                foreach ($lib in $items) {
                    if ($lib.Title -eq "PreservationHoldLibrary" -or $lib.Title -like "*Preservation Hold*") { continue }
                    $results.Add([PSCustomObject]@{
                        LibraryTitle                 = $lib.Title
                        EnableVersioning             = [bool]$lib.EnableVersioning
                        MajorVersionLimit            = if ($null -ne $lib.MajorVersionLimit -and [int]$lib.MajorVersionLimit -gt 0) { [int]$lib.MajorVersionLimit } else { 500 }
                        EnableMinorVersions          = [bool]$lib.EnableMinorVersions
                        MajorWithMinorVersionsLimit  = if ($null -ne $lib.MajorWithMinorVersionsLimit) { [int]$lib.MajorWithMinorVersionsLimit } else { 0 }
                        ItemCount                    = if ($null -ne $lib.ItemCount) { [int]$lib.ItemCount } else { 0 }
                        Source                       = "SharePoint REST"
                    })
                }
            }
        } catch {
            Write-Verbose "REST no disponible para versionado en $SiteWebUrl : $($_.Exception.Message)"
        }
    }

    if ($results.Count -eq 0 -and $SiteId) {
        try {
            $drives = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$SiteId/drives"
            foreach ($drv in $drives) {
                $drvName = if ($drv.name) { $drv.name } else { "Documentos" }
                if ($drvName -eq "PreservationHoldLibrary" -or $drvName -like "*Preservation Hold*") { continue }
                $results.Add([PSCustomObject]@{
                    LibraryTitle                 = $drvName
                    EnableVersioning             = $true
                    MajorVersionLimit            = 500
                    EnableMinorVersions          = $false
                    MajorWithMinorVersionsLimit  = 0
                    ItemCount                    = 0
                    Source                       = "Predeterminado M365"
                })
            }
        } catch {
            Write-Verbose "Error consultando drives para versionado: $($_.Exception.Message)"
        }
    }

    if ($results.Count -eq 0) {
        $results.Add([PSCustomObject]@{
            LibraryTitle                 = "Documentos"
            EnableVersioning             = $true
            MajorVersionLimit            = 500
            EnableMinorVersions          = $false
            MajorWithMinorVersionsLimit  = 0
            ItemCount                    = 0
            Source                       = "Predeterminado M365"
        })
    }

    return $results
}

# =========================================================================
# SECCION 4: GENERACION DE REPORTES (HTML INTERACTIVO Y CSV)
# =========================================================================

function Export-UnifiedReportToHtml {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$FilesData,
        [System.Collections.Generic.List[PSCustomObject]]$SitesSummaryData,
        [System.Collections.Generic.List[PSCustomObject]]$FoldersSummaryData,
        [System.Collections.Generic.List[PSCustomObject]]$LibraryVersionData,
        [System.Collections.Generic.List[PSCustomObject]]$FailedSitesData,
        [string]$FilePath,
        [string]$UserAccount,
        [string]$AuditedSiteFilter,
        [string]$ElapsedTime
    )

    $grandPreservationBytes = 0
    $grandRecycleBinBytes = 0
    $grandVersionHistoryBytes = 0
    foreach ($s in $SitesSummaryData) {
        $grandPreservationBytes += $s.PreservationSizeBytes
        $grandRecycleBinBytes += $s.RecycleBinSizeBytes
        $grandVersionHistoryBytes += $s.VersionHistorySizeBytes
    }
    $grandTotalNonProductiveBytes = $grandPreservationBytes + $grandRecycleBinBytes + $grandVersionHistoryBytes
    
    $grandTotalFormatted = Format-FileSize -Bytes $grandTotalNonProductiveBytes
    $grandPreservationFormatted = Format-FileSize -Bytes $grandPreservationBytes
    $grandRecycleBinFormatted = Format-FileSize -Bytes $grandRecycleBinBytes
    $grandVersionHistoryFormatted = Format-FileSize -Bytes $grandVersionHistoryBytes

    $totalPreservationFiles = ($FilesData | Where-Object { $_.SourceType -eq "PreservationHoldLibrary" }).Count
    $totalRecycleBinItems = ($FilesData | Where-Object { $_.SourceType -eq "Papelera de reciclaje" }).Count
    $totalVersionFiles = ($FilesData | Where-Object { $_.SourceType -eq "Historial de versiones" }).Count
    $totalUnifiedFilesCount = $FilesData.Count
    $totalFoldersCount = $FoldersSummaryData.Count
    $totalLibVersionCount = if ($LibraryVersionData) { $LibraryVersionData.Count } else { 0 }
    $sitesWithHoldCount = ($SitesSummaryData | Where-Object { $_.HasPreservationHold -eq $true }).Count
    $totalAuditedSites = $SitesSummaryData.Count
    $totalFailedSites = if ($FailedSitesData) { $FailedSitesData.Count } else { 0 }

    $topLargestFiles = $FilesData | Sort-Object -Property SizeBytes -Descending | Select-Object -First 30
    $largestSingleFile = if ($topLargestFiles.Count -gt 0) { $topLargestFiles[0].SizeFormatted } else { "0 B" }

    $siteRowsHtml = [System.Text.StringBuilder]::new()
    foreach ($st in ($SitesSummaryData | Sort-Object -Property TotalNonProductiveBytes -Descending)) {
        $stTitleEsc = [System.Net.WebUtility]::HtmlEncode($st.SiteTitle)
        $stUrlEsc = [System.Net.WebUtility]::HtmlEncode($st.SiteUrl)
        $hasHoldBadge = if ($st.HasPreservationHold) {
            "<span class='badge badge-hold-active'>Retencion Activa</span>"
        } else {
            "<span class='badge badge-hold-none'>Sin Retencion</span>"
        }

        $pct = if ($grandTotalNonProductiveBytes -gt 0) { [math]::Round(($st.TotalNonProductiveBytes / $grandTotalNonProductiveBytes) * 100, 1) } else { 0 }

        [void]$siteRowsHtml.AppendLine("
        <tr>
            <td>
                <div class='site-title-cell'>
                    <span class='site-icon-ph'>
                        <svg width='16' height='16' viewBox='0 0 20 20' fill='currentColor'>
                            <path fill-rule='evenodd' d='M4 4a2 2 0 012-2h8a2 2 0 012 2v12a2 2 0 01-2 2H6a2 2 0 01-2-2V4zm3 1a1 1 0 000 2h6a1 1 0 100-2H7zm0 4a1 1 0 000 2h6a1 1 0 100-2H7zm0 4a1 1 0 100 2h4a1 1 0 100-2H7z' clip-rule='evenodd'/>
                        </svg>
                    </span>
                    <div>
                        <strong class='site-name'>$stTitleEsc</strong>
                        <a href='$stUrlEsc' target='_blank' rel='noopener noreferrer' class='site-link'>$stUrlEsc</a>
                    </div>
                </div>
            </td>
            <td>$hasHoldBadge</td>
            <td>
                <span class='badge badge-preservation'>$($st.PreservationFilesCount) archivos</span>
                <strong class='size-text'>$($st.PreservationSizeFormatted)</strong>
            </td>
            <td>
                <span class='badge badge-recycle'>$($st.RecycleBinCount) items</span>
                <strong class='size-text'>$($st.RecycleBinSizeFormatted)</strong>
            </td>
            <td>
                <span class='badge badge-versions'>$($st.VersionHistoryFilesCount) archivos</span>
                <strong class='size-text'>$($st.VersionHistorySizeFormatted)</strong>
            </td>
            <td>
                <span class='badge badge-generic'>$([System.Net.WebUtility]::HtmlEncode($st.VersionLimitConfigured))</span>
            </td>
            <td>
                <div class='storage-bar-wrapper'>
                    <div class='storage-bar-text'>
                        <strong class='size-text-large'>$($st.TotalNonProductiveFormatted)</strong>
                        <span class='pct-text'>($pct%)</span>
                    </div>
                    <div class='storage-progress'>
                        <div class='storage-progress-fill' style='width: $pct%;'></div>
                    </div>
                </div>
            </td>
            <td class='date-cell'>$($st.OldestDate)</td>
            <td class='date-cell'>$($st.NewestDate)</td>
        </tr>")
    }

    $folderRowsHtml = [System.Text.StringBuilder]::new()
    foreach ($fd in ($FoldersSummaryData | Sort-Object -Property SizeBytes -Descending)) {
        $fSiteEsc = [System.Net.WebUtility]::HtmlEncode($fd.SiteTitle)
        $fPathEsc = [System.Net.WebUtility]::HtmlEncode($fd.FolderPath)
        
        [void]$folderRowsHtml.AppendLine("
        <tr>
            <td><strong>$fSiteEsc</strong></td>
            <td>
                <div class='folder-path-cell'>
                    <svg width='14' height='14' viewBox='0 0 20 20' fill='currentColor' class='folder-icon'>
                        <path d='M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z'/>
                    </svg>
                    <span>$fPathEsc</span>
                </div>
            </td>
            <td><span class='badge badge-generic'>$($fd.FilesCount) archivos</span></td>
            <td><strong class='metric-highlight'>$($fd.SizeFormatted)</strong></td>
        </tr>")
    }

    $libVersionRowsHtml = [System.Text.StringBuilder]::new()
    if ($LibraryVersionData) {
        foreach ($lv in $LibraryVersionData) {
            $lvSiteEsc = [System.Net.WebUtility]::HtmlEncode($lv.SiteTitle)
            $lvLibEsc = [System.Net.WebUtility]::HtmlEncode($lv.LibraryTitle)
            $lvLimitEsc = [System.Net.WebUtility]::HtmlEncode("$($lv.MajorVersionLimit) versiones")
            $lvStatusBadge = if ($lv.EnableVersioning) {
                "<span class='badge badge-hold-none'>Habilitado</span>"
            } else {
                "<span class='badge badge-hold-active'>Deshabilitado</span>"
            }
            $lvCount = if ($lv.ItemCount -gt 0) { "$($lv.ItemCount) items" } else { "-" }
            $lvSourceEsc = [System.Net.WebUtility]::HtmlEncode($lv.Source)

            [void]$libVersionRowsHtml.AppendLine("
        <tr>
            <td><strong>$lvSiteEsc</strong></td>
            <td>$lvLibEsc</td>
            <td>$lvStatusBadge</td>
            <td><strong class='metric-highlight'>$lvLimitEsc</strong></td>
            <td>$lvCount</td>
            <td><span class='badge badge-generic'>$lvSourceEsc</span></td>
        </tr>")
        }
    }

    $versionRowsHtml = [System.Text.StringBuilder]::new()
    $versionFiles = $FilesData | Where-Object { $_.SourceType -eq "Historial de versiones" } | Sort-Object -Property SizeBytes -Descending
    foreach ($vf in $versionFiles) {
        $vfNameEsc = [System.Net.WebUtility]::HtmlEncode($vf.ItemName)
        $vfSiteEsc = [System.Net.WebUtility]::HtmlEncode($vf.SiteTitle)
        $vfPathEsc = [System.Net.WebUtility]::HtmlEncode($vf.LocationPath)
        $vfUrlEsc = [System.Net.WebUtility]::HtmlEncode($vf.WebUrl)
        $vfActionUserEsc = [System.Net.WebUtility]::HtmlEncode($vf.ActionByUser)

        [void]$versionRowsHtml.AppendLine("
        <tr>
            <td><a href='$vfUrlEsc' target='_blank' rel='noopener noreferrer' class='file-title'>$vfNameEsc</a></td>
            <td>$vfSiteEsc</td>
            <td class='file-subtext'>$vfPathEsc</td>
            <td><strong class='metric-highlight-large'>$($vf.SizeFormatted)</strong></td>
            <td class='date-cell'>$($vf.DeletedOrModifiedDate)</td>
            <td class='date-cell'>$vfActionUserEsc</td>
        </tr>")
    }

    $fileRowsHtml = [System.Text.StringBuilder]::new()
    foreach ($fl in $FilesData) {
        $flNameEsc = [System.Net.WebUtility]::HtmlEncode($fl.ItemName)
        $flSiteEsc = [System.Net.WebUtility]::HtmlEncode($fl.SiteTitle)
        $flPathEsc = [System.Net.WebUtility]::HtmlEncode($fl.LocationPath)
        $flExtEsc = [System.Net.WebUtility]::HtmlEncode($fl.Extension)
        $flActionUserEsc = [System.Net.WebUtility]::HtmlEncode($fl.ActionByUser)
        $flUrlEsc = [System.Net.WebUtility]::HtmlEncode($fl.WebUrl)

        $srcBadge = if ($fl.SourceType -eq "PreservationHoldLibrary") {
            "<span class='badge badge-preservation'>PreservationHold</span>"
        } elseif ($fl.SourceType -eq "Historial de versiones") {
            "<span class='badge badge-versions'>Versiones</span>"
        } else {
            "<span class='badge badge-recycle'>Papelera de reciclaje</span>"
        }

        $extBadgeClass = switch -Regex ($fl.Extension) {
            "\.docx?|\.rtf"      { "badge-ext-word" }
            "\.xlsx?|\.csv"      { "badge-ext-excel" }
            "\.pptx?|\.pdf"      { "badge-ext-pdf" }
            "\.zip|\.rar|\.7z"   { "badge-ext-zip" }
            "\.png|\.jpg|\.jpeg" { "badge-ext-img" }
            default              { "badge-ext-other" }
        }

        [void]$fileRowsHtml.AppendLine("
        <tr data-source='$($fl.SourceType)'>
            <td>$srcBadge</td>
            <td>
                <div class='file-cell'>
                    <span class='badge $extBadgeClass'>$flExtEsc</span>
                    <div class='file-info'>
                        <a href='$flUrlEsc' target='_blank' rel='noopener noreferrer' class='file-title'>$flNameEsc</a>
                        <span class='file-subtext'>$flPathEsc</span>
                    </div>
                </div>
            </td>
            <td>$flSiteEsc</td>
            <td><strong class='size-text'>$($fl.SizeFormatted)</strong></td>
            <td class='date-cell'>$($fl.DeletedOrModifiedDate)</td>
            <td class='author-cell'>$flActionUserEsc</td>
        </tr>")
    }

    $topRowsHtml = [System.Text.StringBuilder]::new()
    $rank = 1
    foreach ($tf in $topLargestFiles) {
        $tfNameEsc = [System.Net.WebUtility]::HtmlEncode($tf.ItemName)
        $tfSiteEsc = [System.Net.WebUtility]::HtmlEncode($tf.SiteTitle)
        $tfPathEsc = [System.Net.WebUtility]::HtmlEncode($tf.LocationPath)
        $tfUrlEsc = [System.Net.WebUtility]::HtmlEncode($tf.WebUrl)
        $tfUserEsc = [System.Net.WebUtility]::HtmlEncode($tf.ActionByUser)

        $srcBadge = if ($tf.SourceType -eq "PreservationHoldLibrary") {
            "<span class='badge badge-preservation'>PreservationHold</span>"
        } elseif ($tf.SourceType -eq "Historial de versiones") {
            "<span class='badge badge-versions'>Versiones</span>"
        } else {
            "<span class='badge badge-recycle'>Papelera</span>"
        }

        [void]$topRowsHtml.AppendLine("
        <tr>
            <td class='rank-cell'><span class='rank-number'>#$rank</span></td>
            <td>$srcBadge</td>
            <td>
                <div class='file-cell'>
                    <div class='file-info'>
                        <a href='$tfUrlEsc' target='_blank' rel='noopener noreferrer' class='file-title'>$tfNameEsc</a>
                        <span class='file-subtext'>$tfPathEsc</span>
                    </div>
                </div>
            </td>
            <td>$tfSiteEsc</td>
            <td><strong class='metric-highlight-large'>$($tf.SizeFormatted)</strong></td>
            <td class='date-cell'>$($tf.DeletedOrModifiedDate)</td>
            <td class='author-cell'>$tfUserEsc</td>
        </tr>")
        $rank++
    }

    $failedRowsHtml = [System.Text.StringBuilder]::new()
    if ($FailedSitesData -and $FailedSitesData.Count -gt 0) {
        foreach ($fs in $FailedSitesData) {
            $fsTitleEsc = [System.Net.WebUtility]::HtmlEncode($fs.SiteTitle)
            $fsUrlEsc = [System.Net.WebUtility]::HtmlEncode($fs.SiteUrl)
            $fsErrEsc = [System.Net.WebUtility]::HtmlEncode($fs.ErrorMessage)
            $fsDateEsc = [System.Net.WebUtility]::HtmlEncode($fs.Timestamp)

            [void]$failedRowsHtml.AppendLine("
        <tr>
            <td><strong>$fsTitleEsc</strong></td>
            <td><a href='$fsUrlEsc' target='_blank' rel='noopener noreferrer' class='site-link'>$fsUrlEsc</a></td>
            <td><span class='badge badge-hold-active'>Incidencia</span></td>
            <td><span style='color: #d13438;'>$fsErrEsc</span></td>
            <td class='date-cell'>$fsDateEsc</td>
        </tr>")
        }
    }

    $dateNowStr = (Get-SpainDate).ToString("yyyy-MM-dd HH:mm:ss")
    $userAccountEsc = [System.Net.WebUtility]::HtmlEncode($UserAccount)
    $auditedSiteFilterEsc = [System.Net.WebUtility]::HtmlEncode($AuditedSiteFilter)

    $failedTabButton = if ($totalFailedSites -gt 0) {
        "<button class='tab-btn' onclick=`"switchView('failed', event)`" style='color: #d13438;'>Incidencias ($totalFailedSites)</button>"
    } else { "" }

    $failedSectionHtml = ""
    if ($totalFailedSites -gt 0) {
        $sbFailed = [System.Text.StringBuilder]::new()
        [void]$sbFailed.AppendLine('<div id="failedView" class="view-section" style="display: none;">')
        [void]$sbFailed.AppendLine("<div class=`"section-title`" style=`"border-left-color: #d13438;`">Sitios con incidencias registradas ($totalFailedSites)</div>")
        [void]$sbFailed.AppendLine('<div class="site-card"><div class="table-container"><table id="failedTable">')
        [void]$sbFailed.AppendLine('<thead><tr><th>Sitio de SharePoint</th><th>URL</th><th>Estado</th><th>Detalle del error</th><th>Fecha y hora</th></tr></thead>')
        [void]$sbFailed.AppendLine("<tbody>$($failedRowsHtml.ToString())</tbody></table></div></div></div>")
        $failedSectionHtml = $sbFailed.ToString()
    }

    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Auditoría de almacenamiento retenido y papelera - Microsoft 365</title>
    <style>
        :root {
            --sp-brand: #03787c;
            --sp-brand-hover: #025c5f;
            --sp-brand-light: #e6f2f3;
            --purview-purple: #5c2d91;
            --m365-blue: #0078d4;
            --m365-suite-bg: #0078d4;
            
            --bg-main: #faf9f8;
            --bg-card: #ffffff;
            --bg-site-header: #f3f2f1;
            --bg-table-header: #faf9f8;
            --bg-table-hover: #f3f2f1;
            --bg-input: #ffffff;
            --bg-progress-track: #edebe9;
            
            --text-primary: #201f1e;
            --text-secondary: #605e5c;
            --text-heading: #11100f;
            --text-link: #0078d4;
            
            --border-color: #edebe9;
            --border-subtle: #e1dfdd;
            
            --shadow-card: 0 1.6px 3.6px 0 rgba(0,0,0,0.132), 0 0.3px 0.9px 0 rgba(0,0,0,0.108);

            --badge-active-bg: #fde8e8; --badge-active-txt: #a80000; --badge-active-border: #f8c2c2;
            --badge-none-bg: #dff6dd; --badge-none-txt: #107c41; --badge-none-border: #92e08f;
            --badge-generic-bg: #f3f2f1; --badge-generic-txt: #605e5c; --badge-generic-border: #e1dfdd;
            
            --badge-pres-bg: #f3e8ff; --badge-pres-txt: #5c2d91; --badge-pres-border: #d8b4fe;
            --badge-rec-bg: #fff4ce; --badge-rec-txt: #8a3b00; --badge-rec-border: #fed7aa;
            --badge-ver-bg: #e0f2f1; --badge-ver-txt: #00695c; --badge-ver-border: #80cbc4;

            --badge-word-bg: #deecf9; --badge-word-txt: #005a9e;
            --badge-excel-bg: #dff6dd; --badge-excel-txt: #107c41;
            --badge-pdf-bg: #fde8e8; --badge-pdf-txt: #d13438;
            --badge-zip-bg: #fff4ce; --badge-zip-txt: #8a3b00;
            --badge-img-bg: #f3e8ff; --badge-img-txt: #5c2d91;
            --badge-other-bg: #f3f2f1; --badge-other-txt: #605e5c;
        }

        [data-theme="dark"] {
            --sp-brand: #00a8ac;
            --sp-brand-hover: #00c7cb;
            --sp-brand-light: #163638;
            --purview-purple: #a879e6;
            --m365-blue: #2899f5;
            --m365-suite-bg: #0f172a;
            
            --bg-main: #11100f;
            --bg-card: #1b1a19;
            --bg-site-header: #252423;
            --bg-table-header: #1b1a19;
            --bg-table-hover: #292827;
            --bg-input: #252423;
            --bg-progress-track: #323130;
            
            --text-primary: #f3f2f1;
            --text-secondary: #a19f9d;
            --text-heading: #ffffff;
            --text-link: #2899f5;
            
            --border-color: #292827;
            --border-subtle: #323130;
            
            --shadow-card: 0 2px 8px rgba(0, 0, 0, 0.4);

            --badge-active-bg: rgba(209, 52, 56, 0.25); --badge-active-txt: #f87171; --badge-active-border: rgba(209, 52, 56, 0.5);
            --badge-none-bg: rgba(16, 124, 65, 0.25); --badge-none-txt: #4ade80; --badge-none-border: rgba(16, 124, 65, 0.5);
            --badge-generic-bg: rgba(161, 159, 157, 0.2); --badge-generic-txt: #d2d0ce; --badge-generic-border: rgba(161, 159, 157, 0.4);
            
            --badge-pres-bg: rgba(92, 45, 145, 0.3); --badge-pres-txt: #c084fc; --badge-pres-border: rgba(168, 85, 247, 0.4);
            --badge-rec-bg: rgba(217, 119, 6, 0.3); --badge-rec-txt: #fbbf24; --badge-rec-border: rgba(251, 191, 36, 0.4);
            --badge-ver-bg: rgba(0, 105, 92, 0.3); --badge-ver-txt: #4db6ac; --badge-ver-border: rgba(77, 182, 172, 0.4);

            --badge-word-bg: rgba(0, 90, 158, 0.25); --badge-word-txt: #6cb8f6;
            --badge-excel-bg: rgba(16, 124, 65, 0.25); --badge-excel-txt: #4ade80;
            --badge-pdf-bg: rgba(209, 52, 56, 0.25); --badge-pdf-txt: #f87171;
            --badge-zip-bg: rgba(217, 119, 6, 0.25); --badge-zip-txt: #fbbf24;
            --badge-img-bg: rgba(180, 0, 158, 0.25); --badge-img-txt: #e37bee;
            --badge-other-bg: rgba(161, 159, 157, 0.2); --badge-other-txt: #d2d0ce;
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
        .suite-title { font-weight: 700; font-size: 1.05rem; }
        .suite-subtitle { opacity: 0.85; font-size: 0.88rem; }
        .suite-right { display: flex; align-items: center; gap: 18px; font-size: 0.82rem; }
        .suite-meta-item { display: flex; gap: 6px; }
        .meta-label { opacity: 0.75; }
        .meta-value { font-weight: 600; }
        .suite-meta-badge { background: rgba(255,255,255,0.18); padding: 3px 10px; border-radius: 12px; font-weight: 600; }

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

        .ms-message-bar {
            background: var(--bg-card);
            border: 1px solid var(--border-subtle);
            border-left: 4px solid #d83b01;
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
        .ms-message-bar svg { color: #d83b01; flex-shrink: 0; }

        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
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
            top: 0;
            left: 0;
            width: 4px;
            height: 100%;
        }
        .card-total::before { background-color: #d13438; }
        .card-preservation::before { background-color: #5c2d91; }
        .card-recycle::before { background-color: #d97706; }
        .card-versions::before { background-color: #0078d4; }
        .card-sites::before { background-color: var(--sp-brand); }
        .card-largest::before { background-color: #8b5cf6; }

        .metric-card .title { font-size: 0.78rem; color: var(--text-secondary); font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
        .metric-card .value { font-size: 1.85rem; font-weight: 700; color: var(--text-heading); margin-top: 4px; line-height: 1.2; }
        .metric-card .subtext { font-size: 0.78rem; color: var(--text-secondary); margin-top: 4px; }

        .toolbar {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            padding: 12px 18px;
            margin-bottom: 24px;
            display: flex;
            gap: 16px;
            align-items: center;
            justify-content: space-between;
            flex-wrap: wrap;
            box-shadow: var(--shadow-card);
        }
        .filter-tabs { display: flex; gap: 4px; flex-wrap: wrap; }
        .tab-btn {
            background: transparent;
            color: var(--text-secondary);
            border: none;
            border-bottom: 2px solid transparent;
            padding: 8px 14px;
            font-size: 0.88rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.15s ease;
        }
        .tab-btn:hover { color: var(--sp-brand); background: var(--bg-site-header); }
        .tab-btn.active { color: var(--sp-brand); border-bottom: 2px solid var(--sp-brand); }

        .toolbar-controls {
            display: flex;
            gap: 12px;
            align-items: center;
            flex: 1;
            justify-content: flex-end;
            min-width: 280px;
        }
        .search-box {
            position: relative;
            flex: 1;
            min-width: 200px;
            max-width: 380px;
            display: flex;
            align-items: center;
        }
        .search-icon { position: absolute; left: 12px; color: var(--text-secondary); pointer-events: none; }
        .search-box input {
            width: 100%;
            padding: 8px 12px 8px 34px;
            background: var(--bg-input);
            border: 1px solid var(--border-subtle);
            border-radius: 2px;
            color: var(--text-primary);
            font-size: 0.88rem;
            outline: none;
        }
        .search-box input:focus { border-color: var(--sp-brand); box-shadow: 0 0 0 1px var(--sp-brand); }

        .btn-action {
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
        .btn-action:hover { border-color: var(--sp-brand); color: var(--sp-brand); background: var(--bg-site-header); }

        .site-card {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            margin-bottom: 20px;
            overflow: hidden;
            box-shadow: var(--shadow-card);
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
        .badge-hold-active { background: var(--badge-active-bg); color: var(--badge-active-txt); border: 1px solid var(--badge-active-border); }
        .badge-hold-none { background: var(--badge-none-bg); color: var(--badge-none-txt); border: 1px solid var(--badge-none-border); }
        .badge-generic { background: var(--badge-generic-bg); color: var(--badge-generic-txt); border: 1px solid var(--badge-generic-border); }

        .badge-preservation { background: var(--badge-pres-bg); color: var(--badge-pres-txt); border: 1px solid var(--badge-pres-border); }
        .badge-recycle { background: var(--badge-rec-bg); color: var(--badge-rec-txt); border: 1px solid var(--badge-rec-border); }
        .badge-versions { background: var(--badge-ver-bg); color: var(--badge-ver-txt); border: 1px solid var(--badge-ver-border); }

        .badge-ext-word { background: var(--badge-word-bg); color: var(--badge-word-txt); }
        .badge-ext-excel { background: var(--badge-excel-bg); color: var(--badge-excel-txt); }
        .badge-ext-pdf { background: var(--badge-pdf-bg); color: var(--badge-pdf-txt); }
        .badge-ext-zip { background: var(--badge-zip-bg); color: var(--badge-zip-txt); }
        .badge-ext-img { background: var(--badge-img-bg); color: var(--badge-img-txt); }
        .badge-ext-other { background: var(--badge-other-bg); color: var(--badge-other-txt); }

        .storage-bar-wrapper { min-width: 140px; }
        .storage-bar-text { display: flex; justify-content: space-between; font-size: 0.8rem; margin-bottom: 3px; }
        .size-text { font-weight: 600; color: var(--text-heading); margin-left: 6px; }
        .size-text-large { font-weight: 700; color: #d13438; }
        .pct-text { font-size: 0.75rem; color: var(--text-secondary); }
        .storage-progress {
            width: 100%;
            height: 6px;
            background-color: var(--bg-progress-track);
            border-radius: 3px;
            overflow: hidden;
        }
        .storage-progress-fill {
            height: 100%;
            background-color: #d13438;
            border-radius: 3px;
        }

        .site-title-cell { display: flex; align-items: center; gap: 10px; }
        .site-icon-ph { color: var(--sp-brand); }
        .site-name { font-weight: 600; color: var(--text-heading); display: block; }
        .site-link { font-size: 0.75rem; color: var(--text-link); text-decoration: none; }
        .site-link:hover { text-decoration: underline; }

        .folder-path-cell { display: flex; align-items: center; gap: 8px; font-family: monospace; font-size: 0.85rem; }
        .folder-icon { color: #d97706; flex-shrink: 0; }

        .file-cell { display: flex; align-items: center; gap: 10px; }
        .file-info { display: flex; flex-direction: column; }
        .file-title { font-weight: 600; color: var(--text-link); text-decoration: none; word-break: break-all; }
        .file-title:hover { text-decoration: underline; }
        .file-subtext { font-size: 0.75rem; color: var(--text-secondary); }

        .metric-highlight { font-weight: 700; color: var(--text-heading); }
        .metric-highlight-large { font-size: 0.95rem; font-weight: 700; color: #d13438; }
        .date-cell { font-size: 0.8rem; color: var(--text-secondary); white-space: nowrap; }
        .author-cell { font-size: 0.8rem; color: var(--text-secondary); }
        .rank-cell { width: 50px; text-align: center; }
        .rank-number { font-weight: 700; color: var(--text-secondary); }

        .section-title {
            font-size: 1.15rem;
            font-weight: 600;
            color: var(--text-heading);
            margin-bottom: 14px;
            border-left: 4px solid var(--sp-brand);
            padding-left: 10px;
        }
        .view-section { margin-bottom: 32px; }

        .footer {
            margin-top: 40px;
            padding-top: 20px;
            border-top: 1px solid var(--border-color);
            text-align: center;
            font-size: 0.82rem;
            color: var(--text-secondary);
        }
    </style>
</head>
<body>
    <div class="m365-suite-bar">
        <div class="suite-left">
            <svg viewBox="0 0 20 20" width="20" height="20" fill="currentColor">
                <circle cx="4" cy="4" r="1.8"/><circle cx="10" cy="4" r="1.8"/><circle cx="16" cy="4" r="1.8"/>
                <circle cx="4" cy="10" r="1.8"/><circle cx="10" cy="10" r="1.8"/><circle cx="16" cy="10" r="1.8"/>
                <circle cx="4" cy="16" r="1.8"/><circle cx="10" cy="16" r="1.8"/><circle cx="16" cy="16" r="1.8"/>
            </svg>
            <span class="suite-title">SharePoint / Purview</span>
            <span class="suite-subtitle">| Almacenamiento retenido y papelera</span>
        </div>
        <div class="suite-right">
            <div class="suite-meta-item">
                <span class="meta-label">Autenticacion:</span>
                <span class="meta-value">$userAccountEsc</span>
            </div>
            <div class="suite-meta-item">
                <span class="meta-label">Fecha:</span>
                <span class="meta-value">$dateNowStr</span>
            </div>
            <div class="suite-meta-badge">
                &#9889; $ElapsedTime
            </div>
        </div>
    </div>

    <div class="container">
        <div class="page-header">
            <div>
                <h1>Auditoría de almacenamiento retenido y papelera de reciclaje</h1>
                <p>Análisis de espacio no productivo para <strong>$auditedSiteFilterEsc</strong></p>
            </div>
        </div>

        <div class="ms-message-bar">
            <svg width="20" height="20" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd"/>
            </svg>
            <div>
                <strong>Almacenamiento no productivo en SharePoint:</strong>
                <span>Consumo de cuota derivado de tres or&iacute;genes: <b>PreservationHoldLibrary</b> (archivos retenidos por directivas de Purview o litigios), <b>Papelera de reciclaje</b> (elementos eliminados en 1&ordf; y 2&ordf; etapa pendientes de purga) e <b>Historial de versiones</b> (acumulaci&oacute;n de versiones de documentos).</span>
            </div>
        </div>

        <div class="metrics-grid">
            <div class="metric-card card-total">
                <div class="title">Total no productivo (Retenci&#243;n + Papelera + Versiones)</div>
                <div class="value">$grandTotalFormatted</div>
                <div class="subtext">Cuota consumida total recuperable</div>
            </div>
            <div class="metric-card card-preservation">
                <div class="title">PreservationHoldLibrary</div>
                <div class="value">$grandPreservationFormatted</div>
                <div class="subtext">$totalPreservationFiles archivos retenidos</div>
            </div>
            <div class="metric-card card-recycle">
                <div class="title">Papelera de reciclaje</div>
                <div class="value">$grandRecycleBinFormatted</div>
                <div class="subtext">$totalRecycleBinItems items eliminados</div>
            </div>
            <div class="metric-card card-versions">
                <div class="title">Versiones antiguas</div>
                <div class="value">$grandVersionHistoryFormatted</div>
                <div class="subtext">$totalVersionFiles archivos con historial</div>
            </div>
            <div class="metric-card card-sites">
                <div class="title">Sitios analizados</div>
                <div class="value">$sitesWithHoldCount / $totalAuditedSites</div>
                <div class="subtext">Con retenci&#243;n activa $(if ($totalFailedSites -gt 0) { "($totalFailedSites incidencias)" })</div>
            </div>
            <div class="metric-card card-largest">
                <div class="title">Archivo m&#225;s pesado</div>
                <div class="value">$largestSingleFile</div>
                <div class="subtext">Mayor consumo individual</div>
            </div>
        </div>

        <div class="toolbar">
            <div class="filter-tabs">
                <button class="tab-btn active" onclick="switchView('sites', event)">Resumen por sitio ($totalAuditedSites)</button>
                <button class="tab-btn" onclick="switchView('folders', event)">Carpetas PreservationHold ($totalFoldersCount)</button>
                <button class="tab-btn" onclick="switchView('files', event)">Inventario completo ($totalUnifiedFilesCount)</button>
                <button class="tab-btn" onclick="switchView('versions', event)">Versiones antiguas ($totalVersionFiles)</button>
                <button class="tab-btn" onclick="switchView('libversions', event)">Config. versiones ($totalLibVersionCount)</button>
                <button class="tab-btn" onclick="switchView('top', event)">Top 30 m&#225;s pesados</button>
                $failedTabButton
            </div>
            <div class="toolbar-controls">
                <div class="search-box">
                    <svg class="search-icon" width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
                        <path fill-rule="evenodd" d="M11.742 10.344a6.5 6.5 0 1 0-1.397 1.398h-.001c.03.04.062.078.098.115l3.85 3.85a1 1 0 0 0 1.415-1.414l-3.85-3.85a1.007 1.007 0 0 0-.115-.1zM12 6.5a5.5 5.5 0 1 1-11 0 5.5 5.5 0 0 1 11 0z"/>
                    </svg>
                    <input type="text" id="globalSearch" placeholder="Buscar archivo, sitio, carpeta o autor..." onkeyup="filterTables()">
                </div>
                <button class="btn-action" onclick="exportHtmlTableToCsv('filesTable', 'Inventario_Retenido_y_Papelera.csv')" title="Descargar como CSV">
                    <span>Exportar CSV</span>
                </button>
                <button id="themeToggleBtn" class="btn-action" onclick="toggleTheme()" title="Cambiar tema">
                    <span id="themeText">Modo oscuro</span>
                </button>
            </div>
        </div>

        <div id="sitesView" class="view-section">
            <div class="section-title">Resumen de almacenamiento por sitio (PreservationHold vs. papelera vs. versiones)</div>
            <div class="site-card">
                <div class="table-container">
                    <table id="sitesTable">
                        <thead>
                            <tr>
                                <th>Sitio de SharePoint</th>
                                <th>Estado retenci&#243;n</th>
                                <th>PreservationHoldLibrary</th>
                                <th>Papelera de reciclaje</th>
                                <th>Versiones antiguas</th>
                                <th>L&#237;mite de versiones</th>
                                <th>Total no productivo</th>
                                <th>M&#225;s antiguo</th>
                                <th>M&#225;s reciente</th>
                            </tr>
                        </thead>
                        <tbody>
                            $($siteRowsHtml.ToString())
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <div id="foldersView" class="view-section" style="display: none;">
            <div class="section-title">Estructura y tamaño de carpetas en PreservationHoldLibrary</div>
            <div class="site-card">
                <div class="table-container">
                    <table id="foldersTable">
                        <thead>
                            <tr>
                                <th>Sitio de SharePoint</th>
                                <th>Ruta de carpeta en PreservationHold</th>
                                <th>N&#250;mero de archivos</th>
                                <th>Espacio ocupado</th>
                            </tr>
                        </thead>
                        <tbody>
                            $($folderRowsHtml.ToString())
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <div id="filesView" class="view-section" style="display: none;">
            <div class="section-title">Inventario detallado de elementos (PreservationHold, papelera y versiones)</div>
            <div class="site-card">
                <div class="table-container">
                    <table id="filesTable">
                        <thead>
                            <tr>
                                <th>Origen</th>
                                <th>Nombre del archivo / ruta</th>
                                <th>Sitio</th>
                                <th>Tamaño</th>
                                <th>&#218;ltima acci&#243;n / eliminaci&#243;n</th>
                                <th>Usuario responsable</th>
                            </tr>
                        </thead>
                        <tbody>
                            $($fileRowsHtml.ToString())
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <div id="versionsView" class="view-section" style="display: none;">
            <div class="section-title">Espacio ocupado por versiones antiguas de documentos (Version History)</div>
            <div class="site-card">
                <div class="table-container">
                    <table id="versionsTable">
                        <thead>
                            <tr>
                                <th>Archivo</th>
                                <th>Sitio de SharePoint</th>
                                <th>Ruta / biblioteca</th>
                                <th>Espacio versiones antiguas</th>
                                <th>&#218;ltima Modificaci&#243;n</th>
                                <th>N&#250;mero de versiones</th>
                            </tr>
                        </thead>
                        <tbody>
                            $($versionRowsHtml.ToString())
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <div id="libversionsView" class="view-section" style="display: none;">
            <div class="section-title">Configuraci&#243;n de l&#237;mite de versiones por sitio y biblioteca</div>
            <div class="site-card">
                <div class="table-container">
                    <table id="libversionsTable">
                        <thead>
                            <tr>
                                <th>Sitio de SharePoint</th>
                                <th>Biblioteca de documentos</th>
                                <th>Estado versionado</th>
                                <th>L&#237;mite versiones principales</th>
                                <th>Elementos</th>
                                <th>Origen detecci&#243;n</th>
                            </tr>
                        </thead>
                        <tbody>
                            $($libVersionRowsHtml.ToString())
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <div id="topView" class="view-section" style="display: none;">
            <div class="section-title">Top 30 archivos que m&#225;s espacio consumen en el tenant</div>
            <div class="site-card">
                <div class="table-container">
                    <table id="topTable">
                        <thead>
                            <tr>
                                <th>Rank</th>
                                <th>Origen</th>
                                <th>Nombre del archivo y ruta</th>
                                <th>Sitio de SharePoint</th>
                                <th>Tamaño</th>
                                <th>&#218;ltima modificaci&#243;n / borrado</th>
                                <th>Usuario</th>
                            </tr>
                        </thead>
                        <tbody>
                            $($topRowsHtml.ToString())
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        $failedSectionHtml

        <div class="footer">
            <p>Informe de auditoria de almacenamiento no productivo generado para Microsoft 365 SharePoint Online.</p>
        </div>
    </div>

    <script>
        function switchView(viewName, event) {
            document.querySelectorAll('.filter-tabs .tab-btn').forEach(btn => btn.classList.remove('active'));
            if (event && event.target) {
                event.target.classList.add('active');
            }

            const views = ['sitesView', 'foldersView', 'filesView', 'versionsView', 'libversionsView', 'topView', 'failedView'];
            views.forEach(v => {
                const el = document.getElementById(v);
                if (el) el.style.display = 'none';
            });

            const activeEl = document.getElementById(viewName + 'View');
            if (activeEl) activeEl.style.display = 'block';
        }

        function filterTables() {
            const query = document.getElementById('globalSearch').value.toLowerCase().trim();
            const tables = ['sitesTable', 'foldersTable', 'filesTable', 'versionsTable', 'libversionsTable', 'topTable', 'failedTable'];

            tables.forEach(tableId => {
                const table = document.getElementById(tableId);
                if (!table) return;
                const rows = table.querySelectorAll('tbody tr');
                rows.forEach(row => {
                    const text = row.innerText.toLowerCase();
                    row.style.display = text.includes(query) ? '' : 'none';
                });
            });
        }

        function toggleTheme() {
            const currentTheme = document.documentElement.getAttribute('data-theme');
            const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
            document.documentElement.setAttribute('data-theme', newTheme);
            const themeTxtEl = document.getElementById('themeText');
            if (themeTxtEl) {
                themeTxtEl.innerText = newTheme === 'dark' ? 'Modo claro' : 'Modo oscuro';
            }
        }

        function exportHtmlTableToCsv(tableId, filename) {
            const table = document.getElementById(tableId);
            if (!table) return;
            let csv = [];
            const rows = table.querySelectorAll('tr');
            
            for (let i = 0; i < rows.length; i++) {
                if (rows[i].style.display === 'none') continue;
                let row = [], cols = rows[i].querySelectorAll('td, th');
                for (let j = 0; j < cols.length; j++) {
                    let data = cols[j].innerText.replace(/(\r\n|\n|\r)/gm, ' ').replace(/\s+/g, ' ').trim();
                    data = data.replace(/"/g, '""');
                    row.push('"' + data + '"');
                }
                csv.push(row.join(','));
            }

            const csvBlob = new Blob(["\uFEFF" + csv.join('\n')], { type: 'text/csv;charset=utf-8;' });
            const link = document.createElement('a');
            link.href = URL.createObjectURL(csvBlob);
            link.setAttribute('download', filename);
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
        }
    </script>
</body>
</html>
"@

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)
    $targetDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if (-not [string]::IsNullOrWhiteSpace($targetDir) -and -not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($resolvedPath, $html, [System.Text.Encoding]::UTF8)
    Write-StatusMsg -Message "Informe HTML guardado en: $resolvedPath" -Status "SUCCESS"
}

# =========================================================================
# SECCION 5: ORQUESTADOR PRINCIPAL DEL SCRIPT
# =========================================================================

Clear-Host
Write-Host ""
Write-Host "  ==========================================================================" -ForegroundColor Cyan
Write-Host "   Microsoft 365 SharePoint Online  |  Auditoría de espacio" -ForegroundColor White
Write-Host "   PreservationHold (Purview)  |  Papelera de reciclaje  |  Versiones" -ForegroundColor DarkCyan
Write-Host "  ==========================================================================" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# VALIDAR MODULO MICROSOFT GRAPH AUTHENTICATION
# -------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-StatusMsg -Message "Instalando modulo 'Microsoft.Graph.Authentication'..." -Status "WORKING"
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# -------------------------------------------------------------------------
# PASO 1: Autenticacion y Conexion con Microsoft Graph
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 1 -TotalSteps 5 -Title "Conexión y autenticación con Microsoft Graph API"

try {
    $hasAppCredentials = ($TenantId -and $ClientId -and ($ClientSecret -or $CertificateThumbprint -or $CertificatePath))
    $context = Get-MgContext -ErrorAction SilentlyContinue

    if ($context) {
        if ($hasAppCredentials) {
            $isSameTenant = ($context.TenantId -eq $TenantId)
            $isSameApp = ($context.ClientId -eq $ClientId -or $context.AppName -eq $ClientId)
            $isAppOnly = ($context.AuthType -eq "AppOnly")
            if (-not ($isSameTenant -and $isSameApp -and $isAppOnly)) {
                Write-StatusMsg -Message "Renovando sesion con las credenciales indicadas..." -Status "WORKING"
                Disconnect-MgGraph -ErrorAction SilentlyContinue
                $context = $null
            }
        } elseif ($context.AuthType -ne "AppOnly" -and ($context.Scopes -notcontains "Sites.Read.All" -and $context.Scopes -notcontains "Files.Read.All")) {
            Write-StatusMsg -Message "Renovando sesion delegada de Microsoft Graph..." -Status "WORKING"
            Disconnect-MgGraph -ErrorAction SilentlyContinue
            $context = $null
        }
    }

    if (-not $context) {
        Write-StatusMsg -Message "Estableciendo sesion con Microsoft Graph..." -Status "WORKING"

        # Opcion A: Certificado instalado (Thumbprint)
        if ($TenantId -and $ClientId -and $CertificateThumbprint) {
            Write-StatusMsg -Message "Autenticando con App Registration (Certificado: $CertificateThumbprint)..." -Status "WORKING"
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -ErrorAction Stop
        }
        # Opcion B: Archivo de Certificado (.pfx/.cer)
        elseif ($TenantId -and $ClientId -and $CertificatePath) {
            Write-StatusMsg -Message "Autenticando con App Registration (Archivo: $CertificatePath)..." -Status "WORKING"
            $certParams = @{
                TenantId        = $TenantId
                ClientId        = $ClientId
                CertificatePath = $CertificatePath
                ErrorAction     = "Stop"
            }
            if ($CertificatePassword) {
                if ($CertificatePassword -is [System.Security.SecureString]) {
                    $certParams["CertificatePassword"] = $CertificatePassword
                } else {
                    $certParams["CertificatePassword"] = (ConvertTo-SecureString $CertificatePassword -AsPlainText -Force)
                }
            }
            Connect-MgGraph @certParams
        }
        # Opcion C: Client Secret
        elseif ($TenantId -and $ClientId -and $ClientSecret) {
            Write-StatusMsg -Message "Autenticando con App Registration (Client Secret)..." -Status "WORKING"
            
            $secSecret = if ($ClientSecret -is [System.Security.SecureString]) {
                $ClientSecret
            } else {
                ConvertTo-SecureString $ClientSecret -AsPlainText -Force
            }
            $plainSecret = if ($ClientSecret -is [System.Security.SecureString]) {
                [System.Net.NetworkCredential]::new("", $ClientSecret).Password
            } else {
                [string]$ClientSecret
            }
            $psCred = [System.Management.Automation.PSCredential]::new($ClientId, $secSecret)

            try {
                Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $psCred -ErrorAction Stop
            } catch {
                try {
                    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -ClientSecret $secSecret -ErrorAction Stop
                } catch {
                    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -ClientSecret $plainSecret -ErrorAction Stop
                }
            }
        }
        # Opcion D: Sesion interactiva o solicitud de credenciales
        else {
            $isInteractive = $true
            try {
                if ([Environment]::UserInteractive -eq $false -or -not $Host.UI.RawUI) {
                    $isInteractive = $false
                }
            } catch {
                $isInteractive = $false
            }

            if ($isInteractive) {
                Write-Host "`n  [?] No se detectaron credenciales completas de App Registration." -ForegroundColor Yellow
                Write-Host "  Seleccione el metodo de conexion deseado:" -ForegroundColor Cyan
                Write-Host "   [1] Ingresar credenciales de App Registration (Tenant ID, Client ID y Client Secret)" -ForegroundColor White
                Write-Host "   [2] Inicio de sesion interactivo en navegador web" -ForegroundColor White
                $authChoice = Read-Host "`n  Seleccione una opcion [1/2] (Por defecto: 2)"
                
                if ($authChoice -eq "1") {
                    $inTenant = Read-Host "  > Ingrese Tenant ID (GUID o dominio)"
                    $inClient = Read-Host "  > Ingrese Client ID (Application ID)"
                    $inSecret = Read-Host "  > Ingrese Client Secret" -AsSecureString
                    
                    if ($inTenant -and $inClient -and $inSecret) {
                        $TenantId = $inTenant.Trim()
                        $ClientId = $inClient.Trim()
                        $inPsCred = [System.Management.Automation.PSCredential]::new($ClientId, $inSecret)
                        try {
                            Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $inPsCred -ErrorAction Stop
                        } catch {
                            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -ClientSecret $inSecret -ErrorAction Stop
                        }
                    } else {
                        throw "Credenciales de App Registration incompletas."
                    }
                } else {
                    Write-StatusMsg -Message "Iniciando autenticacion interactiva en el navegador..." -Status "WORKING"
                    $requiredScopes = @(
                        "Sites.Read.All",
                        "Files.Read.All",
                        "Group.Read.All"
                    )
                    Connect-MgGraph -Scopes $requiredScopes -ErrorAction Stop
                }
            } else {
                throw "Ejecucion desatendida sin credenciales: Proporcione -TenantId, -ClientId y (-ClientSecret o -CertificateThumbprint / -CertificatePath), o defina las variables de entorno correspondientes."
            }
        }
        $context = Get-MgContext
    }

    $authTypeStr = if ($context.AuthType -eq "AppOnly") { "App Registration (Service principal)" } else { "Delegada (usuario interactivo)" }
    $identityDisplay = if ($context.AppName) {
        "$($context.AppName) (App ID: $($context.ClientId))"
    } elseif ($context.ClientId) {
        "App ID: $($context.ClientId)"
    } elseif ($context.Account) {
        $context.Account
    } else {
        "Entra ID App Registration"
    }

    Write-StatusMsg -Message "Conexion establecida correctamente con Microsoft Graph" -Status "SUCCESS"
    Write-Host ("        Modalidad   : {0}" -f $authTypeStr) -ForegroundColor DarkGray
    Write-Host ("        Identidad   : {0}" -f $identityDisplay) -ForegroundColor DarkGray
    Write-Host ("        Tenant ID   : {0}" -f $context.TenantId) -ForegroundColor DarkGray
} catch {
    Write-StatusMsg -Message "Error al conectar con Microsoft Graph: $($_.Exception.Message)" -Status "FAIL"
    return
}

# -------------------------------------------------------------------------
# DETECCION DINAMICA DEL HOSTNAME DE SHAREPOINT
# -------------------------------------------------------------------------
$tenantHostName = if ($TenantHost) { $TenantHost.Trim().TrimEnd('/') -replace '^https?://', '' } else { "" }

if (-not $tenantHostName) {
    try {
        $rootSiteRes = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/root"
        if ($rootSiteRes -and ($rootSiteRes.webUrl -or $rootSiteRes.WebUrl)) {
            $rUrl = if ($rootSiteRes.webUrl) { $rootSiteRes.webUrl } else { $rootSiteRes.WebUrl }
            $tenantHostName = ([System.Uri]$rUrl).Host
            Write-StatusMsg -Message "Dominio de SharePoint Online detectado: $tenantHostName" -Status "INFO"
        }
    } catch {
        Write-Verbose "No se pudo obtener el root site para resolver dominio: $($_.Exception.Message)"
    }
}

if (-not $tenantHostName) {
    try {
        $orgRes = Invoke-GraphRequestWithRetry -Uri "v1.0/organization"
        if ($orgRes -and $orgRes.value -and $orgRes.value.Count -gt 0) {
            $verifiedDomains = $orgRes.value[0].verifiedDomains
            $onMicrosoftDomain = $verifiedDomains | Where-Object { $_.name -like "*.onmicrosoft.com" } | Select-Object -First 1
            if ($onMicrosoftDomain) {
                $tenantPrefix = ($onMicrosoftDomain.name -split "\.")[0]
                $tenantHostName = "$tenantPrefix.sharepoint.com"
                Write-StatusMsg -Message "Dominio de SharePoint Online inferido: $tenantHostName" -Status "INFO"
            }
        }
    } catch {
        Write-Verbose "No se pudo consultar organizacion para resolver dominio: $($_.Exception.Message)"
    }
}

if (-not $tenantHostName) {
    Write-Host "`n  [?] No se pudo detectar automaticamente el dominio de SharePoint Online." -ForegroundColor Yellow
    $manualHost = Read-Host "  > Ingrese el dominio de SharePoint (ej. contoso.sharepoint.com)"
    if (-not [string]::IsNullOrWhiteSpace($manualHost)) {
        $tenantHostName = $manualHost.Trim().TrimEnd('/') -replace '^https?://', ''
    } else {
        Write-StatusMsg -Message "No se especifico el dominio de SharePoint. Operacion cancelada." -Status "FAIL"
        return
    }
}

# -------------------------------------------------------------------------
# PASO 2: Descubrimiento y Seleccion de Sitios
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 2 -TotalSteps 5 -Title "Descubrimiento y selección de sitios a auditar"

$targetSiteFilter = if ($SiteUrl) { $SiteUrl } elseif ($SiteName) { $SiteName } else { "" }
$selectedGeneralSites = [System.Collections.Generic.List[PSObject]]::new()

# Caso A: Archivo CSV especificado
if ($CsvPath) {
    if (Test-Path $CsvPath) {
        Write-StatusMsg -Message "Importando sitios desde el archivo CSV: $CsvPath" -Status "WORKING"
        $csvRows = Import-Csv -Path $CsvPath -Delimiter ";" -ErrorAction SilentlyContinue
        if (-not $csvRows) { $csvRows = Import-Csv -Path $CsvPath -Delimiter "," -ErrorAction SilentlyContinue }
        
        $csvUrls = [System.Collections.Generic.List[string]]::new()
        if ($csvRows) {
            foreach ($r in $csvRows) {
                foreach ($prop in $r.PSObject.Properties) {
                    $v = "$($prop.Value)".Trim()
                    if ($v -match "^https?://") {
                        $csvUrls.Add($v)
                        break
                    }
                }
            }
        }
        $uniqUrls = $csvUrls | Select-Object -Unique
        Write-StatusMsg -Message "Se encontraron $($uniqUrls.Count) URLs validas en el archivo CSV." -Status "SUCCESS"
        foreach ($u in $uniqUrls) {
            $resolvedSite = Get-GraphSiteByUrl -UrlOrPath $u -TenantHost $tenantHostName
            if ($resolvedSite) {
                $selectedGeneralSites.Add($resolvedSite)
            } else {
                $cPath = ($u -replace "https://[^/]+/(sites|teams)/", "") -replace "https://[^/]+", "" -replace "^/", ""
                $selectedGeneralSites.Add([PSCustomObject]@{
                    id          = "${tenantHostName}:/sites/${cPath}:"
                    displayName = if ($cPath) { $cPath } else { "Sitio CSV" }
                    webUrl      = $u
                })
            }
        }
    } else {
        Write-StatusMsg -Message "El archivo CSV especificado no existe: $CsvPath" -Status "FAIL"
        return
    }
}
# Caso B: URL o Nombre directo por parametro
elseif ($targetSiteFilter) {
    Write-StatusMsg -Message "Localizando el sitio especificado: '$targetSiteFilter'..." -Status "WORKING"
    $singleSite = Get-GraphSiteByUrl -UrlOrPath $targetSiteFilter -TenantHost $tenantHostName
    if ($singleSite) {
        $selectedGeneralSites.Add($singleSite)
        $sDisplay = if ($singleSite.displayName) { $singleSite.displayName } else { $singleSite.name }
        Write-StatusMsg -Message "Sitio localizado: $sDisplay ($($singleSite.webUrl))" -Status "SUCCESS"
    } else {
        $sUrl = if ($targetSiteFilter -like "http*") { $targetSiteFilter } else { "https://${tenantHostName}/sites/" + ($targetSiteFilter -replace "^/sites/", "") }
        $sTitle = ($sUrl -replace "https://[^/]+/(sites|teams)/", "") -replace "^/", ""
        if (-not $sTitle) { $sTitle = $targetSiteFilter }
        
        $selectedGeneralSites.Add([PSCustomObject]@{
            id          = "${tenantHostName}:/sites/${sTitle}:"
            displayName = $sTitle
            webUrl      = $sUrl
        })
        Write-StatusMsg -Message "Sitio configurado para auditoria: '$sTitle' ($sUrl)" -Status "SUCCESS"
    }
}
# Caso C: Descubrimiento multicanal de todos los sitios y seleccion interactiva
else {
    Write-StatusMsg -Message "Consultando el catalogo de sitios en Microsoft Graph..." -Status "WORKING"
    $allSitesRaw = [System.Collections.Generic.List[PSObject]]::new()
    $m365GroupUrls = @{}

    # 1. Sitio Raiz del Tenant
    try {
        $rootSite = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/root"
        if ($rootSite -and ($rootSite.id -or $rootSite.webUrl)) {
            $allSitesRaw.Add($rootSite)
        }
    } catch {
        Write-Verbose "No se pudo obtener sitio raiz: $($_.Exception.Message)"
    }

    # 2. Endpoint getAllSites
    try {
        $sitesAll = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/getAllSites"
        if ($sitesAll) {
            foreach ($s in $sitesAll) { $allSitesRaw.Add($s) }
        }
    } catch {
        Write-Verbose "getAllSites no disponible: $($_.Exception.Message)"
    }

    # 3. Busqueda global wildcard
    try {
        $wildcardRes = Invoke-GraphPaginatedRequest -Uri "v1.0/sites?search=*&`$top=999"
        if ($wildcardRes) {
            foreach ($item in $wildcardRes) { $allSitesRaw.Add($item) }
        }
    } catch {
        Write-Verbose "Busqueda wildcard de sitios no permitida: $($_.Exception.Message)"
    }

    # 4. Busqueda alfabetica y por terminos frecuentes
    $searchTerms = 97..122 | ForEach-Object { [char]$_ }
    $searchTerms += 0..9 | ForEach-Object { [string]$_ }
    $searchTerms += @("site", "portal", "team", "sharepoint", "general", "prueba", "test", "doc")

    foreach ($term in $searchTerms) {
        try {
            $res = Invoke-GraphPaginatedRequest -Uri "v1.0/sites?search=$term&`$top=999"
            if ($res) {
                foreach ($item in $res) { $allSitesRaw.Add($item) }
            }
        } catch {
            Write-Verbose "Error buscando sitios con '$term': $($_.Exception.Message)"
        }
    }

    # 5. Descubrir sitios asociados a grupos de M365 y Teams
    try {
        $m365Groups = Invoke-GraphPaginatedRequest -Uri "v1.0/groups?`$top=999&`$select=id,displayName,mailNickname,resourceProvisioningOptions"
        foreach ($grp in $m365Groups) {
            $gId = if ($grp.id) { $grp.id } else { $grp.Id }
            if ($gId) {
                try {
                    $groupSite = Invoke-GraphRequestWithRetry -Uri "v1.0/groups/$gId/sites/root"
                    if ($groupSite -and ($groupSite.id -or $groupSite.webUrl)) {
                        $allSitesRaw.Add($groupSite)
                        $gWebUrl = if ($groupSite.webUrl) { $groupSite.webUrl } else { $groupSite.WebUrl }
                        if ($gWebUrl) { $m365GroupUrls[$gWebUrl.ToLower()] = $true }
                    }
                } catch {
                    Write-Verbose "Grupo $gId sin root site de SharePoint asociado."
                }
            }
        }
    } catch {
        Write-Verbose "No se pudieron listar grupos de M365: $($_.Exception.Message)"
    }

    # 6. Eliminar duplicados
    $allSitesMap = @{}
    $uniqueSites = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($s in $allSitesRaw) {
        $sId = if ($s.id) { $s.id } else { $s.Id }
        $sUrl = if ($s.webUrl) { $s.webUrl } else { $s.WebUrl }
        $key = if ($sId) { $sId } else { $sUrl }
        if ($key -and -not $allSitesMap.ContainsKey($key.ToLower())) {
            $allSitesMap[$key.ToLower()] = $true
            $uniqueSites.Add($s)
        }
    }

    # 7. Filtrar sitios de sistema y excluidos
    $validSites = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($s in $uniqueSites) {
        $sUrl = if ($s.webUrl) { $s.webUrl } else { $s.WebUrl }
        if ([string]::IsNullOrWhiteSpace($sUrl)) { continue }

        $isExcluded = $false
        if ($ExcludePersonalSites -and ($sUrl -like "*-my.sharepoint.com*" -or $sUrl -like "*/personal/*")) {
            $isExcluded = $true
        }
        foreach ($pattern in $ExcludedSitePatterns) {
            if ($sUrl -like "*$pattern*") {
                $isExcluded = $true
                break
            }
        }
        if (-not $isExcluded) {
            $validSites.Add($s)
        }
    }

    Write-StatusMsg -Message "Se han identificado $($validSites.Count) sitios disponibles en el tenant." -Status "SUCCESS"

    $isInteractive = $true
    try {
        if ([Environment]::UserInteractive -eq $false -or -not $Host.UI.RawUI) {
            $isInteractive = $false
        }
    } catch {
        $isInteractive = $false
    }

    if ($validSites.Count -eq 0 -or -not $isInteractive) {
        if ($validSites.Count -gt 0) {
            foreach ($s in $validSites) { $selectedGeneralSites.Add($s) }
        } else {
            Write-Host "`n  [i] Ingrese la URL o nombre del sitio que desea auditar:" -ForegroundColor Cyan
            $manualSite = Read-Host "  > URL del sitio (ej. https://${tenantHostName}/sites/NombreSitio o 'Finanzas')"
            
            if (-not [string]::IsNullOrWhiteSpace($manualSite)) {
                $resolvedManual = Get-GraphSiteByUrl -UrlOrPath $manualSite -TenantHost $tenantHostName
                if ($resolvedManual) {
                    $selectedGeneralSites.Add($resolvedManual)
                } else {
                    $sUrl = if ($manualSite -like "http*") { $manualSite } else { "https://${tenantHostName}/sites/" + ($manualSite -replace "^/sites/", "") }
                    $sTitle = ($sUrl -replace "https://[^/]+/(sites|teams)/", "") -replace "^/", ""
                    $selectedGeneralSites.Add([PSCustomObject]@{
                        id          = "${tenantHostName}:/sites/${sTitle}:"
                        displayName = $sTitle
                        webUrl      = $sUrl
                    })
                }
            } else {
                Write-StatusMsg -Message "No se indico ningun sitio. Operacion finalizada." -Status "WARN"
                return
            }
        }
    } else {
        # Menu de seleccion interactivo profesional
        Write-Host ""
        Write-Host "  Catálogo de sitios disponibles en el tenant" -ForegroundColor White
        Write-Host "  --------------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host ("  {0,4}  {1,-36}  {2}" -f "Núm.", "Nombre del sitio", "Dirección web / URL") -ForegroundColor Cyan
        Write-Host "  --------------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray

        for ($i = 0; $i -lt $validSites.Count; $i++) {
            $st = $validSites[$i]
            $indexNum = $i + 1
            $titleStr = if ($st.displayName) { $st.displayName } elseif ($st.name) { $st.name } else { "Sitio" }
            if ($titleStr.Length -gt 36) { $titleStr = $titleStr.Substring(0, 33) + "..." }
            $urlStr = if ($st.webUrl) { $st.webUrl } else { "-" }

            Write-Host ("  [{0,2}] " -f $indexNum) -NoNewline -ForegroundColor Green
            Write-Host ("{0,-36}  " -f $titleStr) -NoNewline -ForegroundColor White
            Write-Host $urlStr -ForegroundColor DarkGray
        }

        Write-Host "  --------------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host ("   [ 0] Auditar todos los sitios ({0} sitios)" -f $validSites.Count) -ForegroundColor Cyan
        Write-Host "   [ S] Introducir URL o nombre de otro sitio manual" -ForegroundColor Yellow
        Write-Host "  --------------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host ""

        $selectionInput = Read-Host "  Selecciona una opción [0-$($validSites.Count) o S]"
        $trimmedSel = if ($selectionInput) { $selectionInput.Trim() } else { "0" }

        if ($trimmedSel.ToLower() -eq "s" -or $trimmedSel -like "http*") {
            $customUrl = if ($trimmedSel -like "http*") { $trimmedSel } else { Read-Host "  > Ingrese la URL o nombre del sitio" }
            $resCustom = Get-GraphSiteByUrl -UrlOrPath $customUrl -TenantHost $tenantHostName
            if ($resCustom) {
                $selectedGeneralSites.Add($resCustom)
            } else {
                $sUrl = if ($customUrl -like "http*") { $customUrl } else { "https://${tenantHostName}/sites/" + ($customUrl -replace "^/sites/", "") }
                $sTitle = ($sUrl -replace "https://[^/]+/(sites|teams)/", "") -replace "^/", ""
                $selectedGeneralSites.Add([PSCustomObject]@{
                    id          = "${tenantHostName}:/sites/${sTitle}:"
                    displayName = $sTitle
                    webUrl      = $sUrl
                })
            }
        } else {
            $indices = Get-SelectionIndices -InputString $trimmedSel -MaxRange $validSites.Count -AllowZeroForAll $true
            if ($indices.Count -eq 1 -and $indices[0] -eq 0) {
                foreach ($s in $validSites) { $selectedGeneralSites.Add($s) }
                Write-StatusMsg -Message "Seleccionados todos los sitios del catalogo ($($selectedGeneralSites.Count))." -Status "INFO"
            } else {
                foreach ($idx in $indices) {
                    $selectedGeneralSites.Add($validSites[$idx - 1])
                }
                Write-StatusMsg -Message "Seleccionados $($selectedGeneralSites.Count) sitios especificos." -Status "INFO"
            }
        }
    }
}

if ($selectedGeneralSites.Count -eq 0) {
    Write-StatusMsg -Message "No se ha seleccionado ningun sitio para auditar. Operacion finalizada." -Status "WARN"
    return
}

# -------------------------------------------------------------------------
# PASO 3: Auditoria de PreservationHoldLibrary, Papelera y Versiones
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 3 -TotalSteps 5 -Title "Auditoría de PreservationHoldLibrary, papelera e historial de versiones"

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Estructuras de datos unificadas
$allUnifiedFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
$siteSummaries = [System.Collections.Generic.List[PSCustomObject]]::new()
$folderSummaries = [System.Collections.Generic.List[PSCustomObject]]::new()
$libraryVersionSummaries = [System.Collections.Generic.List[PSCustomObject]]::new()
$failedSites = [System.Collections.Generic.List[PSCustomObject]]::new()

$currentSiteIndex = 0
$totalSitesToProcess = $selectedGeneralSites.Count

foreach ($siteObj in $selectedGeneralSites) {
    $currentSiteIndex++
    $siteId = $siteObj.id
    $siteTitle = if ($siteObj.displayName) { $siteObj.displayName } elseif ($siteObj.name) { $siteObj.name } else { "Sitio" }
    $siteWebUrl = if ($siteObj.webUrl) { $siteObj.webUrl } else { "" }

    Write-Host ""
    Write-Host ("  [{0}/{1}] Sitio: {2}" -f $currentSiteIndex, $totalSitesToProcess, $siteTitle) -ForegroundColor White
    if ($siteWebUrl) {
        Write-Host ("        URL: {0}" -f $siteWebUrl) -ForegroundColor DarkGray
    }

    # Bloque de proteccion por sitio: un fallo en un sitio no detiene la auditoria global
    try {
        $sitePreservationFilesCount = 0
        $sitePreservationFoldersCount = 0
        $sitePreservationBytes = 0
        $hasPreservationHold = $false

        $siteRecycleBinCount = 0
        $siteRecycleBinBytes = 0

        $siteVersionHistoryFilesCount = 0
        $siteVersionHistoryBytes = 0

        $oldestDate = [datetime]::MaxValue
        $newestDate = [datetime]::MinValue

        # =========================================================================
        # A. Auditoria de PreservationHoldLibrary (Purview / eDiscovery / Litigios)
        # =========================================================================
        try {
            $drivesRes = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$siteId/drives"
            $preservationDrives = [System.Collections.Generic.List[PSObject]]::new()
            
            foreach ($drv in $drivesRes) {
                $drvName = if ($drv.name) { $drv.name } else { "" }
                $drvWebUrl = if ($drv.webUrl) { $drv.webUrl } else { "" }
                
                if ($drvName -eq "PreservationHoldLibrary" -or $drvWebUrl -like "*/PreservationHoldLibrary*" -or $drvName -like "*Preservation Hold*") {
                    $preservationDrives.Add($drv)
                }
            }

            # Fallback en listas si no se detecta como drive directo
            if ($preservationDrives.Count -eq 0) {
                try {
                    $listsRes = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$siteId/lists"
                    foreach ($lst in $listsRes) {
                        $lstName = if ($lst.name) { $lst.name } else { "" }
                        $lstDisplay = if ($lst.displayName) { $lst.displayName } else { "" }
                        
                        if ($lstName -eq "PreservationHoldLibrary" -or $lstDisplay -eq "PreservationHoldLibrary" -or $lstDisplay -like "*Preservation Hold*") {
                            try {
                                $listDrive = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/$siteId/lists/$($lst.id)/drive"
                                if ($listDrive -and $listDrive.id) {
                                    $preservationDrives.Add($listDrive)
                                }
                            } catch {
                                Write-Verbose "No se pudo obtener el drive de la lista $($lst.id): $($_.Exception.Message)"
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Error listando bibliotecas de $siteTitle : $($_.Exception.Message)"
                }
            }

            if ($preservationDrives.Count -gt 0) {
                $hasPreservationHold = $true
                foreach ($pDrive in $preservationDrives) {
                    $driveId = $pDrive.id
                    Write-StatusMsg -Message "PreservationHoldLibrary detectada. Analizando archivos retenidos..." -Status "WORKING"

                    $allItems = [System.Collections.Generic.List[PSObject]]::new()
                    try {
                        $deltaResults = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$siteId/drives/$driveId/root/delta"
                        foreach ($it in $deltaResults) {
                            if (-not $it.root) { $allItems.Add($it) }
                        }
                    } catch {
                        Write-Verbose "Delta query no disponible para PreservationHold. Usando exploracion recursiva..."
                        $allItems = Get-DriveItemsRecursive -SiteId $siteId -DriveId $driveId -ItemId "root"
                    }

                    $folderMap = @{}

                    foreach ($item in $allItems) {
                        $itemName = if ($item.name) { $item.name } else { "Item" }
                        $itemSize = if ($item.size) { [double]$item.size } else { 0 }
                        $itemCreated = if ($item.createdDateTime) { [datetime]$item.createdDateTime } else { $null }
                        $itemModified = if ($item.lastModifiedDateTime) { [datetime]$item.lastModifiedDateTime } else { $null }
                        $itemWebUrl = if ($item.webUrl) { $item.webUrl } else { "" }

                        $createdByName = "Desconocido"
                        $createdByEmail = ""
                        if ($item.createdBy -and $item.createdBy.user) {
                            $createdByName = if ($item.createdBy.user.displayName) { $item.createdBy.user.displayName } else { "Usuario" }
                            $createdByEmail = if ($item.createdBy.user.email) { $item.createdBy.user.email } elseif ($item.createdBy.user.userPrincipalName) { $item.createdBy.user.userPrincipalName } else { "" }
                        }
                        
                        $modifiedByName = "Desconocido"
                        $modifiedByEmail = ""
                        if ($item.lastModifiedBy -and $item.lastModifiedBy.user) {
                            $modifiedByName = if ($item.lastModifiedBy.user.displayName) { $item.lastModifiedBy.user.displayName } else { "Usuario" }
                            $modifiedByEmail = if ($item.lastModifiedBy.user.email) { $item.lastModifiedBy.user.email } elseif ($item.lastModifiedBy.user.userPrincipalName) { $item.lastModifiedBy.user.userPrincipalName } else { "" }
                        }

                        $parentPath = ""
                        if ($item.parentReference -and $item.parentReference.path) {
                            $rawPath = $item.parentReference.path
                            if ($rawPath -match "/root:?(.*)$") { $parentPath = $Matches[1] } else { $parentPath = $rawPath }
                        }
                        if ([string]::IsNullOrWhiteSpace($parentPath)) { $parentPath = "/" }

                        if ($item.file -or (-not $item.folder)) {
                            $sitePreservationFilesCount++
                            $sitePreservationBytes += $itemSize

                            if ($itemModified -and $itemModified -lt $oldestDate) { $oldestDate = $itemModified }
                            if ($itemModified -and $itemModified -gt $newestDate) { $newestDate = $itemModified }

                            $ext = [System.IO.Path]::GetExtension($itemName).ToLower()
                            if ([string]::IsNullOrWhiteSpace($ext)) { $ext = "[sin extension]" }

                            if (-not $folderMap.ContainsKey($parentPath)) {
                                $folderMap[$parentPath] = @{ FileCount = 0; SizeBytes = 0 }
                            }
                            $folderMap[$parentPath].FileCount++
                            $folderMap[$parentPath].SizeBytes += $itemSize

                            $allUnifiedFiles.Add([PSCustomObject]@{
                                SourceType            = "PreservationHoldLibrary"
                                SiteTitle             = $siteTitle
                                SiteUrl               = $siteWebUrl
                                ItemName              = $itemName
                                Extension             = $ext
                                LocationPath          = $parentPath
                                SizeBytes             = $itemSize
                                SizeFormatted         = Format-FileSize -Bytes $itemSize
                                DeletedOrModifiedDate = if ($itemModified) { (Get-SpainDate -InputDate $itemModified).ToString("yyyy-MM-dd HH:mm:ss") } else { "-" }
                                ActionByUser          = "$modifiedByName $(if ($modifiedByEmail) { "($modifiedByEmail)" })".Trim()
                                CreatedDate           = if ($itemCreated) { (Get-SpainDate -InputDate $itemCreated).ToString("yyyy-MM-dd HH:mm:ss") } else { "-" }
                                CreatedByUser         = "$createdByName $(if ($createdByEmail) { "($createdByEmail)" })".Trim()
                                WebUrl                = $itemWebUrl
                                AuditDate             = (Get-SpainDate).ToString("yyyy-MM-dd HH:mm:ss")
                            })
                        } elseif ($item.folder) {
                            $sitePreservationFoldersCount++
                            $folderFullPath = if ($parentPath.EndsWith("/")) { "$parentPath$itemName" } else { "$parentPath/$itemName" }
                            if (-not $folderMap.ContainsKey($folderFullPath)) {
                                $folderMap[$folderFullPath] = @{ FileCount = 0; SizeBytes = 0 }
                            }
                        }
                    }

                    foreach ($fk in $folderMap.Keys) {
                        $fData = $folderMap[$fk]
                        $folderSummaries.Add([PSCustomObject]@{
                            SiteTitle         = $siteTitle
                            SiteUrl           = $siteWebUrl
                            FolderPath        = $fk
                            FilesCount        = $fData.FileCount
                            SizeBytes         = $fData.SizeBytes
                            SizeFormatted     = Format-FileSize -Bytes $fData.SizeBytes
                            AuditDate         = (Get-SpainDate).ToString("yyyy-MM-dd HH:mm:ss")
                        })
                    }
                }
            }
        } catch {
            Write-Verbose "Error auditando PreservationHold en '$siteTitle': $($_.Exception.Message)"
        }

        # =========================================================================
        # B. Auditoria de Papelera de Reciclaje (Recycle Bin - 1ª y 2ª Etapa)
        # =========================================================================
        try {
            Write-StatusMsg -Message "Auditando elementos en papelera de reciclaje..." -Status "WORKING"
            $recycleItems = Get-SiteRecycleBinItems -SiteId $siteId -SiteWebUrl $siteWebUrl -TenantHost $tenantHostName -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

            if ($recycleItems -and $recycleItems.Count -gt 0) {
                foreach ($rc in $recycleItems) {
                    $rcName = if ($rc.name) { $rc.name } elseif ($rc.title) { $rc.title } elseif ($rc.displayName) { $rc.displayName } else { "Elemento eliminado" }
                    $rcSize = if ($null -ne $rc.size) { [double]$rc.size } elseif ($rc.file -and $rc.file.size) { [double]$rc.file.size } else { 0 }
                    $rcDeletedDate = if ($rc.deletedDateTime) { [datetime]$rc.deletedDateTime } elseif ($rc.lastModifiedDateTime) { [datetime]$rc.lastModifiedDateTime } else { $null }
                    $rcOrigLocation = if ($rc.deletedFromLocation) { $rc.deletedFromLocation } else { "/" }
                    $rcWebUrl = if ($rc.webUrl) { $rc.webUrl } else { "" }

                    $deletedByName = "Desconocido"
                    $deletedByEmail = ""
                    if ($rc.deletedBy) {
                        if ($rc.deletedBy.user) {
                            $deletedByName = if ($rc.deletedBy.user.displayName) { $rc.deletedBy.user.displayName } else { "Usuario" }
                            $deletedByEmail = if ($rc.deletedBy.user.email) { $rc.deletedBy.user.email } elseif ($rc.deletedBy.user.userPrincipalName) { $rc.deletedBy.user.userPrincipalName } else { "" }
                        } elseif ($rc.deletedBy.application) {
                            $deletedByName = if ($rc.deletedBy.application.displayName) { $rc.deletedBy.application.displayName } else { "Aplicacion" }
                        }
                    }

                    $siteRecycleBinCount++
                    $siteRecycleBinBytes += $rcSize

                    if ($rcDeletedDate -and $rcDeletedDate -lt $oldestDate) { $oldestDate = $rcDeletedDate }
                    if ($rcDeletedDate -and $rcDeletedDate -gt $newestDate) { $newestDate = $rcDeletedDate }

                    $ext = [System.IO.Path]::GetExtension($rcName).ToLower()
                    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = "[sin extension]" }

                    $allUnifiedFiles.Add([PSCustomObject]@{
                        SourceType            = "Papelera de reciclaje"
                        SiteTitle             = $siteTitle
                        SiteUrl               = $siteWebUrl
                        ItemName              = $rcName
                        Extension             = $ext
                        LocationPath          = "Papelera (origen: $rcOrigLocation)"
                        SizeBytes             = $rcSize
                        SizeFormatted         = Format-FileSize -Bytes $rcSize
                        DeletedOrModifiedDate = if ($rcDeletedDate) { (Get-SpainDate -InputDate $rcDeletedDate).ToString("yyyy-MM-dd HH:mm:ss") } else { "-" }
                        ActionByUser          = "$deletedByName $(if ($deletedByEmail) { "($deletedByEmail)" })".Trim()
                        CreatedDate           = "-"
                        CreatedByUser         = "-"
                        WebUrl                = $rcWebUrl
                        AuditDate             = (Get-SpainDate).ToString("yyyy-MM-dd HH:mm:ss")
                    })
                }
            }
        } catch {
            Write-Verbose "No se pudo consultar recycleBin mediante REST/Graph: $($_.Exception.Message)"
        }

        # Fallback: tamano de papelera via drive.quota.deleted cuando REST no esta disponible
        if ($siteRecycleBinBytes -eq 0) {
            try {
                $quotaDeletedBytes = 0
                $quotaAlreadyCounted = $false
                $drivesForQuota = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$siteId/drives"
                foreach ($drv in $drivesForQuota) {
                    if ($quotaAlreadyCounted) { break }
                    try {
                        $drvDetail = Invoke-GraphRequestWithRetry -Uri "v1.0/drives/$($drv.id)?`$select=id,name,quota"
                        if ($drvDetail -and $drvDetail.quota -and $drvDetail.quota.deleted -and [double]$drvDetail.quota.deleted -gt 0) {
                            $quotaDeletedBytes = [double]$drvDetail.quota.deleted
                            $quotaAlreadyCounted = $true
                        }
                    } catch {
                        Write-Verbose "No se pudo obtener quota de drive $($drv.id): $($_.Exception.Message)"
                    }
                }

                if ($quotaDeletedBytes -gt 0) {
                    $siteRecycleBinBytes = $quotaDeletedBytes
                    $allUnifiedFiles.Add([PSCustomObject]@{
                        SourceType            = "Papelera de reciclaje"
                        SiteTitle             = $siteTitle
                        SiteUrl               = $siteWebUrl
                        ItemName              = "[Total papelera - detalle no disponible via API]"
                        Extension             = "[agregado]"
                        LocationPath          = "Papelera de reciclaje (1ª y 2ª etapa)"
                        SizeBytes             = $quotaDeletedBytes
                        SizeFormatted         = Format-FileSize -Bytes $quotaDeletedBytes
                        DeletedOrModifiedDate = "-"
                        ActionByUser          = "Varios usuarios"
                        CreatedDate           = "-"
                        CreatedByUser         = "-"
                        WebUrl                = "$($siteWebUrl.TrimEnd('/'))/_layouts/15/recycle.aspx"
                        AuditDate             = (Get-SpainDate).ToString("yyyy-MM-dd HH:mm:ss")
                    })
                    Write-StatusMsg -Message "Espacio en papelera obtenido via cuota: $(Format-FileSize -Bytes $quotaDeletedBytes)" -Status "SUCCESS"
                }
            } catch {
                Write-Verbose "No se pudo obtener quota.deleted de los drives: $($_.Exception.Message)"
            }
        }
        $siteRecycleBinCount = ($allUnifiedFiles | Where-Object { $_.SourceType -eq "Papelera de reciclaje" -and $_.SiteTitle -eq $siteTitle }).Count

        # =========================================================================
        # C. Historial de Versiones de Documentos
        # =========================================================================
        if ($AuditVersionHistory) {
            try {
                Write-StatusMsg -Message "Auditando historial de versiones de documentos..." -Status "WORKING"
                $filesProcessed = 0

                $drivesForVer = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$siteId/drives"
                foreach ($drv in $drivesForVer) {
                    $drvName = if ($drv.name) { $drv.name } else { "" }
                    if ($drvName -eq "PreservationHoldLibrary" -or $drvName -like "*Preservation Hold*") { continue }

                    $driveItems = Invoke-GraphPaginatedRequest -Uri "v1.0/drives/$($drv.id)/root/delta?`$select=id,name,file,size,parentReference,webUrl,lastModifiedDateTime"
                    $fileItems = $driveItems | Where-Object { $_ -and $_.file -and -not $_.deleted }

                    foreach ($fi in $fileItems) {
                        if ($MaxVersionFilesPerSite -gt 0 -and $filesProcessed -ge $MaxVersionFilesPerSite) { break }
                        $filesProcessed++

                        try {
                            $versions = Invoke-GraphPaginatedRequest -Uri "v1.0/drives/$($drv.id)/items/$($fi.id)/versions?`$select=id,size"
                            if ($versions -and $versions.Count -gt 1) {
                                $olderVersions = $versions | Select-Object -Skip 1
                                $olderBytes = 0
                                foreach ($v in $olderVersions) {
                                    if ($null -ne $v.size -and [double]$v.size -gt 0) {
                                        $olderBytes += [double]$v.size
                                    }
                                }

                                if ($olderBytes -gt 0) {
                                    $siteVersionHistoryFilesCount++
                                    $siteVersionHistoryBytes += $olderBytes

                                    $vExt = [System.IO.Path]::GetExtension($fi.name).ToLower()
                                    if ([string]::IsNullOrWhiteSpace($vExt)) { $vExt = "[sin extension]" }
                                    $vParentPath = if ($fi.parentReference -and $fi.parentReference.path) {
                                        ($fi.parentReference.path -replace "^/drives/[^/]+/root:", "")
                                    } else { "/" }
                                    if ([string]::IsNullOrWhiteSpace($vParentPath)) { $vParentPath = "/" }

                                    $allUnifiedFiles.Add([PSCustomObject]@{
                                        SourceType            = "Historial de versiones"
                                        SiteTitle             = $siteTitle
                                        SiteUrl               = $siteWebUrl
                                        ItemName              = $fi.name
                                        Extension             = $vExt
                                        LocationPath          = "Versiones: $vParentPath"
                                        SizeBytes             = $olderBytes
                                        SizeFormatted         = Format-FileSize -Bytes $olderBytes
                                        DeletedOrModifiedDate = if ($fi.lastModifiedDateTime) { (Get-SpainDate -InputDate ([datetime]$fi.lastModifiedDateTime)).ToString("yyyy-MM-dd HH:mm:ss") } else { "-" }
                                        ActionByUser          = "($($versions.Count) versiones guardadas)"
                                        CreatedDate           = "-"
                                        CreatedByUser         = "-"
                                        WebUrl                = if ($fi.webUrl) { $fi.webUrl } else { "" }
                                        AuditDate             = (Get-SpainDate).ToString("yyyy-MM-dd HH:mm:ss")
                                    })
                                }
                            }
                        } catch {
                            Write-Verbose "Versiones de '$($fi.name)': $($_.Exception.Message)"
                        }
                    }
                    if ($MaxVersionFilesPerSite -gt 0 -and $filesProcessed -ge $MaxVersionFilesPerSite) { break }
                }

                if ($siteVersionHistoryBytes -gt 0) {
                    Write-StatusMsg -Message "Versiones antiguas: $(Format-FileSize -Bytes $siteVersionHistoryBytes) ($siteVersionHistoryFilesCount archivos)" -Status "SUCCESS"
                } else {
                    Write-StatusMsg -Message "Sin versiones antiguas significativas detectadas." -Status "INFO"
                }
            } catch {
                Write-Verbose "Error auditoria versiones: $($_.Exception.Message)"
            }
        }

        # =========================================================================
        # D. Configuracion de limites de versiones por biblioteca
        # =========================================================================
        $siteLibVersions = Get-SiteLibraryVersionSettings -SiteId $siteId -SiteWebUrl $siteWebUrl -TenantHost $tenantHostName -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
        $siteVersionLimitDisplay = ""
        if ($siteLibVersions -and $siteLibVersions.Count -gt 0) {
            foreach ($lv in $siteLibVersions) {
                $libraryVersionSummaries.Add([PSCustomObject]@{
                    SiteTitle         = $siteTitle
                    SiteUrl           = $siteWebUrl
                    LibraryTitle      = $lv.LibraryTitle
                    EnableVersioning  = $lv.EnableVersioning
                    MajorVersionLimit = $lv.MajorVersionLimit
                    ItemCount         = $lv.ItemCount
                    Source            = $lv.Source
                })
            }
            $distinctLimits = $siteLibVersions | Select-Object -ExpandProperty MajorVersionLimit -Unique
            if ($distinctLimits.Count -eq 1) {
                $siteVersionLimitDisplay = "$($distinctLimits[0]) versiones"
            } else {
                $siteVersionLimitDisplay = ($siteLibVersions | ForEach-Object { "$($_.LibraryTitle): $($_.MajorVersionLimit)" }) -join ", "
            }
        } else {
            $siteVersionLimitDisplay = "500 versiones"
        }

        # Resumen consolidado del sitio
        $totalSiteNonProductiveBytes = $sitePreservationBytes + $siteRecycleBinBytes + $siteVersionHistoryBytes
        $oldestStr = if ($oldestDate -ne [datetime]::MaxValue) { (Get-SpainDate -InputDate $oldestDate).ToString("yyyy-MM-dd") } else { "-" }
        $newestStr = if ($newestDate -ne [datetime]::MinValue) { (Get-SpainDate -InputDate $newestDate).ToString("yyyy-MM-dd") } else { "-" }

        $msgPres = Format-FileSize -Bytes $sitePreservationBytes
        $msgRec = Format-FileSize -Bytes $siteRecycleBinBytes
        $msgVer = Format-FileSize -Bytes $siteVersionHistoryBytes
        $msgTotal = Format-FileSize -Bytes $totalSiteNonProductiveBytes

        # Mini tarjeta estructurada de resumen de sitio
        Write-Host "        +-- Resumen de almacenamiento ----------------------------------" -ForegroundColor DarkCyan
        Write-Host "        | PreservationHold : " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-12}" -f $msgPres) -NoNewline -ForegroundColor Magenta
        Write-Host ("({0} archivos retenidos)" -f $sitePreservationFilesCount) -ForegroundColor DarkGray

        Write-Host "        | Papelera recicl. : " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-12}" -f $msgRec) -NoNewline -ForegroundColor Yellow
        Write-Host ("({0} elementos eliminados)" -f $siteRecycleBinCount) -ForegroundColor DarkGray

        Write-Host "        | Versiones antig. : " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-12}" -f $msgVer) -NoNewline -ForegroundColor Cyan
        Write-Host ("({0} archivos con versiones)" -f $siteVersionHistoryFilesCount) -ForegroundColor DarkGray

        Write-Host "        | Límite versiones : " -NoNewline -ForegroundColor DarkGray
        Write-Host $siteVersionLimitDisplay -ForegroundColor White

        Write-Host "        | Total recuperable: " -NoNewline -ForegroundColor DarkGray
        Write-Host $msgTotal -ForegroundColor Green
        Write-Host "        +---------------------------------------------------------------" -ForegroundColor DarkCyan

        $siteSummaries.Add([PSCustomObject]@{
            SiteTitle                      = $siteTitle
            SiteUrl                        = $siteWebUrl
            HasPreservationHold            = $hasPreservationHold
            PreservationFilesCount         = $sitePreservationFilesCount
            PreservationFoldersCount       = $sitePreservationFoldersCount
            PreservationSizeBytes          = $sitePreservationBytes
            PreservationSizeFormatted      = $msgPres
            RecycleBinCount                = $siteRecycleBinCount
            RecycleBinSizeBytes            = $siteRecycleBinBytes
            RecycleBinSizeFormatted        = $msgRec
            VersionHistoryFilesCount       = $siteVersionHistoryFilesCount
            VersionHistorySizeBytes        = $siteVersionHistoryBytes
            VersionHistorySizeFormatted    = $msgVer
            VersionLimitConfigured         = $siteVersionLimitDisplay
            TotalNonProductiveBytes        = $totalSiteNonProductiveBytes
            TotalNonProductiveFormatted    = $msgTotal
            OldestDate                     = $oldestStr
            NewestDate                     = $newestStr
            AuditDate                      = (Get-SpainDate).ToString("yyyy-MM-dd HH:mm:ss")
        })
    } catch {
        # Control de excepciones por sitio individual
        $errSiteMsg = $_.Exception.Message
        Write-StatusMsg -Message "Incidencia en sitio '$siteTitle': $errSiteMsg" -Status "FAIL"
        $failedSites.Add([PSCustomObject]@{
            SiteTitle    = $siteTitle
            SiteUrl      = $siteWebUrl
            ErrorMessage = $errSiteMsg
            Timestamp    = (Get-SpainDate).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }
}

$stopwatch.Stop()
$elapsedTime = "{0:hh\:mm\:ss}" -f $stopwatch.Elapsed

# -------------------------------------------------------------------------
# PASO 4: Generacion del Informe HTML Interactivo Corporativo
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 4 -TotalSteps 5 -Title "Generación del informe HTML interactivo corporativo"

# Determinar nombre y ruta del reporte
$auditedSiteFilterName = if ($selectedGeneralSites -and $selectedGeneralSites.Count -eq 1) {
    if ($selectedGeneralSites[0].displayName) {
        $selectedGeneralSites[0].displayName
    } elseif ($selectedGeneralSites[0].name) {
        $selectedGeneralSites[0].name
    } elseif ($selectedGeneralSites[0].webUrl) {
        $selectedGeneralSites[0].webUrl
    } else {
        "sitio_especifico"
    }
} elseif ($targetSiteFilter) {
    $targetSiteFilter
} else {
    "todos_los_sitios"
}

if ([string]::IsNullOrWhiteSpace($HtmlOutputPath)) {
    $reportFileName = Get-ReportFileName -SiteNameInput $auditedSiteFilterName -Extension "html"
    $HtmlOutputPath = [System.IO.Path]::Combine("Reportes", $reportFileName)
}

$userAccountDisplay = if ($context -and $context.AppName) {
    "$($context.AppName) (App Registration)"
} elseif ($ClientId) {
    "App ID: $ClientId"
} elseif ($context -and $context.Account) {
    $context.Account
} else {
    "App Registration / Entra ID"
}

Write-StatusMsg -Message "Compilando informe interactivo con tema Fluent UI..." -Status "WORKING"
try {
    Export-UnifiedReportToHtml `
        -FilesData $allUnifiedFiles `
        -SitesSummaryData $siteSummaries `
        -FoldersSummaryData $folderSummaries `
        -LibraryVersionData $libraryVersionSummaries `
        -FailedSitesData $failedSites `
        -FilePath $HtmlOutputPath `
        -UserAccount $userAccountDisplay `
        -AuditedSiteFilter $auditedSiteFilterName `
        -ElapsedTime $elapsedTime
} catch {
    Write-StatusMsg -Message "Error al generar informe HTML: $($_.Exception.Message)" -Status "FAIL"
}

# -------------------------------------------------------------------------
# PASO 5: Exportacion CSV y Resumen Final
# -------------------------------------------------------------------------
Write-StepHeader -StepNumber 5 -TotalSteps 5 -Title "Exportación de datos y resumen final"

if ($ExportCsv -and $allUnifiedFiles.Count -gt 0) {
    try {
        if ([string]::IsNullOrWhiteSpace($CsvOutputPath)) {
            $csvFileName = Get-ReportFileName -SiteNameInput $auditedSiteFilterName -Extension "csv"
            $CsvOutputPath = [System.IO.Path]::Combine("Reportes", $csvFileName)
        }

        $resolvedCsvPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CsvOutputPath)
        $csvTargetDir = [System.IO.Path]::GetDirectoryName($resolvedCsvPath)
        if (-not [string]::IsNullOrWhiteSpace($csvTargetDir) -and -not (Test-Path $csvTargetDir)) {
            New-Item -ItemType Directory -Path $csvTargetDir -Force | Out-Null
        }

        $allUnifiedFiles | Export-Csv -Path $resolvedCsvPath -NoTypeInformation -Encoding UTF8
        Write-StatusMsg -Message "Inventario CSV exportado en: $resolvedCsvPath" -Status "SUCCESS"
    } catch {
        Write-StatusMsg -Message "Error al exportar archivo CSV: $($_.Exception.Message)" -Status "FAIL"
    }
}

# Totales globales consolidados
$grandPresTotal = 0
$grandRecTotal = 0
$grandVerTotal = 0
foreach ($s in $siteSummaries) {
    $grandPresTotal += $s.PreservationSizeBytes
    $grandRecTotal += $s.RecycleBinSizeBytes
    $grandVerTotal += $s.VersionHistorySizeBytes
}
$grandTotal = $grandPresTotal + $grandRecTotal + $grandVerTotal
$grandTotalFormatted = Format-FileSize -Bytes $grandTotal
$grandPresFormatted = Format-FileSize -Bytes $grandPresTotal
$grandRecFormatted = Format-FileSize -Bytes $grandRecTotal
$grandVerFormatted = Format-FileSize -Bytes $grandVerTotal

$sitesWithHold = ($siteSummaries | Where-Object { $_.HasPreservationHold -eq $true }).Count

Write-Host ""
Write-Host "  ==========================================================================" -ForegroundColor Cyan
Write-Host "                   Resumen ejecutivo de auditoría                           " -ForegroundColor White
Write-Host "  ==========================================================================" -ForegroundColor Cyan
Write-Host ("   Duración total del análisis           : {0}" -f $elapsedTime) -ForegroundColor White
Write-Host ("   Sitios auditados exitosamente         : {0}" -f $siteSummaries.Count) -ForegroundColor White
if ($failedSites.Count -gt 0) {
    Write-Host ("   Sitios con incidencias                : {0}" -f $failedSites.Count) -ForegroundColor Red
}
Write-Host ("   Sitios con retención activa (Purview) : {0}" -f $sitesWithHold) -ForegroundColor $(if ($sitesWithHold -gt 0) { "Yellow" } else { "Green" })
Write-Host "  --------------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("   Espacio en PreservationHoldLibrary    : {0}" -f $grandPresFormatted) -ForegroundColor Magenta
Write-Host ("   Espacio en papelera de reciclaje      : {0}" -f $grandRecFormatted) -ForegroundColor Yellow
Write-Host ("   Espacio en versiones antiguas         : {0}" -f $grandVerFormatted) -ForegroundColor Cyan
Write-Host ("   Espacio total no productivo           : {0}" -f $grandTotalFormatted) -ForegroundColor Green
Write-Host ("   Total de elementos contabilizados     : {0:N0}" -f $allUnifiedFiles.Count) -ForegroundColor White
Write-Host "  --------------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("   Informe HTML generado                 : {0}" -f $HtmlOutputPath) -ForegroundColor Green
if ($ExportCsv -and $allUnifiedFiles.Count -gt 0) {
    Write-Host ("   Inventario CSV generado               : {0}" -f $CsvOutputPath) -ForegroundColor Green
}
Write-Host "  ==========================================================================" -ForegroundColor Cyan

if ($siteSummaries.Count -gt 0) {
    Write-Host ""
    Write-Host "  Top sitios con mayor volumen no productivo:" -ForegroundColor Yellow
    Write-Host "  --------------------------------------------------------------------------" -ForegroundColor DarkGray
    $siteSummaries | Sort-Object -Property TotalNonProductiveBytes -Descending | Select-Object -First 5 @{Name="Sitio"; Expression={$_.SiteTitle}}, @{Name="PreservationHold"; Expression={$_.PreservationSizeFormatted}}, @{Name="Papelera"; Expression={$_.RecycleBinSizeFormatted}}, @{Name="Versiones"; Expression={$_.VersionHistorySizeFormatted}}, @{Name="Total recuperable"; Expression={$_.TotalNonProductiveFormatted}} | Format-Table -AutoSize
}

if ($failedSites.Count -gt 0) {
    Write-Host ""
    Write-Host "  Incidencias registradas durante la auditoría:" -ForegroundColor Red
    Write-Host "  --------------------------------------------------------------------------" -ForegroundColor DarkGray
    $failedSites | Select-Object @{Name="Sitio"; Expression={$_.SiteTitle}}, @{Name="URL"; Expression={$_.SiteUrl}}, @{Name="Incidencia"; Expression={$_.ErrorMessage}} | Format-Table -AutoSize
}

Write-StatusMsg -Message "Proceso de auditoría finalizado con éxito." -Status "SUCCESS"
