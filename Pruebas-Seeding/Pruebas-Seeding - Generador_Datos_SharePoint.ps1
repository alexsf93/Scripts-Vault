<#
.SYNOPSIS
    Pruebas-Seeding - Generador de Datos de Prueba para SharePoint Online (Sitios, Bibliotecas y Versiones).

.DESCRIPTION
    Script de pruebas (seeding) que se conecta a SharePoint Online via Microsoft Graph API,
    resuelve el sitio especificado, crea una biblioteca de documentos de prueba ('Biblioteca_Pruebas_Limpieza'),
    sube archivos de ejemplo y realiza multiples actualizaciones de contenido para forzar la creacion
    de historial de versiones real (5 a 10 versiones por archivo) y simular consumo de espacio.

.REQUISITOS Y COMPATIBILIDAD
    - Entorno: Windows PowerShell 5.1 / PowerShell 7+ / Azure Cloud Shell (Bash / PowerShell)
    - Modulo: Microsoft.Graph.Authentication (se instala automaticamente si no esta presente)
    - Permisos: Sites.FullControl.All o Sites.ReadWrite.All en Microsoft Graph API

.PARAMETER SiteUrl
    URL completa o nombre del sitio de SharePoint objetivo (ej: "https://contoso.sharepoint.com/sites/Proyectos" o "Proyectos").

.PARAMETER LibraryName
    Nombre de la biblioteca de documentos de prueba a crear (por defecto: "Biblioteca_Pruebas_Limpieza").

.PARAMETER FileCount
    Numero de archivos de prueba a generar (por defecto: 5).

.PARAMETER VersionsPerFile
    Numero de versiones a generar para cada archivo (por defecto: 8).

.PARAMETER TenantId
    ID o dominio del tenant de Microsoft 365 (para autenticacion desatendida).

.PARAMETER ClientId
    ID de la aplicacion (App ID) de Entra ID.

.PARAMETER ClientSecret
    Secreto de aplicacion (Client Secret).

.EXAMPLE
    & '.\Pruebas-Seeding\Pruebas-Seeding - Generador_Datos_SharePoint.ps1' -SiteUrl "Proyectos"

.EXAMPLE
    & '.\Pruebas-Seeding\Pruebas-Seeding - Generador_Datos_SharePoint.ps1' -SiteUrl "https://contoso.sharepoint.com/sites/Proyectos" -VersionsPerFile 10

.NOTES
    Nombre:   Pruebas-Seeding - Generador_Datos_SharePoint.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.0.0
    Fecha:    2026-08-07
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SiteUrl = "",

    [string]$LibraryName = "Biblioteca_Pruebas_Limpieza",
    [int]$FileCount = 5,
    [int]$VersionsPerFile = 8,
    [string]$TenantId = "",
    [string]$ClientId = "",
    [string]$ClientSecret = ""
)

# Validar e instalar modulo requerido si no esta presente
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "  [*] Instalando modulo requerido 'Microsoft.Graph.Authentication' desde PowerShell Gallery..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

