<#
.SYNOPSIS
    SharePoint Online - Auditoria de permisos en sitios, subsitios y carpetas con Microsoft Graph (v3.6.0)

.DESCRIPTION
    Script de auditoria de permisos para SharePoint Online.
    Permite seleccionar un sitio general por pantalla o mediante parametros,
    y analiza la raiz, los subsitios y las carpetas con permisos unicos (ruptura de herencia).
    Desglosa grupos de SharePoint, Entra ID y M365 hasta llegar a usuarios individuales.
    Genera un informe HTML interactivo con vista de matriz por usuario organizada por desplegables y badges.

.PARAMETER TenantId
    ID o dominio del tenant de Microsoft 365.

.PARAMETER ClientId
    ID de la aplicacion (App ID) de Entra ID.

.PARAMETER ClientSecret
    Secreto de aplicacion (Client Secret).

.PARAMETER SiteUrl
    Nombre, ruta o URL del sitio a auditar (ej. "Administracion", "rrhh" o "https://contoso.sharepoint.com/sites/Administracion").

.PARAMETER SiteName
    Alias para -SiteUrl. Nombre o filtro del sitio objetivo.

.PARAMETER HtmlOutputPath
    Ruta del informe HTML de salida. Por defecto: ".\Reporte_Permisos_SharePoint.html"

.PARAMETER MaxFolderDepth
    Profundidad maxima de exploracion de subcarpetas en bibliotecas de documentos (por defecto: 5).

.EXAMPLE
    & '.\Sharepoint - Auditoria permisos.ps1'

.EXAMPLE
    & '.\Sharepoint - Auditoria permisos.ps1' -SiteUrl "Administracion"

.EXAMPLE
    & '.\Sharepoint - Auditoria permisos.ps1' -SiteUrl "https://contoso.sharepoint.com/sites/Administracion" -HtmlOutputPath ".\Auditoria_Administracion.html"

.NOTES
    Nombre:   Sharepoint - Auditoria permisos.ps1
    Autor:    Alejandro Suárez (@alexsf93)
    Versión:  3.6.0
    Fecha:    2026-08-07
#>

param(
    [string]$TenantId = "",
    [string]$ClientId = "",
    [string]$ClientSecret = "",
    [string]$SiteUrl = "",
    [string]$SiteName = "",
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

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# Encabezado sencillo y limpio para cada paso
function Write-StepHeader {
    param(
        [int]$StepNumber,
        [int]$TotalSteps = 6,
        [string]$Title
    )
    Write-Host "`n------------------------------------------------------------------------- " -ForegroundColor Cyan
    Write-Host " PASO ${StepNumber} de ${TotalSteps}: $Title" -ForegroundColor White
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

Clear-Host
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Auditoría de permisos de SPO" -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Nota sobre la estructura:" -ForegroundColor Yellow
Write-Host "  - Sitio principal: Sitio independiente de nivel superior (ej. /sites/Ventas)." -ForegroundColor Gray
Write-Host "  - Subsitio: Sitio secundario dentro de un sitio principal." -ForegroundColor Gray
Write-Host "  - Carpetas únicas: Carpetas o bibliotecas donde se han personalizado los permisos." -ForegroundColor Gray
Write-Host "-------------------------------------------------------------------------" -ForegroundColor DarkGray

# PASO 1: Conexión con Microsoft Graph
Write-StepHeader -StepNumber 1 -TotalSteps 6 -Title "Conexión con Microsoft Graph API"

try {
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if ($context -and ($context.Scopes -notcontains "Sites.FullControl.All" -and $context.Scopes -notcontains "Sites.Read.All")) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        $context = $null
    }

    if (-not $context) {
        Write-StatusMsg -Message "Conectando con Microsoft Graph..." -Status "WORKING"
        if ($TenantId -and $ClientId -and $ClientSecret) {
            Write-StatusMsg -Message "Autenticando con App Registration..." -Status "WORKING"
            $secSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -ClientSecret $secSecret -ErrorAction Stop
        } else {
            Write-StatusMsg -Message "Iniciando sesión interactiva (permisos de lectura)..." -Status "WORKING"
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
    Write-StatusMsg -Message "Error al conectar con Microsoft Graph: $($_.Exception.Message)" -Status "FAIL"
    Exit
}

# Control de Throttling y Reintentos con Exponential Backoff
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
                Write-StatusMsg -Message "Límite de peticiones de Microsoft Graph alcanzado (HTTP $statusCode). Esperando $retryAfter segundos (Intento $attempt de $MaxRetries)..." -Status "WARN"
                Start-Sleep -Seconds $retryAfter
            } else {
                throw $_
            }
        }
    }
}

