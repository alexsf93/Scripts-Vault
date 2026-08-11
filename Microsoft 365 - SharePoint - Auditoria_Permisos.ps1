<#
.SYNOPSIS
    SharePoint online - Auditoria de permisos en sitios, subsitios y carpetas con Microsoft graph (v3.7.0)

.DESCRIPTION
    Script de auditoria de permisos para SharePoint online.
    Permite seleccionar un sitio general por pantalla o mediante parametros,
    y analiza la raiz, los subsitios y las carpetas con permisos unicos (ruptura de herencia).
    Desglosa grupos de SharePoint, Entra id y M365 hasta llegar a usuarios individuales.
    Genera un informe HTML interactivo corporativo estilo Microsoft sharepoint & fluent ui con vista por sitio y matriz por usuario.

.PARAMETER TenantId
    ID o dominio del tenant de Microsoft 365.

.PARAMETER ClientId
    ID de la aplicacion (App ID) de Entra id.

.PARAMETER ClientSecret
    Secreto de aplicacion (Client secret).

.PARAMETER SiteUrl
    Nombre, ruta o URL del sitio a auditar (ej. "Administracion", "rrhh" o "https://contoso.sharepoint.com/sites/Administracion").

.PARAMETER SiteName
    Alias para -SiteUrl. Nombre o filtro del sitio objetivo.

.PARAMETER HtmlOutputPath
    Ruta del informe HTML de salida. Por defecto: ".\Reporte_Permisos_SharePoint.html"

.PARAMETER MaxFolderDepth
    Profundidad maxima de exploracion de subcarpetas en bibliotecas de documentos (por defecto: 5).

.EXAMPLE
    & '.\Microsoft 365 - SharePoint - Auditoria_Permisos.ps1'

.EXAMPLE
    & '.\Microsoft 365 - SharePoint - Auditoria_Permisos.ps1' -SiteUrl "Administracion"

.EXAMPLE
    & '.\Microsoft 365 - SharePoint - Auditoria_Permisos.ps1' -SiteUrl "https://contoso.sharepoint.com/sites/Administracion" -HtmlOutputPath ".\Auditoria_Administracion.html"

.NOTES
    Nombre:   Microsoft 365 - SharePoint - Auditoria_Permisos.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  3.7.0
    Fecha:    2026-08-10
#>

param(
    [string]$TenantId = "",
    [string]$ClientId = "",
    [string]$ClientSecret = "",
    [string]$SiteUrl = "",
    [string]$SiteName = "",
    [string]$CsvPath = "",
    [string]$HtmlOutputPath = ".\Reporte_Permisos_SharePoint.html",
    [int]$MaxFolderDepth = 5,
    [bool]$ExcludePersonalSites = $true,
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

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "  [*] Instalando modulo requerido 'Microsoft.Graph.Authentication' desde PowerShell gallery..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# Encabezado sencillo y limpio para cada paso
function Write-StepHeader {
    param(
        [int]$StepNumber,
        [int]$TotalSteps = 6,
        [string]$Title
    )
    Write-Host "`n------------------------------------------------------------------------- " -ForegroundColor Cyan
    Write-Host " Paso ${StepNumber} de ${TotalSteps}: $Title" -ForegroundColor White
    Write-Host "------------------------------------------------------------------------- " -ForegroundColor Cyan
}

# Mensajes de estado claros sin emojis ni caracteres raros
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

# Limpiar acentos, diacriticos y caracteres especiales de nombres para formar la ruta URL en SharePoint
function Clean-SitePath {
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

Clear-Host
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Auditoria de permisos de spo" -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Nota sobre la estructura:" -ForegroundColor Yellow
Write-Host "  - Sitio principal: Sitio independiente de nivel superior (ej. /sites/ventas)." -ForegroundColor Gray
Write-Host "  - Subsitio: Sitio secundario dentro de un sitio principal." -ForegroundColor Gray
Write-Host "  - Carpetas unicas: Carpetas o bibliotecas donde se han personalizado los permisos." -ForegroundColor Gray
Write-Host "-------------------------------------------------------------------------" -ForegroundColor DarkGray

# Paso 1: Conexion con Microsoft graph
Write-StepHeader -StepNumber 1 -TotalSteps 6 -Title "Conexion con Microsoft graph api"

try {
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if ($context -and ($context.Scopes -notcontains "Sites.FullControl.All" -and $context.Scopes -notcontains "Sites.Read.All")) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        $context = $null
    }

    if (-not $context) {
        Write-StatusMsg -Message "Conectando con Microsoft graph..." -Status "WORKING"
        if ($TenantId -and $ClientId -and $ClientSecret) {
            Write-StatusMsg -Message "Autenticando con app registration..." -Status "WORKING"
            $secSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -ClientSecret $secSecret -ErrorAction Stop
        } else {
            Write-StatusMsg -Message "Iniciando sesion interactiva (permisos de lectura)..." -Status "WORKING"
            $requiredScopes = @(
                "Sites.FullControl.All",
                "Sites.Read.All",
                "Group.Read.All",
                "User.Read.All"
            )
            Connect-MgGraph -Scopes $requiredScopes -ErrorAction Stop
        }
        $context = Get-MgContext
    }
    Write-StatusMsg -Message "Conectado correctamente: $($context.Account) (Tenant: $($context.TenantId))" -Status "SUCCESS"
} catch {
    Write-StatusMsg -Message "Error al conectar con Microsoft graph: $($_.Exception.Message)" -Status "FAIL"
    Exit
}

# Control de throttling y reintentos con exponential backoff
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
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            
            if ($statusCode -eq 429 -or $statusCode -eq 503 -or $ex.Message -like "*429*" -or $ex.Message -like "*503*") {
                $attempt++
                if ($attempt -gt $MaxRetries) {
                    throw $_
                }
                $retryAfter = $BaseDelaySeconds * [math]::Pow(2, $attempt - 1)
                if ($_.Exception.Response -and $_.Exception.Response.Headers -and $_.Exception.Response.Headers["Retry-After"]) {
                    $headerVal = $_.Exception.Response.Headers["Retry-After"]
                    if ([int]::TryParse($headerVal, [ref]$null)) {
                        $retryAfter = [int]$headerVal
                    }
                }
                Write-StatusMsg -Message "Limite de peticiones de Microsoft graph alcanzado (HTTP $statusCode). Esperando $retryAfter segundos (Intento $attempt de $MaxRetries)..." -Status "WARN"
                Start-Sleep -Seconds $retryAfter
            } else {
                throw $_
            }
        }
    }
}

# Deteccion dinamica del hostname de SharePoint
$tenantHostName = "contoso.sharepoint.com"
try {
    $rootSiteRes = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/root"
    if ($rootSiteRes -and ($rootSiteRes.webUrl -or $rootSiteRes.WebUrl)) {
        $rUrl = if ($rootSiteRes.webUrl) { $rootSiteRes.webUrl } else { $rootSiteRes.WebUrl }
        $tenantHostName = ([System.Uri]$rUrl).Host
        Write-StatusMsg -Message "Dominio de SharePoint: $tenantHostName" -Status "INFO"
    }
} catch {
    if ($context -and $context.Account -and $context.Account -like "*@*.*") {
        $domainPart = ($context.Account -split "@")[1]
        $tenantPrefix = ($domainPart -split "\.")[0]
        if ($tenantPrefix) {
            $tenantHostName = "$tenantPrefix.sharepoint.com"
        }
    }
}

# Paginacion Graph API usando reintentos
function Invoke-GraphPaginatedRequest {
    param(
        [string]$Uri
    )
    $results = [System.Collections.Generic.List[PSObject]]::new()
    $nextUri = $Uri
    while ($nextUri) {
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
                if ($nextUri -match "https://[^/]+/(v1.0|beta)/(.*)") {
                    $nextUri = "$($Matches[1])/$($Matches[2])"
                }
            }
        } catch {
            Write-Verbose "Error en consulta a $nextUri : $($_.Exception.Message)"
            break
        }
    }
    return $results
}

# Traducir permisos a lenguaje claro
function Get-FriendlyActionName {
    param([string]$TechnicalPermission)
    
    if ([string]::IsNullOrEmpty($TechnicalPermission)) {
        return "[Acceso limitado]"
    }

    switch -Regex ($TechnicalPermission) {
        "Owner|Control Total|FullControl|Admin" {
            return "[Control total] Crear, editar, eliminar y administrar permisos"
        }
        "Write|Edicion|Member|Colaboracion" {
            return "[Leer y escribir] Leer, modificar, subir y eliminar archivos"
        }
        "Read|Lectura|Visitor|Visitante" {
            return "[Solo lectura] Ver y descargar archivos"
        }
        default {
            return "[Personalizado] $TechnicalPermission"
        }
    }
}

# Clasificacion de Sitio Principal vs Subsitio
function Get-SiteClassification {
    param(
        [string]$WebUrl,
        [string]$Title,
        [bool]$IsM365Group
    )
    if ([string]::IsNullOrEmpty($WebUrl)) {
        return @{ SiteType = "Sitio de sharepoint"; IsSubsite = $false; Category = "principal" }
    }
    
    $cleanUrl = $WebUrl.TrimEnd('/')
    $uri = [System.Uri]$cleanUrl
    $path = $uri.AbsolutePath.TrimEnd('/')
    $segments = $path.Split('/') | Where-Object { $_ -ne "" }
    
    $isSubsite = $false
    
    if ($segments.Count -gt 2 -and ($segments[0] -eq "sites" -or $segments[0] -eq "teams")) {
        $isSubsite = $true
    } elseif ($segments.Count -gt 1 -and $segments[0] -ne "sites" -and $segments[0] -ne "teams") {
        $isSubsite = $true
    }
    
    if ($isSubsite) {
        $siteType = "Subsitio de sharepoint"
        $category = "subsite"
    } elseif ($IsM365Group -or $cleanUrl -like "*msteams*" -or $cleanUrl -like "*/sites/group*") {
        $siteType = "Sitio de equipo (teams / m365)"
        $category = "teams"
    } elseif ($Title -like "*communication*" -or $cleanUrl -like "*/sites/CommunicationSite*") {
        $siteType = "Sitio de comunicacion"
        $category = "principal"
    } else {
        $siteType = "Sitio principal (coleccion de sitios)"
        $category = "principal"
    }

    return @{
        SiteType  = $siteType
        IsSubsite = $isSubsite
        Category  = $category
    }
}

# Escaneo recursivo de carpetas dentro de una biblioteca con permisos unicos (ruptura de herencia)
function Get-DriveFoldersWithUniquePermissions {
    param(
        [string]$SiteId,
        [string]$SiteTitle,
        [string]$SiteWebUrl,
        [string]$DriveId,
        [string]$DriveName,
        [string]$FolderPath = "",
        [string]$ItemId = "root",
        [int]$MaxDepth = 5
    )

    if ($MaxDepth -lt 0) { return }

    try {
        $childrenUri = if ($ItemId -eq "root") {
            "v1.0/sites/$SiteId/drives/$DriveId/root/children"
        } else {
            "v1.0/sites/$SiteId/drives/$DriveId/items/$ItemId/children"
        }

        $children = Invoke-GraphPaginatedRequest -Uri $childrenUri
        foreach ($item in $children) {
            if ($item.folder) {
                $itemName = if ($item.name) { $item.name } else { "Carpeta" }
                $currentPath = "$FolderPath/$itemName"
                $itemId = $item.id

                try {
                    $itemPerms = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$SiteId/drives/$DriveId/items/$itemId/permissions"
                    
                    $hasUnique = $false
                    foreach ($p in $itemPerms) {
                        if (-not $p.inheritedFrom) {
                            $hasUnique = $true
                            break
                        }
                    }

                    if ($hasUnique) {
                        $folderWebUrl = "$SiteWebUrl/$DriveName$currentPath"
                        $folderObj = [PSCustomObject]@{
                            Id        = "${SiteId}:folder:${itemId}"
                            Title     = "$SiteTitle -> Carpeta: $DriveName$currentPath"
                            WebUrl    = $folderWebUrl
                            SiteType  = "Carpeta con permisos unicos"
                            Category  = "folder"
                            IsFolder  = $true
                            RawPerms  = $itemPerms
                        }
                        if (-not $script:finalAuditedMap.ContainsKey($folderWebUrl.ToLower())) {
                            $script:finalAuditedMap[$folderWebUrl.ToLower()] = $true
                            $script:finalAuditedSites.Add($folderObj)
                            Write-StatusMsg -Message "Carpeta con permisos personalizados: $DriveName$currentPath" -Status "INFO"
                        }
                    }
                } catch {}

                Get-DriveFoldersWithUniquePermissions -SiteId $SiteId -SiteTitle $SiteTitle -SiteWebUrl $SiteWebUrl -DriveId $DriveId -DriveName $DriveName -FolderPath $currentPath -ItemId $itemId -MaxDepth ($MaxDepth - 1)
            }
        }
    } catch {}
}