function Write-StatusMsg {
    param([string]$Message, [string]$Status = "INFO")
    switch ($Status) {
        "SUCCESS" { Write-Host "  [+] $Message" -ForegroundColor Green }
        "WORKING" { Write-Host "  [*] $Message" -ForegroundColor Yellow }
        "INFO"    { Write-Host "  [i]" $Message -ForegroundColor Cyan }
        "WARN"    { Write-Host "  [!]" $Message -ForegroundColor DarkYellow }
        "FAIL"    { Write-Host "  [x]" $Message -ForegroundColor Red }
        default   { Write-Host "  [-]" $Message -ForegroundColor Gray }
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

function Invoke-MgGraphWithRetry {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Body = $null,
        [string]$ContentType = "application/json",
        [byte[]]$BinaryContent = $null,
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
            if ($BinaryContent) {
                $Params.Body = $BinaryContent
                $Params.ContentType = "application/octet-stream"
            } elseif ($Body) {
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
Write-Host "   GENERADOR DE DATOS DE PRUEBA EN SHAREPOINT ONLINE (SEEDING RUIDO)    " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Version: 1.0.0 | Graph API | Autor: Alejandro Suarez (@alexsf93)" -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------------------------------
# AUTENTICACIÓN GRAPH API
# -------------------------------------------------------------------------
$Scopes = @("Sites.FullControl.All", "Sites.ReadWrite.All", "Files.ReadWrite.All")

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
        Write-StatusMsg "Conexion establecida mediante App Registration." -Status "SUCCESS"
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
# RESOLUCIÓN DEL SITIO
# -------------------------------------------------------------------------
if (-not $SiteUrl) {
    $SiteUrl = Read-Host "`nIngrese el nombre o URL del sitio de SharePoint (ej. 'Proyectos' o 'https://contoso.sharepoint.com/sites/Proyectos')"
}
if ([string]::IsNullOrWhiteSpace($SiteUrl)) {
    Write-StatusMsg "Debe indicar un sitio de SharePoint valido." -Status "FAIL"
    exit 1
}

Write-StatusMsg "Resolviendo sitio de SharePoint '$SiteUrl'..." -Status "WORKING"

$SiteId = ""
try {
    if ($SiteUrl -match "^https?://") {
        $UriObj = [System.Uri]$SiteUrl
        $HostName = $UriObj.Host
        $RelativePath = $UriObj.AbsolutePath
        $GraphSiteUri = "v1.0/sites/${HostName}:${RelativePath}"
        $SiteResp = Invoke-MgGraphWithRetry -Method GET -Uri $GraphSiteUri
        $SiteId = $SiteResp.id
    } else {
        $CleanName = $SiteUrl.TrimStart('/')
        $GraphSiteUri = "v1.0/sites?`$search=$CleanName"
        $SiteResp = Invoke-MgGraphWithRetry -Method GET -Uri $GraphSiteUri
        if ($SiteResp.value -and $SiteResp.value.Count -gt 0) {
            $SiteId = $SiteResp.value[0].id
        }
    }
} catch {}

if (-not $SiteId) {
    Write-StatusMsg "No se pudo resolver el sitio '$SiteUrl'. Asegurese de que el sitio exista y tenga permisos." -Status "FAIL"
    exit 1
}

Write-StatusMsg "Sitio resuelto correctamente (ID: $SiteId)." -Status "SUCCESS"

# -------------------------------------------------------------------------
# CREACIÓN DE LA BIBLIOTECA DE PRUEBAS
# -------------------------------------------------------------------------
Write-StatusMsg "Verificando/Creando biblioteca de documentos '$LibraryName'..." -Status "WORKING"

$DriveId = ""
try {
    $DrivesResp = Invoke-MgGraphWithRetry -Method GET -Uri "v1.0/sites/$SiteId/drives"
    if ($DrivesResp.value) {
        $ExistingDrive = $DrivesResp.value | Where-Object { $_.name -eq $LibraryName }
        if ($ExistingDrive) {
            $DriveId = $ExistingDrive.id
            Write-StatusMsg "Biblioteca '$LibraryName' ya existente encontrada (ID: $DriveId)." -Status "SUCCESS"
        }
    }
} catch {}

if (-not $DriveId) {
    try {
        $NewListBody = @{
            displayName = $LibraryName
            list        = @{ template = "documentLibrary" }
        }
        $CreatedList = Invoke-MgGraphWithRetry -Method POST -Uri "v1.0/sites/$SiteId/lists" -Body $NewListBody
        
        # Obtener el Drive asociado a la nueva lista
        Start-Sleep -Seconds 2
        $DrivesResp = Invoke-MgGraphWithRetry -Method GET -Uri "v1.0/sites/$SiteId/drives"
        $NewDrive = $DrivesResp.value | Where-Object { $_.name -eq $LibraryName }
        if ($NewDrive) {
            $DriveId = $NewDrive.id
            Write-StatusMsg "Biblioteca '$LibraryName' creada con exito (ID: $DriveId)." -Status "SUCCESS"
        }
    } catch {
        Write-StatusMsg "Error al crear la biblioteca '$LibraryName': $_" -Status "FAIL"
        exit 1
    }
}

if (-not $DriveId) {
    Write-StatusMsg "No se pudo obtener el ID del Drive de la biblioteca." -Status "FAIL"
    exit 1
}

# -------------------------------------------------------------------------
# GENERACIÓN DE ARCHIVOS Y VERSIONES DE PRUEBA
# -------------------------------------------------------------------------
Write-StatusMsg "Generando $FileCount archivos con $VersionsPerFile versiones cada uno..." -Status "WORKING"

$FileTemplates = @(
    "Documento_Proyecto_Alpha.docx",
    "Informe_Financiero_2025.xlsx",
    "Plan_Estrategico_Empresa.pptx",
    "Manual_Procedimientos_Seguridad.pdf",
    "Auditoria_Control_Interno.docx"
)

$TotalVersionsCreated = 0

for ($i = 0; $i -lt $FileCount; $i++) {
    $FileName = if ($i -lt $FileTemplates.Count) { $FileTemplates[$i] } else { "Archivo_Prueba_$($i + 1).docx" }
    
    Write-Host "`n  -> Generando archivo '$FileName':" -ForegroundColor Cyan
    
    for ($v = 1; $v -le $VersionsPerFile; $v++) {
        Write-Progress -Activity "Creando versiones de archivos" -Status "Archivo '$FileName' - Version $v de $VersionsPerFile" -PercentComplete (($v / $VersionsPerFile) * 100)
        
        # Contenido variable simulado con diferente tamano para forzar versiones distintas
        $TimestampText = (Get-SpainDateTime).ToString("yyyy-MM-dd HH:mm:ss")
        $RandomContentText = ("Contenido de prueba de la version $v para $FileName.`nFecha de modificacion: $TimestampText`n" + ("X" * ($v * 1024 * 50)))
        $BinaryData = [System.Text.Encoding]::UTF8.GetBytes($RandomContentText)

        $UploadUri = "v1.0/sites/$SiteId/drives/$DriveId/root:/${FileName}:/content"
        try {
            $UploadResp = Invoke-MgGraphWithRetry -Method PUT -Uri $UploadUri -BinaryContent $BinaryData
            $TotalVersionsCreated++
            Write-Host "     [+] Version $v creada ($([math]::Round($BinaryData.Length / 1KB, 2)) KB)" -ForegroundColor DarkGray
        } catch {
            Write-StatusMsg "Error al crear la version $v de '$FileName': $_" -Status "WARN"
        }
        
        Start-Sleep -Milliseconds 300
    }
}

Write-Progress -Activity "Creando versiones de archivos" -Completed

Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                DATOS DE PRUEBA GENERADOS EN SHAREPOINT                  " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Sitio de SharePoint                   : {0}" -f $SiteUrl) -ForegroundColor White
Write-Host (" Biblioteca de Documentos              : {0}" -f $LibraryName) -ForegroundColor Yellow
Write-Host (" Total de Archivos Creados             : {0}" -f $FileCount) -ForegroundColor White
Write-Host (" Total de Versiones de Historial       : {0}" -f $TotalVersionsCreated) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

Write-Host "💡 AHORA PUEDES PROBAR EL SCRIPT DE LIMPIEZA CON ESTE COMANDO:" -ForegroundColor Yellow
Write-Host "   .\'Microsoft 365 - SharePoint - Limpieza_Historial_Versiones.ps1' -SiteUrl '$SiteUrl' -LibraryName '$LibraryName' -KeepVersions 2`n" -ForegroundColor Cyan