# Detección dinámica del hostname de SharePoint
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

# Paginación Graph API usando reintentos
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

# Clasificación de Sitio Principal vs Subsitio
function Get-SiteClassification {
    param(
        [string]$WebUrl,
        [string]$Title,
        [bool]$IsM365Group
    )
    if ([string]::IsNullOrEmpty($WebUrl)) {
        return @{ SiteType = "Sitio de SharePoint"; IsSubsite = $false; Category = "principal" }
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
        $siteType = "Subsitio de SharePoint"
        $category = "subsite"
    } elseif ($IsM365Group -or $cleanUrl -like "*msteams*" -or $cleanUrl -like "*/sites/group*") {
        $siteType = "Sitio de equipo (Teams / M365)"
        $category = "teams"
    } elseif ($Title -like "*communication*" -or $cleanUrl -like "*/sites/CommunicationSite*") {
        $siteType = "Sitio de comunicación"
        $category = "principal"
    } else {
        $siteType = "Sitio principal (Colección de sitios)"
        $category = "principal"
    }

    return @{
        SiteType  = $siteType
        IsSubsite = $isSubsite
        Category  = $category
    }
}

# Escaneo recursivo de carpetas dentro de una biblioteca con permisos únicos (ruptura de herencia)
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
                            SiteType  = "Carpeta con permisos únicos"
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

    $siteGroups = $ReportData | Group-Object -Property SiteUrl
    $siteCardsHtml = [System.Text.StringBuilder]::new()

    foreach ($group in $siteGroups) {
        $firstItem = $group.Group[0]
        $siteTitle = if ($firstItem.SiteTitle) { $firstItem.SiteTitle } else { "Sitio de SharePoint" }
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
            $actionEsc = [System.Net.WebUtility]::HtmlEncode($friendlyAction)
            $sourceEsc = [System.Net.WebUtility]::HtmlEncode($item.AccessSource)
            $inherEsc = [System.Net.WebUtility]::HtmlEncode($item.HasInheritanceEnabled)
            $inherDetailEsc = [System.Net.WebUtility]::HtmlEncode($item.InheritanceDetail)

            [void]$usersRowsHtml.AppendLine("
            <tr>
                <td>
                    <div class=`"user-cell`">
                        <span class=`"user-name`">$uNameEsc</span>
                        <span class=`"user-email`">$uEmailEsc</span>
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
                        <span class=`"site-title`">$siteTitleEsc</span>
                        <span class=`"badge $siteBadgeClass`">$siteTypeEsc</span>
                    </div>
                    <a href=`"$siteUrlEsc`" target=`"_blank`" class=`"site-url-link`">$siteUrlEsc</a>
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
                            <th>¿Qué puede hacer el usuario?</th>
                            <th>Origen del permiso</th>
                            <th>¿Hereda permisos?</th>
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

    # Renderizar Matriz General por Usuario interactiva con lista estructurada y desplegables
    $userMatrixRowsHtml = [System.Text.StringBuilder]::new()
    if ($UserSummaryData) {
        foreach ($user in $UserSummaryData) {
            $uNameEsc = [System.Net.WebUtility]::HtmlEncode($user.UserName)
            $uEmailEsc = [System.Net.WebUtility]::HtmlEncode($user.UserEmail)
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
                        <span class=`"user-name`">$uNameEsc</span>
                        <span class=`"user-email`">$uEmailEsc</span>
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
    <title>Auditoría de permisos de SPO</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-main: #0f172a;
            --bg-card: #1e293b;
            --bg-table-hover: #334155;
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --border-color: #334155;
            --accent-cyan: #06b6d4;
            --accent-indigo: #6366f1;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Inter', sans-serif;
            background-color: var(--bg-main);
            color: var(--text-primary);
            padding: 30px 20px;
            line-height: 1.5;
        }
        .container { max-width: 1400px; margin: 0 auto; }
        .header {
            background: linear-gradient(135deg, #1e1b4b 0%, #0f172a 100%);
            border: 1px solid #3730a3;
            border-radius: 16px;
            padding: 24px 32px;
            margin-bottom: 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 16px;
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3);
        }
        .header h1 { font-size: 1.6rem; font-weight: 700; color: #ffffff; margin-bottom: 6px; }
        .header p { color: var(--text-secondary); font-size: 0.9rem; }
        .header-meta { text-align: right; font-size: 0.85rem; color: var(--text-secondary); }
        .header-meta span { color: var(--accent-cyan); font-weight: 600; }
        
        .info-banner {
            background: rgba(30, 41, 59, 0.8);
            border: 1px solid #334155;
            border-left: 4px solid var(--accent-cyan);
            border-radius: 12px;
            padding: 16px 20px;
            margin-bottom: 24px;
            font-size: 0.88rem;
            color: #cbd5e1;
        }
        .info-banner strong { color: #ffffff; }

        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }
        .metric-card {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 14px;
            padding: 20px;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
        }
        .metric-card .title { font-size: 0.8rem; color: var(--text-secondary); font-weight: 500; text-transform: uppercase; letter-spacing: 0.5px; }
        .metric-card .value { font-size: 1.8rem; font-weight: 700; color: #ffffff; margin-top: 6px; }
        .metric-card .subtext { font-size: 0.75rem; color: var(--accent-cyan); margin-top: 4px; }

        .toolbar {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 14px;
            padding: 16px 20px;
            margin-bottom: 24px;
            display: flex;
            gap: 16px;
            align-items: center;
            justify-content: space-between;
            flex-wrap: wrap;
        }
        .search-box { flex: 1; min-width: 280px; }
        .search-box input {
            width: 100%;
            padding: 10px 16px;
            background: #0f172a;
            border: 1px solid var(--border-color);
            border-radius: 8px;
            color: #fff;
            font-size: 0.9rem;
            outline: none;
            transition: all 0.2s;
        }
        .search-box input:focus { border-color: var(--accent-cyan); box-shadow: 0 0 0 2px rgba(6, 182, 212, 0.2); }

        .filter-tabs { display: flex; gap: 8px; flex-wrap: wrap; }
        .tab-btn {
            background: #0f172a;
            color: var(--text-secondary);
            border: 1px solid var(--border-color);
            padding: 8px 16px;
            border-radius: 8px;
            font-size: 0.85rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
        }
        .tab-btn.active, .tab-btn:hover {
            background: var(--accent-indigo);
            color: #ffffff;
            border-color: var(--accent-indigo);
        }

        .site-card {
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 16px;
            margin-bottom: 24px;
            overflow: hidden;
            box-shadow: 0 10px 25px rgba(0,0,0,0.2);
        }
        .site-header {
            background: #1e1b4b;
            border-bottom: 1px solid var(--border-color);
            padding: 18px 24px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 12px;
        }
        .site-title-row { display: flex; align-items: center; gap: 12px; }
        .site-title { font-size: 1.2rem; font-weight: 700; color: #ffffff; }
        .site-url-link { font-size: 0.85rem; color: #38bdf8; text-decoration: none; display: block; margin-top: 4px; }
        .site-url-link:hover { text-decoration: underline; }

        .table-container { overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; text-align: left; }
        th {
            background: #111827;
            padding: 12px 18px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
            color: var(--text-secondary);
            border-bottom: 1px solid var(--border-color);
            letter-spacing: 0.5px;
        }
        td { padding: 12px 18px; border-bottom: 1px solid var(--border-color); font-size: 0.85rem; vertical-align: top; }
        tr:hover { background-color: var(--bg-table-hover); }

        .user-cell { display: flex; flex-direction: column; }
        .user-name { font-weight: 600; color: #f8fafc; }
        .user-email { font-size: 0.75rem; color: var(--text-secondary); }

        .badge {
            display: inline-block;
            padding: 4px 10px;
            border-radius: 20px;
            font-size: 0.75rem;
            font-weight: 600;
        }
        .badge-teams-site { background: rgba(99, 102, 241, 0.2); color: #a5b4fc; border: 1px solid rgba(99, 102, 241, 0.4); }
        .badge-comm-site { background: rgba(20, 184, 166, 0.2); color: #5eead4; border: 1px solid rgba(20, 184, 166, 0.4); }
        .badge-subsite { background: rgba(245, 158, 11, 0.2); color: #fde047; border: 1px solid rgba(245, 158, 11, 0.4); }
        .badge-folder { background: rgba(249, 115, 22, 0.2); color: #fdba74; border: 1px solid rgba(249, 115, 22, 0.4); }

        .badge-owner { background: rgba(239, 68, 68, 0.2); color: #fca5a5; border: 1px solid rgba(239, 68, 68, 0.4); }
        .badge-write { background: rgba(245, 158, 11, 0.2); color: #fde047; border: 1px solid rgba(245, 158, 11, 0.4); }
        .badge-read { background: rgba(34, 197, 94, 0.2); color: #86efac; border: 1px solid rgba(34, 197, 94, 0.4); }
        .badge-generic { background: rgba(148, 163, 184, 0.15); color: #cbd5e1; border: 1px solid rgba(148, 163, 184, 0.3); }

        .badge-inherited { background: rgba(6, 182, 212, 0.15); color: #67e8f9; border: 1px solid rgba(6, 182, 212, 0.3); }
        .badge-unique { background: rgba(245, 158, 11, 0.15); color: #fde047; border: 1px solid rgba(245, 158, 11, 0.3); }

        .badge-user { background: rgba(99, 102, 241, 0.15); color: #a5b4fc; }
        .badge-entragroup { background: rgba(168, 85, 247, 0.15); color: #d8b4fe; }
        .badge-spgroup { background: rgba(236, 72, 153, 0.15); color: #f472b6; }
        .badge-app { background: rgba(20, 184, 166, 0.15); color: #5eead4; }

        .user-access-details {
            background: #0f172a;
            border: 1px solid var(--border-color);
            border-radius: 10px;
            padding: 8px 12px;
        }
        .user-access-summary {
            cursor: pointer;
            font-size: 0.82rem;
            font-weight: 600;
            color: var(--accent-cyan);
            display: flex;
            align-items: center;
            gap: 8px;
            flex-wrap: wrap;
            outline: none;
        }
        .user-access-summary:hover {
            color: #ffffff;
        }
        .view-more-link {
            margin-left: auto;
            font-size: 0.78rem;
            color: #38bdf8;
            text-decoration: underline;
        }
        .access-items-list {
            list-style: none;
            margin-top: 10px;
            padding-top: 10px;
            border-top: 1px solid var(--border-color);
            max-height: 240px;
            overflow-y: auto;
        }
        .access-items-list li {
            padding: 6px 4px;
            font-size: 0.8rem;
            color: #e2e8f0;
            border-bottom: 1px solid rgba(255,255,255,0.05);
            display: flex;
            align-items: center;
            gap: 8px;
            word-break: break-word;
        }
        .access-items-list li:last-child {
            border-bottom: none;
        }
        .access-pill-row {
            margin-bottom: 6px;
            font-size: 0.82rem;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .access-item-name {
            color: #f1f5f9;
        }

        .text-subtle { font-size: 0.8rem; color: var(--text-secondary); }
        .view-section { margin-bottom: 32px; }
        .section-title { font-size: 1.3rem; font-weight: 700; color: #ffffff; margin-bottom: 16px; border-left: 4px solid var(--accent-cyan); padding-left: 12px; }
        .footer { text-align: center; margin-top: 30px; font-size: 0.8rem; color: var(--text-secondary); }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div>
                <h1>Auditoría de permisos de SPO</h1>
                <p>Auditoría de accesos para el site $auditedSiteNameEsc</p>
            </div>
            <div class="header-meta">
                <p>Usuario: <span>$userAccountEsc</span></p>
                <p>Fecha de auditoría: <span>$dateNowStr</span></p>
                <p>Tiempo transcurrido: <span>$ElapsedTime</span></p>
            </div>
        </div>

        <div class="info-banner">
            <strong>Estructura de SharePoint Online:</strong>
            <span> <b>Sitio principal</b> es el sitio independiente raíz. <b>Subsitio</b> es un sitio secundario hijo. <b>Carpeta con permisos únicos</b> indica una biblioteca o carpeta donde se han personalizado los permisos.</span>
        </div>

        <div class="metrics-grid">
            <div class="metric-card">
                <div class="title">Total espacios</div>
                <div class="value">$TotalSitesCount</div>
                <div class="subtext">Analizados en total</div>
            </div>
            <div class="metric-card">
                <div class="title">Sitios principales</div>
                <div class="value">$PrimarySitesCount</div>
                <div class="subtext">Colecciones independientes</div>
            </div>
            <div class="metric-card">
                <div class="title">Subsitios</div>
                <div class="value">$SubsitesCount</div>
                <div class="subtext">Sitios secundarios/hijos</div>
            </div>
            <div class="metric-card">
                <div class="title">Carpetas / bibliotecas</div>
                <div class="value">$FoldersCount</div>
                <div class="subtext">Con permisos únicos</div>
            </div>
            <div class="metric-card">
                <div class="title">Equipos Teams</div>
                <div class="value">$TeamSitesCount</div>
                <div class="subtext">Sitios M365</div>
            </div>
            <div class="metric-card">
                <div class="title">Usuarios únicos</div>
                <div class="value">$uniqueUsersCount</div>
                <div class="subtext">Personas físicas</div>
            </div>
        </div>

        <div class="toolbar">
            <div class="filter-tabs">
                <button class="tab-btn active" onclick="switchView('sites', event)">Vista por sitio / subsitio / carpeta ($TotalSitesCount)</button>
                <button class="tab-btn" onclick="switchView('users', event)">Vista matriz por usuario ($uniqueUsersCount)</button>
                <button class="tab-btn" onclick="filterCategory('principal', event)">Sitios principales ($PrimarySitesCount)</button>
                <button class="tab-btn" onclick="filterCategory('subsite', event)">Subsitios ($SubsitesCount)</button>
                <button class="tab-btn" onclick="filterCategory('folder', event)">Carpetas únicas ($FoldersCount)</button>
                <button class="tab-btn" onclick="filterCategory('teams', event)">Equipos Teams ($TeamSitesCount)</button>
            </div>
            <div class="search-box">
                <input type="text" id="tableSearch" placeholder="Buscar usuario, correo, sitio o carpeta..." onkeyup="searchSites()">
            </div>
        </div>

        <!-- VISTA 1: ORGANIZADA POR SITIO Y SUBSITIO Y CARPETAS -->
        <div id="sitesView" class="view-section">
            <div class="section-title">Desglose de permisos por sitio, subsitio y carpetas con permisos únicos</div>
            <div id="sitesContainer">
                $cardsBodyHtml
            </div>
        </div>

        <!-- VISTA 2: MATRIZ POR USUARIO -->
        <div id="usersView" class="view-section" style="display: none;">
            <div class="section-title">Matriz completa por usuario</div>
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
            <p>Autor: Alejandro Suárez Fernández</p>
        </div>
    </div>

    <script>
        var currentFilter = 'all';

        function switchView(viewName, event) {
            document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
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
            document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
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

    $htmlContent | Out-File -FilePath $FilePath -Encoding UTF8 -Force
    Write-StatusMsg -Message "Informe HTML guardado en: $FilePath" -Status "SUCCESS"
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# PASO 2: Descubrimiento de sitios principales en el tenant
Write-StepHeader -StepNumber 2 -TotalSteps 6 -Title "Búsqueda de sitios principales en el tenant"

Write-StatusMsg -Message "Buscando sitios en SharePoint..." -Status "WORKING"
$allSitesRaw = [System.Collections.Generic.List[PSObject]]::new()
$m365GroupUrls = @{}
$m365GroupIdMap = @{}

# A. Si se proporcionó parámetro -SiteUrl / -SiteName, intentar resolución directa primero
$targetSiteFilter = if ($SiteUrl) { $SiteUrl } elseif ($SiteName) { $SiteName } else { "" }
if ($targetSiteFilter) {
    Write-StatusMsg -Message "Filtro indicado por parámetro: '$targetSiteFilter'" -Status "INFO"
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

# B. Consultar la API de búsqueda de Graph iterando por letras y palabras clave
Write-StatusMsg -Message "Consultando el catálogo exhaustivo de sitios..." -Status "WORKING"
$searchTerms = 97..122 | ForEach-Object { [char]$_ }
$searchTerms += 0..9 | ForEach-Object { [string]$_ }
$searchTerms += @("msteams", "rrhh", "level", "fly", "test", "viva", "http", "administracion", "site")

foreach ($term in $searchTerms) {
    try {
        $res = Invoke-GraphPaginatedRequest -Uri "v1.0/sites?search=$term"
        if ($res) {
            foreach ($item in $res) { $allSitesRaw.Add($item) }
        }
    } catch {}
}

# C. Descubrir sitios asociados a Grupos de M365 y Teams
Write-StatusMsg -Message "Buscando sitios asociados a Teams y grupos de Microsoft 365..." -Status "WORKING"
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
                $possibleNames = @($grp.mailNickname, $grp.displayName)
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

# D. Resolución directa de rutas conocidas del tenant
$knownSitePaths = @("rrhh", "test", "administracion", "msteams_f72f18_083716")
foreach ($path in $knownSitePaths) {
    try {
        $directSite = Invoke-GraphRequestWithRetry -Uri "v1.0/sites/${tenantHostName}:/sites/$path"
        if ($directSite -and ($directSite.id -or $directSite.webUrl)) {
            $allSitesRaw.Add($directSite)
        }
    } catch {}
}

# E. Fallback a getAllSites (acceso de aplicación)
try {
    $sitesAll = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/getAllSites"
    if ($sitesAll) {
        foreach ($s in $sitesAll) { $allSitesRaw.Add($s) }
    }
} catch {}

# F. Incluir sitio raíz del tenant
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

# Ordenar por título
$sortedSites = $generalSitesList | Sort-Object -Property Title
$generalSitesList = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($s in $sortedSites) { $generalSitesList.Add($s) }

Write-StatusMsg -Message "Se han encontrado $($generalSitesList.Count) sitios principales." -Status "SUCCESS"

# PASO 3: Selección del sitio objetivo
Write-StepHeader -StepNumber 3 -TotalSteps 6 -Title "Selección del sitio a auditar"

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
        Write-StatusMsg -Message "No se encontró ningún sitio que coincida con '$targetSiteFilter'. Se analizarán todos los sitios." -Status "WARN"
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
        Write-StatusMsg -Message "Modo no interactivo detectado. Seleccionando la opción de auditar todos los sitios." -Status "INFO"
        foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
    } else {
        # MENÚ INTERACTIVO SENCILLO, ALINEADO Y PROFESIONAL
        Write-Host "`n--------------------------------------------------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host " Sitios disponibles en el tenant" -ForegroundColor White
        Write-Host "--------------------------------------------------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host " Selecciona el sitio que deseas auditar (se analizará la raíz, subsitios y carpetas):`n" -ForegroundColor Gray

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
        Write-Host "--------------------------------------------------------------------------------------------------------`n" -ForegroundColor Cyan

        $userChoice = Read-Host "Elige una opción [0-$($generalSitesList.Count)]"

        if ($userChoice -match '^\d+$' -and [int]$userChoice -ge 1 -and [int]$userChoice -le $generalSitesList.Count) {
            $selectedIndex = [int]$userChoice - 1
            $selectedGeneralSites.Add($generalSitesList[$selectedIndex])
            Write-StatusMsg -Message "Sitio elegido: '$($selectedGeneralSites[0].Title)'" -Status "SUCCESS"
        } else {
            Write-StatusMsg -Message "Opción elegida: Auditar todos los sitios." -Status "SUCCESS"
            foreach ($s in $generalSitesList) { $selectedGeneralSites.Add($s) }
        }
    }
}

# PASO 4: Búsqueda de subsitios
Write-StepHeader -StepNumber 4 -TotalSteps 6 -Title "Búsqueda de subsitios"

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
                    SiteType = "Subsitio de SharePoint"
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

# PASO 5: Búsqueda de carpetas con permisos únicos
Write-StepHeader -StepNumber 5 -TotalSteps 6 -Title "Búsqueda de carpetas con permisos propios"

Write-StatusMsg -Message "Comprobando bibliotecas y carpetas con permisos personalizados..." -Status "WORKING"

$sitesToScanDrives = @($script:finalAuditedSites)
foreach ($site in $sitesToScanDrives) {
    if (-not $site.IsFolder -and $site.Id) {
        try {
            $drives = Invoke-GraphPaginatedRequest -Uri "v1.0/sites/$($site.Id)/drives"
            foreach ($drive in $drives) {
                $driveName = if ($drive.name) { $drive.name } else { "Biblioteca de Documentos" }
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

# PASO 6: Análisis de permisos por usuario y grupo
Write-StepHeader -StepNumber 6 -TotalSteps 6 -Title "Análisis de permisos de usuarios y grupos"

$permissionReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$failedSites = [System.Collections.Generic.List[PSCustomObject]]::new()
$siteIndex = 0

foreach ($site in $script:finalAuditedSites) {
    $siteIndex++
    $percent = [math]::Round(($siteIndex / $script:finalAuditedSites.Count) * 100, 1)
    
    Write-Host "  [$siteIndex/$($script:finalAuditedSites.Count)] ($percent%) Auditando: $($site.Title) -> $($site.WebUrl)" -ForegroundColor Gray

    try {
        # Si es una carpeta con permisos únicos ya detectada, procesar sus permisos directamente
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
                                    $uName = if ($spU.displayName) { $spU.displayName } else { "Usuario SharePoint" }
                                    $uEmail = if ($spU.userPrincipalName) { $spU.userPrincipalName } elseif ($spU.email) { $spU.email } else { $spU.id }
                                    
                                    if ($uEmail -like "*#EXT#*") {
                                        if ($spU.email) { $uEmail = $spU.email }
                                        elseif ($uEmail -match "([^=]+)_([^@]+)#EXT#@") { $uEmail = "$($Matches[1])@$($Matches[2])" }
                                    }

                                    $spRole = switch -Regex ($spGrpName) {
                                        "Owner|Propietario|Owners" { "Control total (owner de grupo SharePoint)" }
                                        "Member|Miembro|Members" { "Edicion / colaboracion (member de grupo SharePoint)" }
                                        "Visitor|Visitante|Visitors" { "Solo lectura (visitor de grupo SharePoint)" }
                                        default { "Acceso via grupo SharePoint ($spGrpName)" }
                                    }

                                    if ($uEmail -notlike "*app@sharepoint*" -and $uEmail -notlike "*system*") {
                                        $permissionReport.Add([PSCustomObject]@{
                                            UserName              = $uName
                                            UserEmail             = $uEmail
                                            SiteTitle             = $site.Title
                                            SiteUrl               = $site.WebUrl
                                            SiteType              = $site.SiteType
                                            SitePermissions       = $spRole
                                            AccessSource          = "Miembro de grupo SharePoint ($spGrpName)"
                                            HasInheritanceEnabled = if ($site.SiteType -like "*Subsitio*") { "Si (grupo de sitio principal)" } else { "No (permisos directos del sitio principal)" }
                                            InheritanceDetail     = "Grupo nativo SharePoint: $spGrpName"
                                            AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                                        })
                                    }
                                }
                            }
                        } catch {
                            Write-Verbose "Error al leer usuarios de grupo SharePoint $spGrpName : $($_.Exception.Message)"
                        }
                    }
                }
            }
        } catch {
            Write-Verbose "Error al obtener siteGroups para $($site.WebUrl): $($_.Exception.Message)"
        }

        # B. Extraer administradores de la colección de sitios (Site Collection Admins)
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

        # C. Extraer propietarios y miembros del Grupo M365 / Teams asociado
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
                            SitePermissions       = "Control total (owner de equipo / grupo M365)"
                            AccessSource          = "Propietario de grupo M365"
                            HasInheritanceEnabled = "No (permisos directos de grupo)"
                            InheritanceDetail     = "Propietario del equipo de Teams"
                            AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                        })
                    }
                }
            } catch {
                Write-Verbose "Error al obtener propietarios M365: $($_.Exception.Message)"
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
                            SitePermissions       = "Edicion / colaboracion (member de equipo / grupo M365)"
                            AccessSource          = "Miembro de grupo M365"
                            HasInheritanceEnabled = "No (permisos directos de grupo)"
                            InheritanceDetail     = "Miembro del equipo de Teams"
                            AuditDate             = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                        })
                    }
                }
            } catch {
                Write-Verbose "Error al obtener miembros M365: $($_.Exception.Message)"
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
                                        SitePermissions       = "Control total (owner de grupo Entra ID)"
                                        AccessSource          = "Usuario via grupo Entra ID ($grpName)"
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
                                        SitePermissions       = "Edicion / colaboracion (member de grupo Entra ID)"
                                        AccessSource          = "Usuario via grupo Entra ID ($grpName)"
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
    $userAccount = if ($context -and $context.Account) { $context.Account } else { "Usuario M365" }
    
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
Write-Host "                          Resumen de auditoría                           " -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "  Tiempo total                : $elapsedTime" -ForegroundColor White
Write-Host "  Sitios y carpetas analizados: $($script:finalAuditedSites.Count)" -ForegroundColor White
Write-Host "  Sitios procesados con éxito : $($script:finalAuditedSites.Count - $failedSites.Count)" -ForegroundColor Green
Write-Host "  Sitios con error u omitidos : $($failedSites.Count)" -ForegroundColor $(if ($failedSites.Count -gt 0) { "Yellow" } else { "Gray" })
Write-Host "  Registros de permisos       : $($permissionReport.Count)" -ForegroundColor White
Write-Host "  Usuarios únicos             : $(if ($userSummary) { $userSummary.Count } else { 0 })" -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan

if ($userSummary -and $userSummary.Count -gt 0) {
    Write-Host "`nTop 5 usuarios con mayor número de accesos:" -ForegroundColor Yellow
    $userSummary | Select-Object -First 5 UserName, UserEmail, TotalSitesAccess, PermissionTypes | Format-Table -AutoSize
}

Write-StatusMsg -Message "Auditoría finalizada." -Status "SUCCESS"
