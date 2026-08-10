<#
.SYNOPSIS
    Pruebas-Seeding - Generador de Permisos Unicos y Ruptura de Herencia en SharePoint Online.

.DESCRIPTION
    Script de pruebas (seeding) que se conecta a SharePoint online via Microsoft graph api,
    resuelve el sitio especificado, crea una biblioteca y carpetas de prueba ('Biblioteca_Pruebas_Permisos')
    y rompe la herencia de permisos asignando permisos explicitos directos a usuarios o grupos de prueba
    para simular escenarios reales que puedan ser detectados y auditados por el script de auditoria de permisos.

.REQUISITOS Y COMPATIBILIDAD
    - Entorno: Windows PowerShell 5.1 / PowerShell 7+ / Azure cloud shell
    - Modulo: Microsoft.Graph.Authentication (se instala automaticamente si no esta presente)
    - Permisos: Sites.FullControl.All o Sites.ReadWrite.All en Microsoft graph api

.PARAMETER SiteUrl
    URL completa o nombre del sitio de SharePoint objetivo (ej. "https://contoso.sharepoint.com/sites/Proyectos" o "Proyectos").

.PARAMETER LibraryName
    Nombre de la biblioteca de documentos de prueba a crear (por defecto: "Biblioteca_Pruebas_Permisos").

.PARAMETER FolderCount
    Numero de carpetas con permisos unicos a generar (por defecto: 3).

.PARAMETER TargetUserEmail
    Correo electronico del usuario al que se le asignaran permisos explicitos de prueba (opcional).

.PARAMETER TenantId
    ID o dominio del tenant de Microsoft 365 (para autenticacion desatendida).

.PARAMETER ClientId
    ID de la aplicacion (App ID) de Entra id.

.PARAMETER ClientSecret
    Secreto de aplicacion (Client secret).

.EXAMPLE
    & '.\Pruebas-Seeding\Pruebas-Seeding - Generador_Permisos_Unicos_SharePoint.ps1' -SiteUrl "Proyectos"

.EXAMPLE
    & '.\Pruebas-Seeding\Pruebas-Seeding - Generador_Permisos_Unicos_SharePoint.ps1' -SiteUrl "https://contoso.sharepoint.com/sites/Proyectos" -TargetUserEmail "usuario.demo@contoso.com"

.NOTES
    Nombre:   Pruebas-Seeding - Generador_Permisos_Unicos_SharePoint.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.0.0
    Fecha:    2026-08-10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SiteUrl = "",

    [string]$LibraryName = "Biblioteca_Pruebas_Permisos",
    [int]$FolderCount = 3,
    [string]$TargetUserEmail = "",
    [string]$TenantId = "",
    [string]$ClientId = "",
    [string]$ClientSecret = ""
)

# Validar e instalar modulo requerido si no esta presente
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "  [*] Instalando modulo requerido 'Microsoft.Graph.Authentication' desde PowerShell gallery..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

function Write-StatusMsg {
    param([string]$Message, [string]$Status = "INFO")
    switch ($Status) {
        "SUCCESS" { Write-Host "  [+] $Message" -ForegroundColor Green }
        "WORKING" { Write-Host "  [*] $Message" -ForegroundColor Yellow }
        "INFO"    { Write-Host "  [i] $Message" -ForegroundColor Cyan }
        "WARN"    { Write-Host "  [!] $Message" -ForegroundColor DarkYellow }
        "FAIL"    { Write-Host "  [x] $Message" -ForegroundColor Red }
        default   { Write-Host "  [-] $Message" -ForegroundColor Gray }
    }
}

function Invoke-MgGraphWithRetry {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Body = $null,
        [string]$ContentType = "application/json",
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
            if ($Body) {
                $Params.Body = ($Body | ConvertTo-Json -Depth 5 -Compress)
                $Params.ContentType = $ContentType
            }
            return Invoke-MgGraphRequest @Params
        } catch {
            $Ex = $_.Exception
            $StatusCode = 0
            if ($Ex.Response -and $Ex.Response.StatusCode) {
                $StatusCode = [int]$Ex.Response.StatusCode
            }
            if (($StatusCode -eq 429 -or $StatusCode -eq 503 -or $StatusCode -eq 504) -and $Attempt -le $MaxRetries) {
                $WaitTimeSec = 5 * $Attempt
                Write-StatusMsg "Limitacion Graph API (HTTP $StatusCode). Esperando $WaitTimeSec s (Intento $Attempt/$MaxRetries)..." -Status "WARN"
                Start-Sleep -Seconds $WaitTimeSec
            } else {
                throw $_
            }
        }
    }
}