# Exportar informe HTML
function Export-PermissionsToHtml {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$ReportData,
        [array]$UserSummaryData,
        [string]$FilePath,
        [string]$UserAccount,
        [string]$AuditedSiteName,
        [int]$TotalSitesCount,
        [int]$PrimarySitesCount,
        [int]$SubsitesCount,
        [int]$TeamSitesCount,
        [int]$FoldersCount,
        [string]$ElapsedTime
    )

    if (-not $ReportData -or $ReportData.Count -eq 0) {
        Write-Warning "No hay datos para generar el reporte HTML."
        return
    }

    # Helper para generar avatar de persona con iniciales al estilo Microsoft fluent ui
    function Get-UserPersonaHtml {
        param([string]$Name)
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "Usuario" }
        $cleanName = $Name -replace "^Grupo:\s*", ""
        $parts = $cleanName.Trim() -split "\s+"
        
        $initials = if ($parts.Count -ge 2) {
            ($parts[0].Substring(0, 1) + $parts[-1].Substring(0, 1)).ToUpper()
        } elseif ($cleanName.Length -ge 2) {
            $cleanName.Substring(0, 2).ToUpper()
        } else {
            $cleanName.ToUpper()
        }
        
        $colors = @("#0078d4", "#03787c", "#107c41", "#5c2d91", "#008272", "#004e8c", "#b4009e", "#d13438", "#881798")
        $charSum = 0
        foreach ($char in [char[]]$cleanName) { $charSum += [int]$char }
        $colorIndex = $charSum % $colors.Count
        $bgColor = $colors[$colorIndex]
        
        return "<span class=`"ms-avatar`" style=`"background-color: $bgColor;`">$initials</span>"
    }

    $siteGroups = $ReportData | Group-Object -Property SiteUrl
    $siteCardsHtml = [System.Text.StringBuilder]::new()

    foreach ($group in $siteGroups) {
        $firstItem = $group.Group[0]
        $siteTitle = if ($firstItem.SiteTitle) { $firstItem.SiteTitle } else { "Sitio de sharepoint" }
        $siteUrl = if ($firstItem.SiteUrl) { $firstItem.SiteUrl } else { "" }
        $siteType = if ($firstItem.SiteType) { $firstItem.SiteType } else { "Sitio" }

        if ($siteType -like "*Carpeta*") {
            $siteBadgeClass = "badge-folder"
            $siteCategoryAttr = "folder"
        } elseif ($siteType -like "*Subsitio*") {
            $siteBadgeClass = "badge-subsite"
            $siteCategoryAttr = "subsite"
        } elseif ($siteType -like "*Teams*" -or $siteType -like "*M365*") {
            $siteBadgeClass = "badge-teams-site"
            $siteCategoryAttr = "teams"
        } else {
            $siteBadgeClass = "badge-comm-site"
            $siteCategoryAttr = "principal"
        }

        $uniqueSiteUsersMap = @{}
        $uniqueSiteRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($item in $group.Group) {
            $uEmailStr = if ($item.UserEmail) { [string]$item.UserEmail } else { "no-email" }
            $uPermStr = if ($item.SitePermissions) { [string]$item.SitePermissions } else { "no-perm" }
            $key = ($uEmailStr.ToLower()) + "_" + ($uPermStr.ToLower())

            if (-not $uniqueSiteUsersMap.ContainsKey($key)) {
                $uniqueSiteUsersMap[$key] = $true
                $uniqueSiteRows.Add($item)
            }
        }

        $usersRowsHtml = [System.Text.StringBuilder]::new()
        foreach ($item in $uniqueSiteRows) {
            $friendlyAction = Get-FriendlyActionName -TechnicalPermission $item.SitePermissions

            $permBadgeClass = switch -Regex ($item.SitePermissions) {
                "Owner|Control Total|Admin" { "badge-owner" }
                "Write|Edicion|Member"      { "badge-write" }
                "Read|Lectura|Visitor"      { "badge-read" }
                default                     { "badge-generic" }
            }

            $inherBadgeClass = if ($item.HasInheritanceEnabled -like "*Si*") { "badge-inherited" } else { "badge-unique" }
            
            $sourceBadgeClass = switch -Regex ($item.AccessSource) {
                "Usuario Directo" { "badge-user" }
                "Entra ID"       { "badge-entragroup" }
                "SharePoint"     { "badge-spgroup" }
                "M365"           { "badge-app" }
                default          { "badge-generic" }
            }

            $uNameEsc = [System.Net.WebUtility]::HtmlEncode($item.UserName)
            $uEmailEsc = [System.Net.WebUtility]::HtmlEncode($item.UserEmail)
            $personaAvatarHtml = Get-UserPersonaHtml -Name $item.UserName
            $actionEsc = [System.Net.WebUtility]::HtmlEncode($friendlyAction)
            $sourceEsc = [System.Net.WebUtility]::HtmlEncode($item.AccessSource)
            $inherEsc = [System.Net.WebUtility]::HtmlEncode($item.HasInheritanceEnabled)
            $inherDetailEsc = [System.Net.WebUtility]::HtmlEncode($item.InheritanceDetail)

            [void]$usersRowsHtml.AppendLine("
            <tr>
                <td>
                    <div class=`"user-cell`">
                        $personaAvatarHtml
                        <div class=`"user-info`">
                            <span class=`"user-name`">$uNameEsc</span>
                            <span class=`"user-email`">$uEmailEsc</span>
                        </div>
                    </div>
                </td>
                <td><span class=`"badge $permBadgeClass`">$actionEsc</span></td>
                <td><span class=`"badge $sourceBadgeClass`">$sourceEsc</span></td>
                <td><span class=`"badge $inherBadgeClass`">$inherEsc</span></td>
                <td class=`"text-subtle`">$inherDetailEsc</td>
            </tr>
")
        }

        $siteTitleEsc = [System.Net.WebUtility]::HtmlEncode($siteTitle)
        $siteUrlEsc = [System.Net.WebUtility]::HtmlEncode($siteUrl)
        $siteTypeEsc = [System.Net.WebUtility]::HtmlEncode($siteType)
        $siteUsersCount = $uniqueSiteRows.Count

        [void]$siteCardsHtml.AppendLine("
        <div class=`"site-card`" data-site-category=`"$siteCategoryAttr`" data-site-title=`"$siteTitleEsc`">
            <div class=`"site-header`">
                <div>
                    <div class=`"site-title-row`">
                        <span class=`"site-icon-wrapper`">
                            <svg width=`"18`" height=`"18`" viewBox=`"0 0 20 20`" fill=`"currentColor`">
                                <path fill-rule=`"evenodd`" d=`"M4 4a2 2 0 012-2h8a2 2 0 012 2v12a2 2 0 01-2 2H6a2 2 0 01-2-2V4zm3 1a1 1 0 000 2h6a1 1 0 100-2H7zm0 4a1 1 0 000 2h6a1 1 0 100-2H7zm0 4a1 1 0 100 2h4a1 1 0 100-2H7z`" clip-rule=`"evenodd`"/>
                            </svg>
                        </span>
                        <span class=`"site-title`">$siteTitleEsc</span>
                        <span class=`"badge $siteBadgeClass`">$siteTypeEsc</span>
                    </div>
                    <a href=`"$siteUrlEsc`" target=`"_blank`" class=`"site-url-link`">
                        <svg width=`"12`" height=`"12`" viewBox=`"0 0 16 16`" fill=`"currentColor`" style=`"vertical-align: middle; margin-right: 3px;`">
                            <path fill-rule=`"evenodd`" d=`"M8.636 3.5a.5.5 0 0 0-.5-.5H1.5A1.5 1.5 0 0 0 0 4.5v10A1.5 1.5 0 0 0 1.5 16h10a1.5 1.5 0 0 0 1.5-1.5V7.864a.5.5 0 0 0-1 0V14.5a.5.5 0 0 1-.5.5h-10a.5.5 0 0 1-.5-.5v-10a.5.5 0 0 1 .5-.5h6.636a.5.5 0 0 0 .5-.5z`"/>
                            <path fill-rule=`"evenodd`" d=`"M16 .5a.5.5 0 0 0-.5-.5h-5a.5.5 0 0 0 0 1h3.793L6.146 9.146a.5.5 0 1 0 .708.708L15 1.707V5.5a.5.5 0 0 0 1 0v-5z`"/>
                        </svg>
                        $siteUrlEsc
                    </a>
                </div>
                <div class=`"site-meta`">
                    <span class=`"badge badge-generic`">$siteUsersCount usuarios e identidades</span>
                </div>
            </div>
            <div class=`"table-container`">
                <table>
                    <thead>
                        <tr>
                            <th>Usuario e identidad</th>
                            <th>Nivel de acceso</th>
                            <th>Origen del permiso</th>
                            <th>Hereda permisos</th>
                            <th>Detalle de herencia</th>
                        </tr>
                    </thead>
                    <tbody>
                        $($usersRowsHtml.ToString())
                    </tbody>
                </table>
            </div>
        </div>
")
    }

    # Renderizar matriz general por usuario interactiva con lista estructurada y desplegables
    $userMatrixRowsHtml = [System.Text.StringBuilder]::new()
    if ($UserSummaryData) {
        foreach ($user in $UserSummaryData) {
            $uNameEsc = [System.Net.WebUtility]::HtmlEncode($user.UserName)
            $uEmailEsc = [System.Net.WebUtility]::HtmlEncode($user.UserEmail)
            $personaAvatarHtml = Get-UserPersonaHtml -Name $user.UserName
            $friendlyActionSummary = Get-FriendlyActionName -TechnicalPermission $user.PermissionTypes
            $permTypesEsc = [System.Net.WebUtility]::HtmlEncode($friendlyActionSummary)

            $permBadgeClass = switch -Regex ($user.PermissionTypes) {
                "Owner|Control Total|Admin" { "badge-owner" }
                "Write|Edicion|Member"      { "badge-write" }
                "Read|Lectura|Visitor"      { "badge-read" }
                default                     { "badge-generic" }
            }

            # Construir estructura limpia de accesos (sitios vs carpetas)
            $itemsHtml = [System.Text.StringBuilder]::new()
            $allUserItems = [System.Collections.Generic.List[PSObject]]::new()
            if ($user.SiteItems) { foreach ($si in $user.SiteItems) { $allUserItems.Add(@{ Type = "site"; Name = $si }) } }
            if ($user.FolderItems) { foreach ($fi in $user.FolderItems) { $allUserItems.Add(@{ Type = "folder"; Name = $fi }) } }

            if ($allUserItems.Count -le 2) {
                foreach ($item in $allUserItems) {
                    $itemEsc = [System.Net.WebUtility]::HtmlEncode($item.Name)
                    $badgeCls = if ($item.Type -eq "site") { "badge-comm-site" } else { "badge-folder" }
                    $typeTag = if ($item.Type -eq "site") { "Sitio" } else { "Carpeta" }
                    [void]$itemsHtml.AppendLine("<div class='access-pill-row'><span class='badge $badgeCls'>$typeTag</span> <span class='access-item-name'>$itemEsc</span></div>")
                }
            } else {
                $sitesBadge = if ($user.SitesCount -gt 0) { "<span class='badge badge-comm-site'>$($user.SitesCount) sitio(s)</span> " } else { "" }
                $foldersBadge = if ($user.FoldersCount -gt 0) { "<span class='badge badge-folder'>$($user.FoldersCount) carpeta(s)</span>" } else { "" }
                
                [void]$itemsHtml.AppendLine("
                <details class='user-access-details'>
                    <summary class='user-access-summary'>
                        $sitesBadge $foldersBadge
                        <span class='view-more-link'>Ver $($allUserItems.Count) accesos &#9660;</span>
                    </summary>
                    <ul class='access-items-list'>
                ")
                foreach ($item in $allUserItems) {
                    $itemEsc = [System.Net.WebUtility]::HtmlEncode($item.Name)
                    $badgeCls = if ($item.Type -eq "site") { "badge-comm-site" } else { "badge-folder" }
                    $typeTag = if ($item.Type -eq "site") { "Sitio" } else { "Carpeta" }
                    [void]$itemsHtml.AppendLine("<li><span class='badge $badgeCls'>$typeTag</span> $itemEsc</li>")
                }
                [void]$itemsHtml.AppendLine("
                    </ul>
                </details>
                ")
            }

            [void]$userMatrixRowsHtml.AppendLine("
            <tr>
                <td>
                    <div class=`"user-cell`">
                        $personaAvatarHtml
                        <div class=`"user-info`">
                            <span class=`"user-name`">$uNameEsc</span>
                            <span class=`"user-email`">$uEmailEsc</span>
                        </div>
                    </div>
                </td>
                <td>
                    <div class=`"user-access-count`">
                        <span class=`"badge badge-generic`">$($user.TotalSitesAccess) accesos</span>
                    </div>
                </td>
                <td><span class=`"badge $permBadgeClass`">$permTypesEsc</span></td>
                <td>$($itemsHtml.ToString())</td>
            </tr>
")
        }
    }

    $uniqueUsersCount = if ($UserSummaryData) { $UserSummaryData.Count } else { 0 }
    $userAccountEsc = [System.Net.WebUtility]::HtmlEncode($UserAccount)
    $auditedSiteNameEsc = [System.Net.WebUtility]::HtmlEncode($AuditedSiteName)
    $dateNowStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $cardsBodyHtml = $siteCardsHtml.ToString()
    $matrixBodyHtml = $userMatrixRowsHtml.ToString()

    $htmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Auditoria de permisos - Microsoft sharepoint online</title>
    <style>
        :root {
            /* Microsoft fluent ui design tokens - Light mode (Sharepoint default) */
            --sp-brand: #03787c;
            --sp-brand-hover: #025c5f;
            --sp-brand-light: #e6f2f3;
            --m365-blue: #0078d4;
            --m365-suite-bg: #0078d4;
            
            --bg-main: #faf9f8;
            --bg-card: #ffffff;
            --bg-header: #ffffff;
            --bg-site-header: #f3f2f1;
            --bg-table-header: #faf9f8;
            --bg-table-hover: #f3f2f1;
            --bg-input: #ffffff;
            --bg-details: #faf9f8;
            
            --text-primary: #201f1e;
            --text-secondary: #605e5c;
            --text-heading: #11100f;
            --text-user-name: #201f1e;
            --text-link: #0078d4;
            
            --border-color: #edebe9;
            --border-subtle: #e1dfdd;
            --border-header: #e1dfdd;
            --accent-cyan: #03787c;
            --accent-indigo: #0078d4;
            
            --shadow-card: 0 1.6px 3.6px 0 rgba(0,0,0,0.132), 0 0.3px 0.9px 0 rgba(0,0,0,0.108);
            --shadow-elevated: 0 3.2px 7.2px 0 rgba(0,0,0,0.132), 0 0.6px 1.8px 0 rgba(0,0,0,0.108);

            /* Badges fluent ui light mode */
            --badge-teams-bg: #f3f2f1; --badge-teams-txt: #464775; --badge-teams-border: #6264a7;
            --badge-comm-bg: #e6f2f3; --badge-comm-txt: #03787c; --badge-comm-border: #03787c;
            --badge-subsite-bg: #fff4ce; --badge-subsite-txt: #797775; --badge-subsite-border: #d97706;
            --badge-folder-bg: #deecf9; --badge-folder-txt: #005a9e; --badge-folder-border: #106ebe;

            --badge-owner-bg: #fde8e8; --badge-owner-txt: #a80000; --badge-owner-border: #f8c2c2;
            --badge-write-bg: #fff4ce; --badge-write-txt: #8a3b00; --badge-write-border: #feea9f;
            --badge-read-bg: #dff6dd; --badge-read-txt: #107c41; --badge-read-border: #92e08f;
            --badge-generic-bg: #f3f2f1; --badge-generic-txt: #605e5c; --badge-generic-border: #e1dfdd;

            --badge-inherited-bg: #deecf9; --badge-inherited-txt: #0078d4; --badge-inherited-border: #c7e0f4;
            --badge-unique-bg: #fff4ce; --badge-unique-txt: #8a3b00; --badge-unique-border: #feea9f;

            --badge-user-bg: #deecf9; --badge-user-txt: #005a9e;
            --badge-entragroup-bg: #f3e8ff; --badge-entragroup-txt: #5c2d91;
            --badge-spgroup-bg: #e6f2f3; --badge-spgroup-txt: #03787c;
            --badge-app-bg: #edf5f5; --badge-app-txt: #008272;
        }

        [data-theme="dark"] {
            /* Microsoft fluent ui dark theme */
            --sp-brand: #00a8ac;
            --sp-brand-hover: #00c7cb;
            --sp-brand-light: #163638;
            --m365-blue: #2899f5;
            --m365-suite-bg: #0f172a;
            
            --bg-main: #11100f;
            --bg-card: #1b1a19;
            --bg-header: #1b1a19;
            --bg-site-header: #252423;
            --bg-table-header: #1b1a19;
            --bg-table-hover: #292827;
            --bg-input: #252423;
            --bg-details: #11100f;
            
            --text-primary: #f3f2f1;
            --text-secondary: #a19f9d;
            --text-heading: #ffffff;
            --text-user-name: #ffffff;
            --text-link: #2899f5;
            
            --border-color: #292827;
            --border-subtle: #323130;
            --border-header: #292827;
            --accent-cyan: #00a8ac;
            --accent-indigo: #2899f5;
            
            --shadow-card: 0 2px 8px rgba(0, 0, 0, 0.4);
            --shadow-elevated: 0 4px 16px rgba(0, 0, 0, 0.5);

            /* Badges dark mode */
            --badge-teams-bg: rgba(98, 100, 167, 0.25); --badge-teams-txt: #a6a8d6; --badge-teams-border: rgba(98, 100, 167, 0.5);
            --badge-comm-bg: rgba(3, 120, 124, 0.25); --badge-comm-txt: #4cd9dc; --badge-comm-border: rgba(3, 120, 124, 0.5);
            --badge-subsite-bg: rgba(217, 119, 6, 0.25); --badge-subsite-txt: #fcd34d; --badge-subsite-border: rgba(217, 119, 6, 0.5);
            --badge-folder-bg: rgba(0, 90, 158, 0.25); --badge-folder-txt: #6cb8f6; --badge-folder-border: rgba(0, 90, 158, 0.5);

            --badge-owner-bg: rgba(209, 52, 56, 0.25); --badge-owner-txt: #f87171; --badge-owner-border: rgba(209, 52, 56, 0.5);
            --badge-write-bg: rgba(217, 119, 6, 0.25); --badge-write-txt: #fbbf24; --badge-write-border: rgba(217, 119, 6, 0.5);
            --badge-read-bg: rgba(16, 124, 65, 0.25); --badge-read-txt: #4ade80; --badge-read-border: rgba(16, 124, 65, 0.5);
            --badge-generic-bg: rgba(161, 159, 157, 0.2); --badge-generic-txt: #d2d0ce; --badge-generic-border: rgba(161, 159, 157, 0.4);

            --badge-inherited-bg: rgba(40, 153, 245, 0.2); --badge-inherited-txt: #70baff; --badge-inherited-border: rgba(40, 153, 245, 0.4);
            --badge-unique-bg: rgba(217, 119, 6, 0.2); --badge-unique-txt: #fbbf24; --badge-unique-border: rgba(217, 119, 6, 0.4);

            --badge-user-bg: rgba(40, 153, 245, 0.2); --badge-user-txt: #70baff;
            --badge-entragroup-bg: rgba(180, 0, 158, 0.2); --badge-entragroup-txt: #e37bee;
            --badge-spgroup-bg: rgba(0, 168, 172, 0.2); --badge-spgroup-txt: #4cd9dc;
            --badge-app-bg: rgba(0, 130, 114, 0.2); --badge-app-txt: #42d1bd;
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

        /* Top suite bar Microsoft 365 */
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
        .suite-left {
            display: flex;
            align-items: center;
            gap: 12px;
        }
        .waffle-icon { opacity: 0.95; cursor: default; }
        .sp-icon { display: flex; align-items: center; }
        .suite-title { font-weight: 700; font-size: 1.05rem; letter-spacing: 0.2px; }
        .suite-subtitle { opacity: 0.85; font-size: 0.88rem; font-weight: 400; }
        
        .suite-right {
            display: flex;
            align-items: center;
            gap: 18px;
            font-size: 0.82rem;
        }
        .suite-meta-item { display: flex; gap: 6px; }
        .meta-label { opacity: 0.75; }
        .meta-value { font-weight: 600; }
        .suite-meta-badge {
            background: rgba(255,255,255,0.18);
            padding: 3px 10px;
            border-radius: 12px;
            font-weight: 600;
        }

        .container { width: 100%; max-width: 100%; margin: 0; padding: 0 24px; }
        
        /* Header section inside container */
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
        .page-header p {
            color: var(--text-secondary);
            font-size: 0.9rem;
            margin-top: 2px;
        }

        /* Fluent message bar */
        .ms-message-bar {
            background: var(--bg-card);
            border: 1px solid var(--border-subtle);
            border-left: 4px solid var(--sp-brand);
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
        .ms-message-bar svg { color: var(--sp-brand); flex-shrink: 0; }
        .ms-message-bar strong { color: var(--text-heading); }

        /* Metric kpi cards */
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
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
            transition: all 0.2s ease;
        }
        .metric-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 4px;
            height: 100%;
            background-color: var(--sp-brand);
        }
        .metric-card.card-primary::before { background-color: var(--sp-brand); }
        .metric-card.card-subsite::before { background-color: #d97706; }
        .metric-card.card-folder::before { background-color: #005a9e; }
        .metric-card.card-teams::before { background-color: #6264a7; }
        .metric-card.card-users::before { background-color: #107c41; }

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
        .metric-card .subtext {
            font-size: 0.78rem;
            color: var(--text-secondary);
            margin-top: 4px;
        }

        /* Toolbar & pivot tabs */
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
            border-radius: 2px 2px 0 0;
        }
        .tab-btn:hover {
            color: var(--sp-brand);
            background: var(--bg-site-header);
        }
        .tab-btn.active {
            color: var(--sp-brand);
            border-bottom: 2px solid var(--sp-brand);
            background: transparent;
        }

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
            max-width: 400px;
            display: flex;
            align-items: center;
        }
        .search-icon {
            position: absolute;
            left: 12px;
            color: var(--text-secondary);
            pointer-events: none;
        }
        .search-box input {
            width: 100%;
            padding: 8px 12px 8px 34px;
            background: var(--bg-input);
            border: 1px solid var(--border-subtle);
            border-radius: 2px;
            color: var(--text-primary);
            font-size: 0.88rem;
            outline: none;
            transition: all 0.2s ease;
        }
        .search-box input:focus {
            border-color: var(--sp-brand);
            box-shadow: 0 0 0 1px var(--sp-brand);
        }

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
        .theme-toggle-btn:hover {
            border-color: var(--sp-brand);
            color: var(--sp-brand);
            background: var(--bg-site-header);
        }

        /* Site cards */
        .site-card {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 4px;
            margin-bottom: 20px;
            overflow: hidden;
            box-shadow: var(--shadow-card);
            transition: background-color 0.2s ease, border-color 0.2s ease;
        }
        .site-header {
            background: var(--bg-site-header);
            border-bottom: 1px solid var(--border-color);
            padding: 14px 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 12px;
        }
        .site-title-row { display: flex; align-items: center; gap: 10px; }
        .site-icon-wrapper { color: var(--sp-brand); display: flex; align-items: center; }
        .site-title { font-size: 1.1rem; font-weight: 600; color: var(--text-heading); }
        .site-url-link { font-size: 0.84rem; color: var(--text-link); text-decoration: none; display: inline-block; margin-top: 3px; }
        .site-url-link:hover { text-decoration: underline; }

        /* Tables - Details list style */
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

        /* User persona avatar cell */
        .user-cell {
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .ms-avatar {
            width: 32px;
            height: 32px;
            border-radius: 50%;
            color: #ffffff;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 0.78rem;
            font-weight: 600;
            flex-shrink: 0;
            box-shadow: 0 1px 2px rgba(0,0,0,0.12);
        }
        .user-info { display: flex; flex-direction: column; }
        .user-name { font-weight: 600; color: var(--text-user-name); font-size: 0.86rem; }
        .user-email { font-size: 0.75rem; color: var(--text-secondary); }

        /* Fluent badges */
        .badge {
            display: inline-block;
            padding: 3px 10px;
            border-radius: 12px;
            font-size: 0.75rem;
            font-weight: 600;
            transition: all 0.2s ease;
        }
        .badge-teams-site { background: var(--badge-teams-bg); color: var(--badge-teams-txt); border: 1px solid var(--badge-teams-border); }
        .badge-comm-site { background: var(--badge-comm-bg); color: var(--badge-comm-txt); border: 1px solid var(--badge-comm-border); }
        .badge-subsite { background: var(--badge-subsite-bg); color: var(--badge-subsite-txt); border: 1px solid var(--badge-subsite-border); }
        .badge-folder { background: var(--badge-folder-bg); color: var(--badge-folder-txt); border: 1px solid var(--badge-folder-border); }

        .badge-owner { background: var(--badge-owner-bg); color: var(--badge-owner-txt); border: 1px solid var(--badge-owner-border); }
        .badge-write { background: var(--badge-write-bg); color: var(--badge-write-txt); border: 1px solid var(--badge-write-border); }
        .badge-read { background: var(--badge-read-bg); color: var(--badge-read-txt); border: 1px solid var(--badge-read-border); }
        .badge-generic { background: var(--badge-generic-bg); color: var(--badge-generic-txt); border: 1px solid var(--badge-generic-border); }

        .badge-inherited { background: var(--badge-inherited-bg); color: var(--badge-inherited-txt); border: 1px solid var(--badge-inherited-border); }
        .badge-unique { background: var(--badge-unique-bg); color: var(--badge-unique-txt); border: 1px solid var(--badge-unique-border); }

        .badge-user { background: var(--badge-user-bg); color: var(--badge-user-txt); }
        .badge-entragroup { background: var(--badge-entragroup-bg); color: var(--badge-entragroup-txt); }
        .badge-spgroup { background: var(--badge-spgroup-bg); color: var(--badge-spgroup-txt); }
        .badge-app { background: var(--badge-app-bg); color: var(--badge-app-txt); }

        /* User access summary & details */
        .user-access-details {
            background: var(--bg-details);
            border: 1px solid var(--border-subtle);
            border-radius: 4px;
            padding: 8px 12px;
        }
        .user-access-summary {
            cursor: pointer;
            font-size: 0.82rem;
            font-weight: 600;
            color: var(--sp-brand);
            display: flex;
            align-items: center;
            gap: 8px;
            flex-wrap: wrap;
            outline: none;
        }
        .user-access-summary:hover { color: var(--text-heading); }
        .view-more-link { margin-left: auto; font-size: 0.78rem; color: var(--text-link); text-decoration: underline; }
        .access-items-list {
            list-style: none;
            margin-top: 8px;
            padding-top: 8px;
            border-top: 1px solid var(--border-subtle);
            max-height: 220px;
            overflow-y: auto;
        }
        .access-items-list li {
            padding: 5px 4px;
            font-size: 0.8rem;
            color: var(--text-primary);
            border-bottom: 1px solid var(--border-subtle);
            display: flex;
            align-items: center;
            gap: 8px;
            word-break: break-word;
        }
        .access-items-list li:last-child { border-bottom: none; }
        .access-pill-row { margin-bottom: 4px; font-size: 0.82rem; display: flex; align-items: center; gap: 8px; }
        .access-item-name { color: var(--text-primary); }

        .text-subtle { font-size: 0.8rem; color: var(--text-secondary); }
        .view-section { margin-bottom: 32px; }
        .section-title {
            font-size: 1.15rem;
            font-weight: 600;
            color: var(--text-heading);
            margin-bottom: 14px;
            border-left: 4px solid var(--sp-brand);
            padding-left: 10px;
        }

        /* Footer */
        .footer {
            margin-top: 40px;
            padding-top: 20px;
            border-top: 1px solid var(--border-color);
            text-align: center;
            font-size: 0.82rem;
            color: var(--text-secondary);
        }
        .footer-content {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 10px;
            flex-wrap: wrap;
        }
        .footer-separator { opacity: 0.4; }
    </style>
</head>
<body>
    <!-- Top suite bar Microsoft 365 -->
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
            <div class="sp-icon">
                <svg viewBox="0 0 24 24" width="22" height="22" fill="none">
                    <rect width="24" height="24" rx="4" fill="#03787C"/>
                    <path d="M12 4C7.58 4 4 7.58 4 12C4 16.42 7.58 20 12 20C16.42 20 20 16.42 20 12C20 7.58 16.42 4 12 4ZM12 17.5C8.96 17.5 6.5 15.04 6.5 12C6.5 8.96 8.96 6.5 12 6.5C15.04 6.5 17.5 8.96 17.5 12C17.5 15.04 15.04 17.5 12 17.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M14.5 12C14.5 13.38 13.38 14.5 12 14.5C10.62 14.5 9.5 13.38 9.5 12C9.5 10.62 10.62 9.5 12 9.5C13.38 9.5 14.5 10.62 14.5 12Z" fill="white"/>
                </svg>
            </div>
            <span class="suite-title">SharePoint</span>
            <span class="suite-subtitle">| Auditoria de permisos</span>
        </div>
        <div class="suite-right">
            <div class="suite-meta-item">
                <span class="meta-label">Tenant:</span>
                <span class="meta-value">$userAccountEsc</span>
            </div>
            <div class="suite-meta-item">
                <span class="meta-label">Fecha:</span>
                <span class="meta-value">$dateNowStr</span>
            </div>
            <div class="suite-meta-badge">
                ⚡ $ElapsedTime
            </div>
        </div>
    </div>

    <div class="container">
        <div class="page-header">
            <div>
                <h1>Auditoria de permisos e identidades</h1>
                <p>Analisis detallado para el sitio <strong>$auditedSiteNameEsc</strong></p>
            </div>
        </div>

        <div class="ms-message-bar">
            <svg width="20" height="20" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd"/>
            </svg>
            <div>
                <strong>Estructura de sharepoint online:</strong>
                <span><b>Sitio principal</b> es la coleccion raiz. <b>Subsitio</b> es una web secundaria. <b>Carpeta con permisos unicos</b> indica ruptura explicita de herencia en la biblioteca de documentos.</span>
            </div>
        </div>

        <div class="metrics-grid">
            <div class="metric-card card-primary">
                <div class="title">Total espacios</div>
                <div class="value">$TotalSitesCount</div>
                <div class="subtext">Analizados en total</div>
            </div>
            <div class="metric-card card-primary">
                <div class="title">Sitios principales</div>
                <div class="value">$PrimarySitesCount</div>
                <div class="subtext">Colecciones independientes</div>
            </div>
            <div class="metric-card card-subsite">
                <div class="title">Subsitios</div>
                <div class="value">$SubsitesCount</div>
                <div class="subtext">Sitios secundarios/hijos</div>
            </div>
            <div class="metric-card card-folder">
                <div class="title">Carpetas / bibliotecas</div>
                <div class="value">$FoldersCount</div>
                <div class="subtext">Con permisos unicos</div>
            </div>
            <div class="metric-card card-teams">
                <div class="title">Equipos teams</div>
                <div class="value">$TeamSitesCount</div>
                <div class="subtext">Sitios m365</div>
            </div>
            <div class="metric-card card-users">
                <div class="title">Usuarios unicos</div>
                <div class="value">$uniqueUsersCount</div>
                <div class="subtext">Identidades detectadas</div>
            </div>
        </div>

        <div class="toolbar">
            <div class="filter-tabs">
                <button class="tab-btn active" onclick="switchView('sites', event)">Vista por sitio / subsitio / carpeta ($TotalSitesCount)</button>
                <button class="tab-btn" onclick="switchView('users', event)">Vista matriz por usuario ($uniqueUsersCount)</button>
                <button class="tab-btn" onclick="filterCategory('principal', event)">Sitios principales ($PrimarySitesCount)</button>
                <button class="tab-btn" onclick="filterCategory('subsite', event)">Subsitios ($SubsitesCount)</button>
                <button class="tab-btn" onclick="filterCategory('folder', event)">Carpetas unicas ($FoldersCount)</button>
                <button class="tab-btn" onclick="filterCategory('teams', event)">Equipos teams ($TeamSitesCount)</button>
            </div>
            <div class="toolbar-controls">
                <div class="search-box">
                    <svg class="search-icon" width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
                        <path fill-rule="evenodd" d="M11.742 10.344a6.5 6.5 0 1 0-1.397 1.398h-.001c.03.04.062.078.098.115l3.85 3.85a1 1 0 0 0 1.415-1.414l-3.85-3.85a1.007 1.007 0 0 0-.115-.1zM12 6.5a5.5 5.5 0 1 1-11 0 5.5 5.5 0 0 1 11 0z"/>
                    </svg>
                    <input type="text" id="tableSearch" placeholder="Buscar usuario, correo, sitio o carpeta..." onkeyup="searchSites()">
                </div>
                <button id="themeToggleBtn" class="theme-toggle-btn" onclick="toggleTheme()" title="Cambiar tema de color">
                    <span id="themeIcon"><svg width="14" height="14" viewBox="0 0 20 20" fill="currentColor"><path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z"/></svg></span> <span id="themeText">Modo oscuro</span>
                </button>
            </div>
        </div>

        <!-- VISTA 1: ORGANIZADA POR SITIO Y SUBSITIO Y CARPETAS -->
        <div id="sitesView" class="view-section">
            <div class="section-title">Desglose de permisos por sitio, subsitio y carpetas con permisos unicos</div>
            <div id="sitesContainer">
                $cardsBodyHtml
            </div>
        </div>

        <!-- VISTA 2: MATRIZ POR USUARIO -->
        <div id="usersView" class="view-section" style="display: none;">
            <div class="section-title">Matriz completa por usuario e identidad</div>
            <div class="site-card">
                <div class="table-container">
                    <table>
                        <thead>
                            <tr>
                                <th>Usuario e identidad</th>
                                <th>Total de accesos</th>
                                <th>Nivel de acceso principal</th>
                                <th>Lista de sitios y carpetas a los que tiene acceso</th>
                            </tr>
                        </thead>
                        <tbody>
                            $matrixBodyHtml
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <div class="footer">
            <div class="footer-content">
                <svg viewBox="0 0 24 24" width="16" height="16" fill="none">
                    <rect width="24" height="24" rx="4" fill="#03787C"/>
                    <path d="M12 4C7.58 4 4 7.58 4 12C4 16.42 7.58 20 12 20C16.42 20 20 16.42 20 12C20 7.58 16.42 4 12 4ZM12 17.5C8.96 17.5 6.5 15.04 6.5 12C6.5 8.96 8.96 6.5 12 6.5C15.04 6.5 17.5 8.96 17.5 12C17.5 15.04 15.04 17.5 12 17.5Z" fill="white" fill-opacity="0.3"/>
                    <path d="M14.5 12C14.5 13.38 13.38 14.5 12 14.5C10.62 14.5 9.5 13.38 9.5 12C9.5 10.62 10.62 9.5 12 9.5C13.38 9.5 14.5 10.62 14.5 12Z" fill="white"/>
                </svg>
                <span>Microsoft 365 - SharePoint online auditoria de permisos</span>
                <span class="footer-separator">&bull;</span>
                <span>Autor: Alejandro Suarez Fernandez (@alexsf93)</span>
            </div>
        </div>
    </div>

    <script>
        var currentFilter = 'all';

        function toggleTheme() {
            var currentTheme = document.documentElement.getAttribute('data-theme') || 'light';
            var newTheme = currentTheme === 'dark' ? 'light' : 'dark';
            setTheme(newTheme);
        }

        function setTheme(theme) {
            document.documentElement.setAttribute('data-theme', theme);
            try {
                localStorage.setItem('spo_audit_theme', theme);
            } catch (e) {}

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
            try {
                savedTheme = localStorage.getItem('spo_audit_theme') || 'light';
            } catch (e) {}
            setTheme(savedTheme);
        })();

        function switchView(viewName, event) {
            document.querySelectorAll('.tab-btn').forEach(function(btn) { btn.classList.remove('active'); });
            if (event && event.target) {
                event.target.classList.add('active');
            }

            if (viewName === 'sites') {
                currentFilter = 'all';
                document.getElementById('sitesView').style.display = 'block';
                document.getElementById('usersView').style.display = 'none';
                applyFilters();
            } else if (viewName === 'users') {
                document.getElementById('sitesView').style.display = 'none';
                document.getElementById('usersView').style.display = 'block';
                applyFilters();
            }
        }

        function filterCategory(type, event) {
            document.querySelectorAll('.tab-btn').forEach(function(btn) { btn.classList.remove('active'); });
            if (event && event.target) {
                event.target.classList.add('active');
            }
            document.getElementById('sitesView').style.display = 'block';
            document.getElementById('usersView').style.display = 'none';
            currentFilter = type;
            applyFilters();
        }

        function searchSites() {
            applyFilters();
        }

        function applyFilters() {
            var searchVal = document.getElementById("tableSearch").value.toLowerCase();
            
            var cards = document.querySelectorAll('#sitesContainer .site-card');
            cards.forEach(function(card) {
                var category = card.getAttribute('data-site-category') || '';
                var textContent = card.textContent.toLowerCase();

                var matchesFilter = (currentFilter === 'all' || currentFilter === category);
                var matchesSearch = (searchVal === '' || textContent.indexOf(searchVal) > -1);

                if (matchesFilter && matchesSearch) {
                    card.style.display = "";
                } else {
                    card.style.display = "none";
                }
            });

            var userRows = document.querySelectorAll('#usersView tbody tr');
            userRows.forEach(function(row) {
                var textContent = row.textContent.toLowerCase();
                if (searchVal === '' || textContent.indexOf(searchVal) > -1) {
                    row.style.display = "";
                } else {
                    row.style.display = "none";
                }
            });
        }
    </script>
</body>
</html>
"@

    $resolvedPath = if ([System.IO.Path]::IsPathRooted($FilePath)) {
        $FilePath
    } else {
        [System.IO.Path]::Combine($PWD.Path, $FilePath)
    }

    [System.IO.File]::WriteAllText($resolvedPath, $htmlContent, [System.Text.Encoding]::UTF8)
    Write-StatusMsg -Message "Informe HTML guardado en la ruta absoluta: $resolvedPath" -Status "SUCCESS"

    if ($env:ACC_CLOUD_SHELL -or $env:AZURE_HTTP_USER_AGENT -or ($PSVersionTable.Platform -eq 'Unix')) {
        Write-Host "  [i] Entorno Azure Cloud Shell / Linux detectado." -ForegroundColor Cyan
        Write-Host "      Para descargar el reporte HTML a tu equipo local, ejecuta en Cloud Shell:" -ForegroundColor Cyan
        Write-Host "      download `"$resolvedPath`"`n" -ForegroundColor Yellow
    }
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Paso 2: Descubrimiento de sitios principales en el tenant
Write-StepHeader -StepNumber 2 -TotalSteps 6 -Title "Busqueda de sitios principales en el tenant"

Write-StatusMsg -Message "Buscando sitios en sharepoint..." -Status "WORKING"
$allSitesRaw = [System.Collections.Generic.List[PSObject]]::new()
$m365GroupUrls = @{}
$m365GroupIdMap = @{}

# A. Si se proporciono parametro -SiteUrl / -SiteName, intentar resolucion directa primero
$targetSiteFilter = if ($SiteUrl) { $SiteUrl } elseif ($SiteName) { $SiteName } else { "" }
if ($targetSiteFilter) {
    Write-StatusMsg -Message "Filtro indicado por parametro: '$targetSiteFilter'" -Status "INFO"
    try {
        $targetHost = $tenantHostName
        $cleanFilter = $targetSiteFilter
        if ($targetSiteFilter -match "https://([^/]+)/sites/(.*)") {
            $targetHost = $Matches[1]
            $cleanFilter = $Matches[2]
        } elseif ($targetSiteFilter -match "https://([^/]+)") {
            $targetHost = $Matches[1]
            $cleanFilter = ""
        } else {
            $cleanFilter = ($targetSiteFilter -replace "^/sites/", "") -replace "^/", ""
        }

        if ($cleanFilter) {
            $directSite = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/${targetHost}:/sites/$cleanFilter"
            if ($directSite -and ($directSite.id -or $directSite.webUrl)) {
                $allSitesRaw.Add($directSite)
            }
        }
    } catch {
        Write-Verbose "No se pudo resolver directamente el sitio '$targetSiteFilter': $($_.Exception.Message)"
    }
}

# B. Consultar la API de busqueda de Graph (wildcard global y por palabras clave con $top=999)
Write-StatusMsg -Message "Consultando el catalogo exhaustivo de sitios..." -Status "WORKING"
try {
    $wildcardRes = Invoke-GraphPaginatedRequest -Uri "v1.0/sites?search=*&`$top=999"
    if ($wildcardRes) {
        foreach ($item in $wildcardRes) { $allSitesRaw.Add($item) }
    }
} catch {}

$searchTerms = 97..122 | ForEach-Object { [char]$_ }
$searchTerms += 0..9 | ForEach-Object { [string]$_ }
$searchTerms += @("msteams", "rrhh", "level", "fly", "test", "viva", "http", "administracion", "site")

foreach ($term in $searchTerms) {
    try {
        $res = Invoke-GraphPaginatedRequest -Uri "v1.0/sites?search=$term&`$top=999"
        if ($res) {
            foreach ($item in $res) { $allSitesRaw.Add($item) }
        }
    } catch {}
}

# C. Descubrir sitios asociados a grupos de M365 y teams (con limpieza avanzada de acentos y caracteres)
Write-StatusMsg -Message "Buscando sitios asociados a teams y grupos de Microsoft 365..." -Status "WORKING"
try {
    $m365Groups = Invoke-GraphPaginatedRequest -Uri "v1.0/groups?`$top=999"
    foreach ($grp in $m365Groups) {
        $gId = if ($grp.id) { $grp.id } else { $grp.Id }
        if ($gId) {
            $groupSite = $null
            try {
                $groupSite = Invoke-GraphRequestWithRetry -Uri "v1.0/groups/$gId/sites/root"
            } catch {}

            if (-not $groupSite) {
                $cleanName1 = Clean-SitePath -Text $grp.mailNickname
                $cleanName2 = Clean-SitePath -Text $grp.displayName
                $possibleNames = @($grp.mailNickname, $grp.displayName, $cleanName1, $cleanName2) | Select-Object -Unique
                foreach ($name in $possibleNames) {
                    if ($name) {
                        try {
                            $cleanName = [System.Uri]::EscapeDataString($name)
                            $groupSite = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/${tenantHostName}:/sites/$cleanName"
                            if ($groupSite -and ($groupSite.id -or $groupSite.webUrl)) { break }
                        } catch {}
                    }
                }
            }

            if ($groupSite -and ($groupSite.id -or $groupSite.webUrl)) {
                $allSitesRaw.Add($groupSite)
                $gWebUrl = if ($groupSite.webUrl) { $groupSite.webUrl } else { $groupSite.WebUrl }
                if ($gWebUrl) {
                    $m365GroupUrls[$gWebUrl.ToLower()] = $true
                    $m365GroupIdMap[$gWebUrl.ToLower()] = $gId
                }
            }
        }
    }
} catch {}

# C.2 Importar sitios desde CSV únicamente si se especifico el parametro -CsvPath
if ([string]::IsNullOrWhiteSpace($CsvPath) -eq $false -and (Test-Path $CsvPath)) {
    Write-StatusMsg -Message "Importando lista de sitios desde el CSV especificado: '$CsvPath'..." -Status "WORKING"
    try {
        $csvContent = Import-Csv -Path $CsvPath -Delimiter ";" -ErrorAction SilentlyContinue
        if (-not $csvContent) {
            $csvContent = Import-Csv -Path $CsvPath -Delimiter "," -ErrorAction SilentlyContinue
        }
        if ($csvContent) {
            $csvLoadedCount = 0
            foreach ($row in $csvContent) {
                $siteUrlVal = if ($row.URL) { $row.URL } elseif ($row.Url) { $row.Url } elseif ($row.'WebUrl') { $row.'WebUrl' } else { "" }
                $siteNameVal = if ($row.'Site name') { $row.'Site name' } elseif ($row.Title) { $row.Title } else { "" }

                if ($siteUrlVal -and $siteUrlVal -like "http*") {
                    $cleanPath = ($siteUrlVal -replace "https://[^/]+", "") -replace "^/sites/", "" -replace "^/", ""
                    $csvSite = $null
                    if ($cleanPath) {
                        try {
                            $csvSite = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/${tenantHostName}:/sites/$cleanPath"
                        } catch {}
                    }
                    if (-not $csvSite) {
                        $csvSite = [PSCustomObject]@{
                            id        = $siteUrlVal
                            displayName = if ($siteNameVal) { $siteNameVal } else { $cleanPath }
                            webUrl    = $siteUrlVal
                        }
                    }
                    if ($csvSite) {
                        $allSitesRaw.Add($csvSite)
                        $csvLoadedCount++
                    }
                }
            }
            Write-StatusMsg -Message "Se han importado $csvLoadedCount sitios desde el CSV." -Status "SUCCESS"
        }
    } catch {
        Write-StatusMsg -Message "Error al leer el archivo CSV '$CsvPath': $($_.Exception.Message)" -Status "WARN"
    }
}

# D. Resolucion directa de rutas conocidas del tenant
$knownSitePaths = @("rrhh", "test", "administracion", "msteams_f72f18_083716")
foreach ($path in $knownSitePaths) {
    try {
        $directSite = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/${tenantHostName}:/sites/$path"
        if ($directSite -and ($directSite.id -or $directSite.webUrl)) {
            $allSitesRaw.Add($directSite)
        }
    } catch {}
}

# E. Fallback a getAllSites (acceso de aplicacion)
try {
    $sitesAll = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/getAllSites"
    if ($sitesAll) {
        foreach ($s in $sitesAll) { $allSitesRaw.Add($s) }
    }
} catch {}

# F. Incluir sitio raiz del tenant
try {
    $rootSite = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/root"
    if ($rootSite -and $rootSite.id) { $allSitesRaw.Add($rootSite) }
} catch {}

# G. Eliminar duplicados por ID y WebUrl
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

# H. Filtrar patrones no deseados y clasificar sitios
$generalSitesList = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($s in $uniqueSites) {
    $webUrl = if ($s.webUrl) { $s.webUrl } else { $s.WebUrl }
    $title = if ($s.displayName) { $s.displayName } else { $s.name }
    $siteId = if ($s.id) { $s.id } else { $s.Id }

    if ([string]::IsNullOrEmpty($webUrl)) { continue }

    if ($ExcludePersonalSites -and $webUrl -like "*/personal/*") {
        continue
    }

    $skip = $false
    foreach ($pattern in $ExcludedSitePatterns) {
        if ($webUrl -like "*$pattern*") {
            $skip = $true
            break
        }
    }

    if (-not $skip) {
        $isM365Group = $m365GroupUrls.ContainsKey($webUrl.ToLower())
        $classInfo = Get-SiteClassification -WebUrl $webUrl -Title $title -IsM365Group $isM365Group

        if (-not $classInfo.IsSubsite) {
            $generalSitesList.Add([PSCustomObject]@{
                Id        = $siteId
                Title     = if ($title) { $title } else { "Sitio general" }
                WebUrl    = $webUrl
                SiteType  = $classInfo.SiteType
                Category  = $classInfo.Category
                RawObject = $s
            })
        }
    }
}

# Ordenar por titulo
$sortedSites = $generalSitesList | Sort-Object -Property Title
$generalSitesList = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($s in $sortedSites) { $generalSitesList.Add($s) }

Write-StatusMsg -Message "Se han encontrado $($generalSitesList.Count) sitios principales." -Status "SUCCESS"

# Paso 3: Seleccion del sitio objetivo
Write-StepHeader -StepNumber 3 -TotalSteps 6 -Title "Seleccion del sitio a auditar"

$selectedGeneralSites = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($targetSiteFilter) {
    $searchTerm = ($targetSiteFilter -replace "https://[^/]+/sites/", "") -replace "^/", ""
    if ([string]::IsNullOrEmpty($searchTerm)) { $searchTerm = $targetSiteFilter }

    Write-StatusMsg -Message "Filtrando por el sitio '$searchTerm'..." -Status "WORKING"
    foreach ($gs in $generalSitesList) {
        if ($gs.WebUrl -like "*$searchTerm*" -or $gs.Title -like "*$searchTerm*" -or $gs.WebUrl -eq $targetSiteFilter) {
            $selectedGeneralSites.Add($gs)
        }
    }

    if ($selectedGeneralSites.Count -eq 0) {
        Write-StatusMsg -Message "No se encontro ningun sitio que coincida con '$targetSiteFilter'. Se analizaran todos los sitios." -Status "WARN"
        foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
    }
} else {
    $isInteractive = $true
    try {
        if ([Environment]::UserInteractive -eq $false -or -not $Host.UI.RawUI) {
            $isInteractive = $false
        }
    } catch {
        $isInteractive = $false
    }

    if (-not $isInteractive) {
        Write-StatusMsg -Message "Modo no interactivo detectado. Seleccionando la opcion de auditar todos los sitios." -Status "INFO"
        foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
    } else {
        # Menu interactivo sencillo, alineado y profesional
        Write-Host "`n--------------------------------------------------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host " Sitios disponibles en el tenant" -ForegroundColor White
        Write-Host "--------------------------------------------------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host " Selecciona el sitio que deseas auditar (se analizara la raiz, subsitios y carpetas):`n" -ForegroundColor Gray

        Write-Host "  Nº    Nombre del sitio                    Tipo de sitio                   Ruta" -ForegroundColor Yellow
        Write-Host "  ----  ----------------------------------  ------------------------------  ----------------------------------" -ForegroundColor DarkGray

        for ($i = 0; $i -lt $generalSitesList.Count; $i++) {
            $siteObj = $generalSitesList[$i]
            $indexNum = $i + 1

            $titleStr = $siteObj.Title
            if ($titleStr.Length -gt 34) { $titleStr = $titleStr.Substring(0, 31) + "..." }

            $typeStr = $siteObj.SiteType
            if ($typeStr.Length -gt 30) { $typeStr = $typeStr.Substring(0, 27) + "..." }

            $urlPath = $siteObj.WebUrl
            if ($urlPath -match "https://[^/]+(/.*)") { $urlPath = $Matches[1] }
            if ($urlPath.Length -gt 36) { $urlPath = $urlPath.Substring(0, 33) + "..." }

            $numPad = "  [{0,2}] " -f $indexNum
            $titlePad = "{0,-34}  " -f $titleStr
            $typePad = "{0,-30}  " -f $typeStr

            Write-Host $numPad -NoNewline -ForegroundColor Green
            Write-Host $titlePad -NoNewline -ForegroundColor White
            Write-Host $typePad -NoNewline -ForegroundColor Yellow
            Write-Host $urlPath -ForegroundColor DarkGray
        }

        Write-Host "  ----  ----------------------------------  ------------------------------  ----------------------------------" -ForegroundColor DarkGray
        Write-Host "  [ 0]  Auditar todos los sitios" -ForegroundColor Cyan
        Write-Host "  [ S]  Ingresar URL o nombre de sitio especifico (ej. /sites/Ventas o https://...)" -ForegroundColor Yellow
        Write-Host "  [ C]  Cargar sitios desde un archivo CSV especifico" -ForegroundColor Green
        Write-Host "--------------------------------------------------------------------------------------------------------`n" -ForegroundColor Cyan
        $userChoice = Read-Host "Elige una opcion (ej. 1,2,4,6 o 0 para todos, 'S' para URL, 'C' para CSV) [0-$($generalSitesList.Count)]"

        $trimmedChoice = if ($userChoice) { $userChoice.Trim() } else { "" }
        $isCsvChoice = ($trimmedChoice.ToLower() -eq 'c' -or $trimmedChoice.ToLower() -eq 'csv' -or $trimmedChoice -like "*.csv")
        $isUrlOrCustom = ($trimmedChoice -like "http*" -or $trimmedChoice -like "/*" -or $trimmedChoice.ToLower() -eq 's' -or $trimmedChoice.ToLower() -eq 'url')

        if ($isCsvChoice) {
            $inputCsvFile = ""
            if ($trimmedChoice -like "*.csv") {
                $inputCsvFile = $trimmedChoice
            } else {
                $inputCsvFile = Read-Host "`nIngrese el nombre o ruta del archivo CSV (ej. 'mis_sitios.csv')"
            }

            $resolvedCsvPath = if ([System.IO.Path]::IsPathRooted($inputCsvFile)) { $inputCsvFile } else { [System.IO.Path]::Combine($PWD.Path, $inputCsvFile) }
            if (Test-Path $resolvedCsvPath) {
                Write-StatusMsg -Message "Importando sitios desde el CSV: '$resolvedCsvPath'..." -Status "WORKING"
                try {
                    $csvData = Import-Csv -Path $resolvedCsvPath -Delimiter ";" -ErrorAction SilentlyContinue
                    if (-not $csvData) { $csvData = Import-Csv -Path $resolvedCsvPath -Delimiter "," -ErrorAction SilentlyContinue }

                    if ($csvData) {
                        $csvSitesList = [System.Collections.Generic.List[PSCustomObject]]::new()
                        foreach ($row in $csvData) {
                            $sUrl = if ($row.URL) { $row.URL } elseif ($row.Url) { $row.Url } elseif ($row.'WebUrl') { $row.'WebUrl' } else { "" }
                            $sTitle = if ($row.'Site name') { $row.'Site name' } elseif ($row.Title) { $row.Title } else { "" }
                            if ($sUrl -and $sUrl -like "http*") {
                                $cPath = ($sUrl -replace "https://[^/]+", "") -replace "^/sites/", "" -replace "^/", ""
                                $gSite = $null
                                if ($cPath) {
                                    try { $gSite = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/${tenantHostName}:/sites/$cPath" } catch {}
                                }
                                $siteObj = [PSCustomObject]@{
                                    Id        = if ($gSite -and $gSite.id) { $gSite.id } else { $sUrl }
                                    Title     = if ($sTitle) { $sTitle } elseif ($gSite -and $gSite.displayName) { $gSite.displayName } else { $cPath }
                                    WebUrl    = $sUrl
                                    SiteType  = "Sitio del CSV"
                                    Category  = "General"
                                    RawObject = $gSite
                                }
                                $csvSitesList.Add($siteObj)
                            }
                        }

                        if ($csvSitesList.Count -gt 0) {
                            foreach ($s in $csvSitesList) { $selectedGeneralSites.Add($s) }
                            Write-StatusMsg -Message "Se han cargado correctamente $($selectedGeneralSites.Count) sitios desde el CSV." -Status "SUCCESS"
                        } else {
                            Write-StatusMsg -Message "No se encontraron URLs validas en el CSV. Auditando todos los sitios del tenant." -Status "WARN"
                            foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
                        }
                    }
                } catch {
                    Write-StatusMsg -Message "Error al leer el CSV '$resolvedCsvPath': $($_.Exception.Message). Auditando todos los sitios del tenant." -Status "WARN"
                    foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
                }
            } else {
                Write-StatusMsg -Message "No se encontro el archivo CSV en '$resolvedCsvPath'. Auditando todos los sitios del tenant." -Status "WARN"
                foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
            }
        } elseif ($isUrlOrCustom) {
            $customSiteInput = ""
            if ($trimmedChoice.ToLower() -eq 's' -or $trimmedChoice.ToLower() -eq 'url') {
                $customSiteInput = Read-Host "`nIngrese la URL o nombre exacto del sitio (ej. 'https://contoso.sharepoint.com/sites/Ventas' o 'Ventas')"
            } else {
                $customSiteInput = $trimmedChoice
            }

            if (-not [string]::IsNullOrWhiteSpace($customSiteInput)) {
                Write-StatusMsg -Message "Resolviendo sitio especifico '$customSiteInput'..." -Status "WORKING"
                $targetHost = $tenantHostName
                $cleanFilter = $customSiteInput.Trim()
                if ($cleanFilter -match "https://([^/]+)/sites/(.*)") {
                    $targetHost = $Matches[1]
                    $cleanFilter = $Matches[2]
                } elseif ($cleanFilter -match "https://([^/]+)") {
                    $targetHost = $Matches[1]
                    $cleanFilter = ""
                } else {
                    $cleanFilter = ($cleanFilter -replace "^/sites/", "") -replace "^/", ""
                }

                $resolvedSite = $null
                if ($cleanFilter) {
                    try {
                        $directSite = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/${targetHost}:/sites/$cleanFilter"
                        if ($directSite -and ($directSite.id -or $directSite.webUrl)) {
                            $webUrl = if ($directSite.webUrl) { $directSite.webUrl } else { $directSite.WebUrl }
                            $title = if ($directSite.displayName) { $directSite.displayName } else { $cleanFilter }
                            $siteId = if ($directSite.id) { $directSite.id } else { $directSite.Id }
                            $classInfo = Get-SiteClassification -WebUrl $webUrl -Title $title -IsM365Group $false
                            $resolvedSite = [PSCustomObject]@{
                                Id        = $siteId
                                Title     = $title
                                WebUrl    = $webUrl
                                SiteType  = $classInfo.SiteType
                                Category  = $classInfo.Category
                                RawObject = $directSite
                            }
                        }
                    } catch {}
                }

                if (-not $resolvedSite) {
                    $matchedInList = $generalSitesList | Where-Object { $_.WebUrl -like "*$cleanFilter*" -or $_.Title -like "*$cleanFilter*" } | Select-Object -First 1
                    if ($matchedInList) {
                        $resolvedSite = $matchedInList
                    } else {
                        $fullUrl = if ($customSiteInput -like "http*") { $customSiteInput } else { "https://${tenantHostName}/sites/$cleanFilter" }
                        $resolvedSite = [PSCustomObject]@{
                            Id        = $fullUrl
                            Title     = if ($cleanFilter) { $cleanFilter } else { "Sitio Especificado" }
                            WebUrl    = $fullUrl
                            SiteType  = "Sitio especifico por URL"
                            Category  = "General"
                            RawObject = $null
                        }
                    }
                }

                if ($resolvedSite) {
                    $selectedGeneralSites.Add($resolvedSite)
                    Write-StatusMsg -Message "Sitio especifico seleccionado: '$($resolvedSite.Title)' ($($resolvedSite.WebUrl))" -Status "SUCCESS"
                } else {
                    Write-StatusMsg -Message "No se pudo encontrar el sitio '$customSiteInput'. Se auditaran todos los sitios." -Status "WARN"
                    foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
                }
            } else {
                Write-StatusMsg -Message "Entrada vacia. Se auditaran todos los sitios." -Status "WARN"
                foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
            }
        } else {
            $chosenIndices = Get-SelectionIndices -InputString $userChoice -MaxRange $generalSitesList.Count -AllowZeroForAll $true

            if ($chosenIndices.Count -eq 1 -and $chosenIndices[0] -eq 0) {
                Write-StatusMsg -Message "Opcion elegida: Auditar todos los sitios." -Status "SUCCESS"
                foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
            } else {
                $selectedTitles = @()
                foreach ($idx in $chosenIndices) {
                    $selectedObj = $generalSitesList[$idx - 1]
                    $selectedGeneralSites.Add($selectedObj)
                    $selectedTitles += "'$($selectedObj.Title)'"
                }
                Write-StatusMsg -Message "Sitio(s) elegido(s) ($($selectedGeneralSites.Count)): $($selectedTitles -join ', ')" -Status "SUCCESS"
            }
        }
    }
}

# Paso 4: Busqueda de subsitios
Write-StepHeader -StepNumber 4 -TotalSteps 6 -Title "Busqueda de subsitios"

Write-StatusMsg -Message "Buscando subsitios en los sitios seleccionados..." -Status "WORKING"

$script:finalAuditedSites = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:finalAuditedMap = @{}

$subsiteQueue = [System.Collections.Generic.Queue[PSCustomObject]]::new()
foreach ($gs in $selectedGeneralSites) {
    if (-not $script:finalAuditedMap.ContainsKey($gs.WebUrl.ToLower())) {
        $script:finalAuditedMap[$gs.WebUrl.ToLower()] = $true
        $script:finalAuditedSites.Add([PSCustomObject]@{
            Id       = $gs.Id
            Title    = $gs.Title
            WebUrl   = $gs.WebUrl
            SiteType = $gs.SiteType
            Category = $gs.Category
            IsFolder = $false
        })
        $subsiteQueue.Enqueue($gs)
    }
}

# Recorrer subsitios
while ($subsiteQueue.Count -gt 0) {
    $currentSite = $subsiteQueue.Dequeue()
    $cId = $currentSite.Id
    $cUrl = $currentSite.WebUrl
    
    $discoveredSubsites = [System.Collections.Generic.List[PSObject]]::new()

    if ($cId) {
        try {
            $res = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$cId/sites"
            if ($res) { foreach ($s in $res) { $discoveredSubsites.Add($s) } }
        } catch {}
    }

    if ($cUrl -match "https://[^/]+(/.*)") {
        $relPath = $Matches[1].TrimEnd('/')
        if ($relPath) {
            try {
                $resPath = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/${tenantHostName}:${relPath}:/sites"
                if ($resPath) { foreach ($s in $resPath) { $discoveredSubsites.Add($s) } }
            } catch {}
        }
    }

    try {
        $resSearch = Invoke-GraphPaginatedRequest -Uri "v1.0/sites?search=$cUrl"
        if ($resSearch) { foreach ($s in $resSearch) { $discoveredSubsites.Add($s) } }
    } catch {}

    foreach ($sub in $discoveredSubsites) {
        $subId = if ($sub.id) { $sub.id } else { $sub.Id }
        $subUrl = if ($sub.webUrl) { $sub.webUrl } else { $sub.WebUrl }
        $subTitle = if ($sub.displayName) { $sub.displayName } else { $sub.name }

        if ($subId -and $subUrl -and $subUrl.ToLower() -ne $cUrl.ToLower() -and -not $script:finalAuditedMap.ContainsKey($subUrl.ToLower())) {
            if ($subUrl -like "*$($currentSite.WebUrl)*" -or $subUrl -match "/sites/[^/]+/.+") {
                $script:finalAuditedMap[$subUrl.ToLower()] = $true
                
                $subObj = [PSCustomObject]@{
                    Id       = $subId
                    Title    = if ($subTitle) { $subTitle } else { "Subsitio de $($currentSite.Title)" }
                    WebUrl   = $subUrl
                    SiteType = "Subsitio de sharepoint"
                    Category = "subsite"
                    IsFolder = $false
                }
                $script:finalAuditedSites.Add($subObj)
                $subsiteQueue.Enqueue($subObj)
                Write-StatusMsg -Message "Subsitio encontrado: $($subObj.Title) ($($subObj.WebUrl))" -Status "SUCCESS"
            }
        }
    }
}

# Paso 5: Busqueda de carpetas con permisos unicos
Write-StepHeader -StepNumber 5 -TotalSteps 6 -Title "Busqueda de carpetas con permisos propios"

Write-StatusMsg -Message "Comprobando bibliotecas y carpetas con permisos personalizados..." -Status "WORKING"

$sitesToScanDrives = @($script:finalAuditedSites)
foreach ($site in $sitesToScanDrives) {
    if (-not $site.IsFolder -and $site.Id) {
        try {
            $drives = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$($site.Id)/drives"
            foreach ($drive in $drives) {
                $driveName = if ($drive.name) { $drive.name } else { "Biblioteca de documentos" }
                $driveId = $drive.id
                if ($driveId) {
                    Get-DriveFoldersWithUniquePermissions -SiteId $site.Id -SiteTitle $site.Title -SiteWebUrl $site.WebUrl -DriveId $driveId -DriveName $driveName -FolderPath "" -ItemId "root" -MaxDepth $MaxFolderDepth
                }
            }
        } catch {
            Write-Verbose "No se pudieron revisar bibliotecas en $($site.WebUrl): $($_.Exception.Message)"
        }
    }
}

Write-StatusMsg -Message "Total de espacios a auditar (sitios, subsitios y carpetas): $($script:finalAuditedSites.Count)" -Status "SUCCESS"

# Paso 6: Analisis de permisos por usuario y grupo
Write-StepHeader -StepNumber 6 -TotalSteps 6 -Title "Analisis de permisos de usuarios y grupos"

$permissionReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$failedSites = [System.Collections.Generic.List[PSCustomObject]]::new()
$siteIndex = 0

foreach ($site in $script:finalAuditedSites) {
    $siteIndex++
    $percent = [math]::Round(($siteIndex / $script:finalAuditedSites.Count) * 100, 1)
    
    Write-Host "  [$siteIndex/$($script:finalAuditedSites.Count)] ($percent%) Auditando: $($site.Title) -> $($site.WebUrl)" -ForegroundColor Gray

    try {
        # Si es una carpeta con permisos unicos ya detectada, procesar sus permisos directamente
        if ($site.IsFolder -and $site.RawPerms) {
            foreach ($perm in $site.RawPerms) {
                $roles = if ($perm.roles) { $perm.roles -join ", " } else { "Acceso generico" }
                $sitePermission = switch -Regex ($roles) {
                    "owner" { "Control total (owner)" }
                    "write" { "Edicion / colaboracion (write)" }
                    "read"  { "Solo lectura (read)" }
                    default { $roles }
                }

                if ($perm.grantedToV2.user) {
                    $uName = $perm.grantedToV2.user.displayName
                    $uEmail = if ($perm.grantedToV2.user.userPrincipalName) { $perm.grantedToV2.user.userPrincipalName } elseif ($perm.grantedToV2.user.email) { $perm.grantedToV2.user.email } else { $perm.grantedToV2.user.id }

                    if ($uEmail -notlike "*app@sharepoint*") {
                        $permissionReport.Add([PSCustomObject]@{
                            UserName              = $uName
                            UserEmail             = $uEmail
                            SiteTitle             = $site.Title
                            SiteUrl               = $site.WebUrl
                            SiteType              = $site.SiteType
                            SitePermissions       = $sitePermission
                            AccessSource          = "Usuario directo en carpeta"
                            HasInheritanceEnabled = "No (permisos unicos en carpeta)"
                            InheritanceDetail     = "Permisos directos asignados a la carpeta"
                            AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                        })
                    }
                } elseif ($perm.grantedToV2.group) {
                    $grpName = $perm.grantedToV2.group.displayName
                    $permissionReport.Add([PSCustomObject]@{
                        UserName              = $grpName
                        UserEmail             = "Grupo: $grpName"
                        SiteTitle             = $site.Title
                        SiteUrl               = $site.WebUrl
                        SiteType              = $site.SiteType
                        SitePermissions       = $sitePermission
                        AccessSource          = "Grupo via carpeta ($grpName)"
                        HasInheritanceEnabled = "No (permisos unicos en carpeta)"
                        InheritanceDetail     = "Permisos directos de grupo asignados a la carpeta"
                        AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    })
                }
            }
            continue
        }

        # A. Extraer miembros de grupos nativos de SharePoint (/siteGroups/{id}/users)
        try {
            $spGroupsRes = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/$($site.Id)/siteGroups"
            if ($spGroupsRes -and $spGroupsRes.value) {
                foreach ($spGrp in $spGroupsRes.value) {
                    $spGrpId = $spGrp.id
                    $spGrpName = $spGrp.displayName
                    if ($spGrpId) {
                        try {
                            $spUsersRes = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/$($site.Id)/siteGroups/$spGrpId/users"
                            if ($spUsersRes -and $spUsersRes.value) {
                                foreach ($spU in $spUsersRes.value) {
                                    $uName = if ($spU.displayName) { $spU.displayName } else { "Usuario sharepoint" }
                                    $uEmail = if ($spU.userPrincipalName) { $spU.userPrincipalName } elseif ($spU.email) { $spU.email } else { $spU.id }
                                    
                                    if ($uEmail -like "*#EXT#*") {
                                        if ($spU.email) { $uEmail = $spU.email }
                                        elseif ($uEmail -match "([^=]+)_([^@]+)#EXT#@") { $uEmail = "$($Matches[1])@$($Matches[2])" }
                                    }

                                    $spRole = switch -Regex ($spGrpName) {
                                        "Owner|Propietario|Owners" { "Control total (owner de grupo sharepoint)" }
                                        "Member|Miembro|Members" { "Edicion / colaboracion (member de grupo sharepoint)" }
                                        "Visitor|Visitante|Visitors" { "Solo lectura (visitor de grupo sharepoint)" }
                                        default { "Acceso via grupo sharepoint ($spGrpName)" }
                                    }

                                    if ($uEmail -notlike "*app@sharepoint*" -and $uEmail -notlike "*system*") {
                                        $permissionReport.Add([PSCustomObject]@{
                                            UserName              = $uName
                                            UserEmail             = $uEmail
                                            SiteTitle             = $site.Title
                                            SiteUrl               = $site.WebUrl
                                            SiteType              = $site.SiteType
                                            SitePermissions       = $spRole
                                            AccessSource          = "Miembro de grupo sharepoint ($spGrpName)"
                                            HasInheritanceEnabled = if ($site.SiteType -like "*Subsitio*") { "Si (grupo de sitio principal)" } else { "No (permisos directos del sitio principal)" }
                                            InheritanceDetail     = "Grupo nativo sharepoint: $spGrpName"
                                            AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                                        })
                                    }
                                }
                            }
                        } catch {
                            Write-Verbose "Error al leer usuarios de grupo sharepoint $spGrpName : $($_.Exception.Message)"
                        }
                    }
                }
            }
        } catch {
            Write-Verbose "Error al obtener siteGroups para $($site.WebUrl): $($_.Exception.Message)"
        }

        # B. Extraer administradores de la coleccion de sitios (Site collection admins)
        try {
            $adminsRes = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/$($site.Id)/siteCollection/admins"
            if ($adminsRes -and $adminsRes.value) {
                foreach ($admin in $adminsRes.value) {
                    $uName = if ($admin.displayName) { $admin.displayName } else { "Admin de sitio" }
                    $uEmail = if ($admin.userPrincipalName) { $admin.userPrincipalName } elseif ($admin.email) { $admin.email } else { $admin.id }
                    
                    if ($uEmail -notlike "*app@sharepoint*") {
                        $permissionReport.Add([PSCustomObject]@{
                            UserName              = $uName
                            UserEmail             = $uEmail
                            SiteTitle             = $site.Title
                            SiteUrl               = $site.WebUrl
                            SiteType              = $site.SiteType
                            SitePermissions       = "Control total (administrador de coleccion de sitios)"
                            AccessSource          = "Administrador de sitio"
                            HasInheritanceEnabled = "No (permisos unicos de administracion)"
                            InheritanceDetail     = "Administrador de coleccion de sitios"
                            AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                        })
                    }
                }
            }
        } catch {
            Write-Verbose "Error al obtener admins para $($site.WebUrl): $($_.Exception.Message)"
        }

        # C. Extraer propietarios y miembros del grupo M365 / teams asociado
        if ($m365GroupIdMap.ContainsKey($site.WebUrl.ToLower())) {
            $groupId = $m365GroupIdMap[$site.WebUrl.ToLower()]
            try {
                $ownersRes = Invoke-GraphPaginatedRequest -Uri "v1.0/groups/$groupId/owners?`$select=id,displayName,userPrincipalName,mail"
                foreach ($owner in $ownersRes) {
                    $uName = if ($owner.displayName) { $owner.displayName } else { "Propietario de equipo" }
                    $uEmail = if ($owner.userPrincipalName) { $owner.userPrincipalName } elseif ($owner.mail) { $owner.mail } else { $owner.id }
                    
                    if ($uEmail -like "*#EXT#*") {
                        if ($owner.mail) { $uEmail = $owner.mail }
                        elseif ($uEmail -match "([^=]+)_([^@]+)#EXT#@") { $uEmail = "$($Matches[1])@$($Matches[2])" }
                    }

                    if ($uEmail -notlike "*app@sharepoint*") {
                        $permissionReport.Add([PSCustomObject]@{
                            UserName              = $uName
                            UserEmail             = $uEmail
                            SiteTitle             = $site.Title
                            SiteUrl               = $site.WebUrl
                            SiteType              = $site.SiteType
                            SitePermissions       = "Control total (owner de equipo / grupo m365)"
                            AccessSource          = "Propietario de grupo m365"
                            HasInheritanceEnabled = "No (permisos directos de grupo)"
                            InheritanceDetail     = "Propietario del equipo de teams"
                            AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                        })
                    }
                }
            } catch {
                Write-Verbose "Error al obtener propietarios m365: $($_.Exception.Message)"
            }

            try {
                $membersRes = Invoke-GraphPaginatedRequest -Uri "v1.0/groups/$groupId/members?`$select=id,displayName,userPrincipalName,mail"
                foreach ($member in $membersRes) {
                    $uName = if ($member.displayName) { $member.displayName } else { "Miembro de equipo" }
                    $uEmail = if ($member.userPrincipalName) { $member.userPrincipalName } elseif ($member.mail) { $member.mail } else { $member.id }
                    
                    if ($uEmail -like "*#EXT#*") {
                        if ($member.mail) { $uEmail = $member.mail }
                        elseif ($uEmail -match "([^=]+)_([^@]+)#EXT#@") { $uEmail = "$($Matches[1])@$($Matches[2])" }
                    }

                    if ($uEmail -notlike "*app@sharepoint*") {
                        $permissionReport.Add([PSCustomObject]@{
                            UserName              = $uName
                            UserEmail             = $uEmail
                            SiteTitle             = $site.Title
                            SiteUrl               = $site.WebUrl
                            SiteType              = $site.SiteType
                            SitePermissions       = "Edicion / colaboracion (member de equipo / grupo m365)"
                            AccessSource          = "Miembro de grupo m365"
                            HasInheritanceEnabled = "No (permisos directos de grupo)"
                            InheritanceDetail     = "Miembro del equipo de teams"
                            AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                        })
                    }
                }
            } catch {
                Write-Verbose "Error al obtener miembros m365: $($_.Exception.Message)"
            }
        }

        # D. Extraer permisos directos e inherentes del sitio (/permissions)
        $permsRaw = @()
        try {
            $permsRaw = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$($site.Id)/permissions"
        } catch {}

        if (-not $permsRaw -or $permsRaw.Count -eq 0) {
            try {
                $permsRaw = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$($site.Id)/drive/root/permissions"
            } catch {}
        }

        foreach ($perm in $permsRaw) {
            $roles = if ($perm.roles) { $perm.roles -join ", " } else { "Acceso generico" }
            
            $sitePermission = switch -Regex ($roles) {
                "owner" { "Control total (owner)" }
                "write" { "Edicion / colaboracion (write)" }
                "read"  { "Solo lectura (read)" }
                default { $roles }
            }

            $hasInheritance = "No (permisos unicos / directos)"
            $inheritanceDetail = "Directo en el sitio"

            if ($perm.inheritedFrom) {
                $hasInheritance = "Si (permiso heredado)"
                $inheritedName = if ($perm.inheritedFrom.displayName) { $perm.inheritedFrom.displayName } else { "Sitio / libreria padre" }
                $inheritanceDetail = "Heredado de: $inheritedName"
            }

            if ($perm.grantedToV2.user) {
                $uName = $perm.grantedToV2.user.displayName
                $uEmail = if ($perm.grantedToV2.user.userPrincipalName) { $perm.grantedToV2.user.userPrincipalName } elseif ($perm.grantedToV2.user.email) { $perm.grantedToV2.user.email } else { $perm.grantedToV2.user.id }

                if ($uEmail -like "*#EXT#*") {
                    if ($perm.grantedToV2.user.email) { $uEmail = $perm.grantedToV2.user.email }
                    elseif ($uEmail -match "([^=]+)_([^@]+)#EXT#@") { $uEmail = "$($Matches[1])@$($Matches[2])" }
                }

                if ($uEmail -notlike "*app@sharepoint*") {
                    $permissionReport.Add([PSCustomObject]@{
                        UserName              = $uName
                        UserEmail             = $uEmail
                        SiteTitle             = $site.Title
                        SiteUrl               = $site.WebUrl
                        SiteType              = $site.SiteType
                        SitePermissions       = $sitePermission
                        AccessSource          = "Usuario directo"
                        HasInheritanceEnabled = $hasInheritance
                        InheritanceDetail     = $inheritanceDetail
                        AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    })
                }
            } elseif ($perm.grantedToV2.group) {
                $grpId = $perm.grantedToV2.group.id
                $grpName = $perm.grantedToV2.group.displayName
                $grpMail = $perm.grantedToV2.group.email

                if (-not $grpId -and $grpMail) {
                    try {
                        $nick = ($grpMail -split "@")[0]
                        $foundGroup = Invoke-GraphPaginatedRequest -Uri "v1.0/groups?`$filter=mailNickname eq '$nick'"
                        if ($foundGroup -and $foundGroup.Count -gt 0 -and $foundGroup[0].id) {
                            $grpId = $foundGroup[0].id
                        }
                    } catch {}
                }

                if ($grpId) {
                    try {
                        $grpOwners = Invoke-GraphPaginatedRequest -Uri "v1.0/groups/$grpId/owners"
                        if ($grpOwners -and $grpOwners.Count -gt 0) {
                            foreach ($o in $grpOwners) {
                                $oName = if ($o.displayName) { $o.displayName } else { "Propietario de grupo" }
                                $oEmail = if ($o.userPrincipalName) { $o.userPrincipalName } elseif ($o.mail) { $o.mail } else { $o.id }
                                if ($oEmail -like "*#EXT#*") {
                                    if ($o.mail) { $oEmail = $o.mail }
                                    elseif ($oEmail -match "([^=]+)_([^@]+)#EXT#@") { $oEmail = "$($Matches[1])@$($Matches[2])" }
                                }
                                if ($oEmail -notlike "*app@sharepoint*") {
                                    $permissionReport.Add([PSCustomObject]@{
                                        UserName              = $oName
                                        UserEmail             = $oEmail
                                        SiteTitle             = $site.Title
                                        SiteUrl               = $site.WebUrl
                                        SiteType              = $site.SiteType
                                        SitePermissions       = "Control total (owner de grupo entra id)"
                                        AccessSource          = "Usuario via grupo entra id ($grpName)"
                                        HasInheritanceEnabled = $hasInheritance
                                        InheritanceDetail     = $inheritanceDetail
                                        AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                                    })
                                }
                            }
                        }
                    } catch {}

                    try {
                        $grpMembers = Invoke-GraphPaginatedRequest -Uri "v1.0/groups/$grpId/members"
                        if ($grpMembers -and $grpMembers.Count -gt 0) {
                            foreach ($m in $grpMembers) {
                                $mName = if ($m.displayName) { $m.displayName } else { "Miembro de grupo" }
                                $mEmail = if ($m.userPrincipalName) { $m.userPrincipalName } elseif ($m.mail) { $m.mail } else { $m.id }
                                if ($mEmail -like "*#EXT#*") {
                                    if ($m.mail) { $mEmail = $m.mail }
                                    elseif ($mEmail -match "([^=]+)_([^@]+)#EXT#@") { $mEmail = "$($Matches[1])@$($Matches[2])" }
                                }
                                if ($mEmail -notlike "*app@sharepoint*") {
                                    $permissionReport.Add([PSCustomObject]@{
                                        UserName              = $mName
                                        UserEmail             = $mEmail
                                        SiteTitle             = $site.Title
                                        SiteUrl               = $site.WebUrl
                                        SiteType              = $site.SiteType
                                        SitePermissions       = "Edicion / colaboracion (member de grupo entra id)"
                                        AccessSource          = "Usuario via grupo entra id ($grpName)"
                                        HasInheritanceEnabled = $hasInheritance
                                        InheritanceDetail     = $inheritanceDetail
                                        AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                                    })
                                }
                            }
                        }
                    } catch {}
                }
            } elseif ($perm.grantedTo) {
                $uName = $perm.grantedTo.user.displayName
                $uEmail = if ($perm.grantedTo.user.userPrincipalName) { $perm.grantedTo.user.userPrincipalName } else { $perm.grantedTo.user.id }
                if ($uEmail -notlike "*app@sharepoint*") {
                    $permissionReport.Add([PSCustomObject]@{
                        UserName              = $uName
                        UserEmail             = $uEmail
                        SiteTitle             = $site.Title
                        SiteUrl               = $site.WebUrl
                        SiteType              = $site.SiteType
                        SitePermissions       = $sitePermission
                        AccessSource          = "Usuario directo"
                        HasInheritanceEnabled = $hasInheritance
                        InheritanceDetail     = $inheritanceDetail
                        AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    })
                }
            }
        }
    } catch {
        Write-StatusMsg -Message "No se pudieron obtener permisos de $($site.WebUrl): $($_.Exception.Message)" -Status "WARN"
        $failedSites.Add([PSCustomObject]@{
            SiteTitle    = $site.Title
            SiteUrl      = $site.WebUrl
            ErrorMessage = $_.Exception.Message
            AttemptDate  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        })
    }
}

# Generar informe HTML
Write-StatusMsg -Message "Generando informe HTML..." -Status "WORKING"

if ($permissionReport.Count -gt 0) {
    $userSummary = $permissionReport | Group-Object -Property UserEmail | ForEach-Object {
        $userMail = $_.Name
        $userDisplayName = ($_.Group | Select-Object -ExpandProperty UserName -First 1)
        
        $sitesListArray = $_.Group | Select-Object -ExpandProperty SiteTitle -Unique
        $sitesList = $sitesListArray -join " | "
        $siteUrls = ($_.Group | Select-Object -ExpandProperty SiteUrl -Unique) -join " | "
        $permTypes = ($_.Group | Select-Object -ExpandProperty SitePermissions -Unique) -join " | "
        $siteCount = $sitesListArray.Count

        $siteItems = [System.Collections.Generic.List[string]]::new()
        $folderItems = [System.Collections.Generic.List[string]]::new()
        foreach ($st in $sitesListArray) {
            if ($st -like "*-> Carpeta:*") {
                $folderItems.Add($st)
            } else {
                $siteItems.Add($st)
            }
        }

        [PSCustomObject]@{
            UserEmail        = $userMail
            UserName         = $userDisplayName
            TotalSitesAccess = $siteCount
            SitesCount       = $siteItems.Count
            FoldersCount     = $folderItems.Count
            SiteItems        = $siteItems
            FolderItems      = $folderItems
            PermissionTypes  = $permTypes
            SitesList        = $sitesList
            SitesUrls        = $siteUrls
        }
    } | Sort-Object -Property TotalSitesAccess -Descending

    $stopwatch.Stop()
    $elapsedTime = "{0:hh\:mm\:ss}" -f $stopwatch.Elapsed
    $userAccount = if ($context -and $context.Account) { $context.Account } else { "Usuario m365" }
    
    $auditedSiteName = if ($selectedGeneralSites -and $selectedGeneralSites.Count -eq 1) {
        $selectedGeneralSites[0].Title
    } elseif ($targetSiteFilter) {
        $targetSiteFilter
    } else {
        "todos los sites"
    }

    $primaryCount = ($script:finalAuditedSites | Where-Object { $_.SiteType -notlike "*Subsitio*" -and $_.SiteType -notlike "*Teams*" -and $_.SiteType -notlike "*Carpeta*" }).Count
    $subsitesCount = ($script:finalAuditedSites | Where-Object { $_.SiteType -like "*Subsitio*" }).Count
    $teamsCount = ($script:finalAuditedSites | Where-Object { $_.SiteType -like "*Teams*" -or $_.SiteType -like "*M365*" }).Count
    $foldersCount = ($script:finalAuditedSites | Where-Object { $_.SiteType -like "*Carpeta*" }).Count

    try {
        Export-PermissionsToHtml -ReportData $permissionReport -UserSummaryData $userSummary -FilePath $HtmlOutputPath -UserAccount $userAccount -AuditedSiteName $auditedSiteName -TotalSitesCount $script:finalAuditedSites.Count -PrimarySitesCount $primaryCount -SubsitesCount $subsitesCount -TeamSitesCount $teamsCount -FoldersCount $foldersCount -ElapsedTime $elapsedTime
    } catch {
        Write-StatusMsg -Message "Error al generar informe HTML: $($_.Exception.Message)" -Status "FAIL"
    }
} else {
    Write-StatusMsg -Message "No se encontraron permisos para exportar." -Status "WARN"
    $stopwatch.Stop()
    $elapsedTime = "{0:hh\:mm\:ss}" -f $stopwatch.Elapsed
}

# Resumen final en consola
Write-Host "`n=========================================================================" -ForegroundColor Cyan
Write-Host "                          Resumen de auditoria                           " -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "  Tiempo total                : $elapsedTime" -ForegroundColor White
Write-Host "  Sitios y carpetas analizados: $($script:finalAuditedSites.Count)" -ForegroundColor White
Write-Host "  Sitios procesados con exito : $($script:finalAuditedSites.Count - $failedSites.Count)" -ForegroundColor Green
Write-Host "  Sitios con error u omitidos : $($failedSites.Count)" -ForegroundColor $(if ($failedSites.Count -gt 0) { "Yellow" } else { "Gray" })
Write-Host "  Registros de permisos       : $($permissionReport.Count)" -ForegroundColor White
Write-Host "  Usuarios unicos             : $(if ($userSummary) { $userSummary.Count } else { 0 })" -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan

if ($userSummary -and $userSummary.Count -gt 0) {
    Write-Host "`nTop 5 usuarios con mayor numero de accesos:" -ForegroundColor Yellow
    $userSummary | Select-Object -First 5 UserName, UserEmail, TotalSitesAccess, PermissionTypes | Format-Table -AutoSize
}

Write-StatusMsg -Message "Auditoria finalizada." -Status "SUCCESS"