Clear-Host
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "   GENERADOR DE PERMISOS UNICOS EN SHAREPOINT ONLINE (SEEDING PERMISOS)   " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Version: 1.0.0 | Graph API | Autor: Alejandro Suarez (@alexsf93)" -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------------------------------
# AUTENTICACION GRAPH API
# -------------------------------------------------------------------------
$Scopes = @("Sites.FullControl.All", "Sites.ReadWrite.All", "Files.ReadWrite.All", "User.Read.All")

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
        Write-StatusMsg "Conexion establecida mediante app registration." -Status "SUCCESS"
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
# SELECCION DE SITIO SHAREPOINT
# -------------------------------------------------------------------------
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
        Write-StatusMsg "Error al obtener lista de sitios: $_" -Status "FAIL"
        exit 1
    }

    if (-not $AllSites -or $AllSites.Count -eq 0) {
        Write-StatusMsg "No se encontraron sitios en el tenant." -Status "FAIL"
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

# -------------------------------------------------------------------------
# CREACION O LOCALIZACION DE BIBLIOTECA DE PRUEBAS
# -------------------------------------------------------------------------
Write-StatusMsg "Verificando biblioteca de documentos '$LibraryName'..." -Status "WORKING"

$DrivesUri = "v1.0/sites/$SiteId/drives"
$Drives = (Invoke-MgGraphWithRetry -Method GET -Uri $DrivesUri).value
$TargetDrive = $Drives | Where-Object { $_.name -eq $LibraryName }

if (-not $TargetDrive) {
    Write-StatusMsg "Creando nueva biblioteca de documentos '$LibraryName'..." -Status "WORKING"
    $CreateDriveBody = @{
        name        = $LibraryName
        description = "Biblioteca de pruebas para verificacion de permisos unicos y ruptura de herencia"
        list        = @{ template = "documentLibrary" }
    }
    try {
        $TargetDrive = Invoke-MgGraphWithRetry -Method POST -Uri "v1.0/sites/$SiteId/lists" -Body $CreateDriveBody
        # Re-consultar drives para obtener el objeto drive completo
        Start-Sleep -Seconds 2
        $Drives = (Invoke-MgGraphWithRetry -Method GET -Uri $DrivesUri).value
        $TargetDrive = $Drives | Where-Object { $_.name -eq $LibraryName }
        Write-StatusMsg "Biblioteca '$LibraryName' creada exitosamente." -Status "SUCCESS"
    } catch {
        Write-StatusMsg "No se pudo crear la biblioteca especifica. Usando la biblioteca por defecto 'Documents'..." -Status "WARN"
        $TargetDrive = $Drives | Where-Object { $_.driveType -eq "documentLibrary" } | Select-Object -First 1
    }
}

if (-not $TargetDrive) {
    Write-StatusMsg "No se pudo localizar ninguna biblioteca valida para crear estructuras de permisos." -Status "FAIL"
    exit 1
}

$DriveId = $TargetDrive.id
Write-StatusMsg "Biblioteca objetivo ID: $DriveId" -Status "INFO"

# -------------------------------------------------------------------------
# GENERACION DE CARPETAS DE PRUEBA Y ASIGNACION DE PERMISOS UNICOS
# -------------------------------------------------------------------------
Write-StatusMsg "Generando $FolderCount carpetas de prueba con permisos unicos explicitos..." -Status "WORKING"

$RolesList = @("read", "write")
$CreatedFolders = @()

for ($i = 1; $i -le $FolderCount; $i++) {
    $FolderName = "Carpeta_Permisos_Unicos_$i"
    Write-StatusMsg "Creando carpeta '$FolderName'..." -Status "WORKING"

    $FolderBody = @{
        name   = $FolderName
        folder = @{}
        "@microsoft.graph.conflictBehavior" = "replace"
    }

    try {
        $CreateFolderUri = "v1.0/sites/$SiteId/drives/$DriveId/root/children"
        $FolderItem = Invoke-MgGraphWithRetry -Method POST -Uri $CreateFolderUri -Body $FolderBody
        Write-StatusMsg "  Carpeta creada ID: $($FolderItem.id)" -Status "SUCCESS"

        # Romper herencia / Asignar permiso de comparticion explícito si se proporcionó correo de usuario
        if ($TargetUserEmail) {
            Write-StatusMsg "  Asignando permiso explicito direct a '$TargetUserEmail'..." -Status "WORKING"
            $InviteBody = @{
                recipients      = @(@{ email = $TargetUserEmail })
                message         = "Acceso de prueba generado automaticamente para auditoria de permisos."
                requireSignIn   = $true
                sendInvitation  = $false
                roles           = @($RolesList[$i % $RolesList.Count])
            }

            $InviteUri = "v1.0/sites/$SiteId/drives/$DriveId/items/$($FolderItem.id)/invite"
            try {
                $InviteResp = Invoke-MgGraphWithRetry -Method POST -Uri $InviteUri -Body $InviteBody
                Write-StatusMsg "  Permiso de rol '$($RolesList[$i % $RolesList.Count])' asignado a '$TargetUserEmail'." -Status "SUCCESS"
            } catch {
                Write-StatusMsg "  No se pudo asignar el permiso a '$TargetUserEmail': $_" -Status "WARN"
            }
        } else {
            # Crear un enlace de intercambio o permiso explicito anonimo / de organizacion para forzar ruptura de herencia
            Write-StatusMsg "  Creando permiso explicito de organizacion (ruptura de herencia)..." -Status "WORKING"
            $LinkBody = @{
                type = "view"
                scope = "organization"
            }
            $LinkUri = "v1.0/sites/$SiteId/drives/$DriveId/items/$($FolderItem.id)/createLink"
            try {
                $LinkResp = Invoke-MgGraphWithRetry -Method POST -Uri $LinkUri -Body $LinkBody
                Write-StatusMsg "  Permiso unico configurado en la carpeta." -Status "SUCCESS"
            } catch {
                Write-StatusMsg "  Aviso al configurar vinculo explicito: $_" -Status "WARN"
            }
        }

        $CreatedFolders += $FolderName
    } catch {
        Write-StatusMsg "Error al procesar carpeta '$FolderName': $_" -Status "WARN"
    }
}

Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                    RESUMEN DE SEEDING DE PERMISOS                       " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Sitio objetivo                       : {0}" -f $TargetSite.displayName) -ForegroundColor White
Write-Host (" Biblioteca de prueba                 : {0}" -f $TargetDrive.name) -ForegroundColor White
Write-Host (" Carpetas creadas con permisos unicos : {0}" -f $CreatedFolders.Count) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

Write-StatusMsg "Proceso de seeding finalizado con exito." -Status "SUCCESS"
Write-StatusMsg "Ahora puede ejecutar 'Microsoft 365 - SharePoint - Auditoria_Permisos.ps1' para auditar este sitio." -Status "INFO"
