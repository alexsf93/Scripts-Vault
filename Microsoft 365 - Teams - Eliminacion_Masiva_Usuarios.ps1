<#
.SYNOPSIS
    Microsoft Teams - Eliminacion Masiva de Usuarios.

.DESCRIPTION
    Este script elimina usuarios de un equipo de Microsoft Teams basandose en su rol (Invitados, Miembros, o Ambos).
    Soporta filtrado por dominio, exclusion automatica de propietarios y generacion de logs.

.PARAMETER TeamName
    Nombre del equipo de Teams.

.PARAMETER TargetRole
    Rol a eliminar: 'Guest', 'Member', o 'Both'.

.PARAMETER Domain
    (Opcional) Dominio para filtrar usuarios (ej: externo.com).

.EXAMPLE
    & '.\Microsoft 365 - Teams - Eliminacion_Masiva_Usuarios.ps1' -TeamName "Proyecto X" -TargetRole Guest
    Elimina todos los invitados del equipo.

.EXAMPLE
    & '.\Microsoft 365 - Teams - Eliminacion_Masiva_Usuarios.ps1' -TeamName "Proyecto X" -TargetRole Member -Domain "contratista.org"
    Elimina miembros del dominio especificado.

.NOTES
    Nombre:   Microsoft 365 - Teams - Eliminacion_Masiva_Usuarios.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.0.1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$TeamName,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Guest', 'Member', 'Both')]
    [string]$TargetRole,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$')]
    [string]$Domain,

    [Parameter(Mandatory = $false, HelpMessage = "Tiempo de pausa en ms entre eliminaciones para evitar alertas de Entra Identity Protection")]
    [int]$RequestDelayMs = 300
)

Write-Host "Rol objetivo: $TargetRole" -ForegroundColor Cyan
if ($Domain) {
    Write-Host ("Filtro de dominio: *@" + $Domain + " (y formato #EXT#)") -ForegroundColor Cyan
}

# Forzar UTF-8
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

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

# ---------------------------------------------------------
# 1. Conexion a Microsoft Teams
# ---------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
    Write-Host "Instalando modulo requerido 'MicrosoftTeams' desde PowerShell Gallery..." -ForegroundColor Yellow
    Install-Module MicrosoftTeams -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module MicrosoftTeams -ErrorAction Stop

Write-Host "Conectando a Microsoft Teams..." -ForegroundColor Cyan
if ($env:ACC_CLOUD -or $env:AZURE_HTTP_USER_AGENT -match 'cloud-shell') {
    Connect-MicrosoftTeams -UseDeviceAuthentication
}
else {
    try {
        Connect-MicrosoftTeams -ErrorAction Stop
    }
    catch {
        Connect-MicrosoftTeams -UseDeviceAuthentication
    }
}

# ---------------------------------------------------------
# 2. Obtener Equipo y Miembros
# ---------------------------------------------------------
Write-Host "Buscando equipo '$TeamName'..." -ForegroundColor Cyan
try {
    $team = Get-Team -DisplayName $TeamName -ErrorAction Stop
    if ($team.Count -gt 1) {
        Write-Error "Multiples equipos encontrados con ese nombre. Se mas especifico."
        exit 1
    }
}
catch {
    Write-Error "No se encontro el equipo '$TeamName'."
    exit 1
}

Write-Host "Analizando miembros del equipo (esto puede tardar)..." -ForegroundColor Cyan
$members = Get-TeamUser -GroupId $team.GroupId

# Filtrado segun TargetRole
switch ($TargetRole) {
    'Guest' { $usersToCheck = $members | Where-Object { $_.Role -eq "Guest" } }
    'Member' { 
        $usersToCheck = $members | Where-Object { $_.Role -eq "Member" } 
        Write-Warning "Se excluiran automaticamente los Propietarios (Owners) para proteger el equipo."
    }
    'Both' { 
        $usersToCheck = $members | Where-Object { $_.Role -ne "Owner" }
        Write-Warning "Se excluiran automaticamente los Propietarios (Owners) para proteger el equipo."
    }
}

if (-not $usersToCheck) {
    Write-Host "No hay usuarios del rol '$TargetRole' en este equipo." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------
# 3. Preparar lista de usuarios a eliminar
# ---------------------------------------------------------
$targets = @()

# Aplicar filtro de dominio si se especifico
if ($Domain) {
    # Buscar tanto formato estandar (*@dominio.com) como formato #EXT# (*_dominio.com#EXT#@*)
    $standardPattern = "*@" + $Domain
    $extPattern = "*_" + $Domain + "#EXT#@*"
    
    Write-Host ("Aplicando filtro de dominio: " + $standardPattern + " (y formato #EXT#)") -ForegroundColor Cyan
    $usersToCheck = $usersToCheck | Where-Object { 
        ($_.User -like $standardPattern) -or ($_.User -like $extPattern)
    }
    
    if (-not $usersToCheck) {
        Write-Host "No se encontraron usuarios del dominio '$Domain' con el rol '$TargetRole'." -ForegroundColor Yellow
        Write-Host ("Nota: Se busco en formato estandar (*@" + $Domain + ") y formato externo (*_" + $Domain + "#EXT#@*)") -ForegroundColor Gray
        exit 0
    }
}

$totalUsers = @($usersToCheck).Count
Write-Host "Seleccionando $totalUsers usuarios del rol '$TargetRole'..." -ForegroundColor Cyan

foreach ($u in $usersToCheck) {
    $targets += @{
        User   = $u.User
        UserId = $u.UserId
        Role   = $u.Role
    }
}

# ---------------------------------------------------------
# 4. Confirmacion y Borrado
# ---------------------------------------------------------
$count = $targets.Count

if ($count -eq 0) {
    Write-Host "No se encontraron usuarios ($TargetRole) que coincidan con el criterio." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nSe han encontrado $count usuarios para eliminar." -ForegroundColor Cyan
$targets | ForEach-Object { Write-Host " - $($_.User) [$($_.Role)]" -ForegroundColor Gray }

Write-Warning "`nATENCION: Se procedera a eliminar estos $count usuarios del equipo '$TeamName'."

$deletedLog = @()
foreach ($target in $targets) {
    if ($PSCmdlet.ShouldProcess("Usuario: $($target.User)", "Eliminar del equipo")) {
        try {
            # Usar UserId en lugar de User para evitar problemas con caracteres especiales (#EXT#)
            Remove-TeamUser -GroupId $team.GroupId -User $target.UserId -ErrorAction Stop
            Write-Host " [OK] Eliminado: $($target.User)" -ForegroundColor Green
            $deletedLog += $target.User

            if ($RequestDelayMs -gt 0) {
                Start-Sleep -Milliseconds $RequestDelayMs
            }
        }
        catch {
            Write-Warning " [ERROR] Fallo eliminacion de $($target.User): $_"
        }
    }
}

# ---------------------------------------------------------
# 5. Log Final
# ---------------------------------------------------------
if ($deletedLog.Count -gt 0) {
    $timestamp = (Get-SpainDateTime).ToString("yyyyMMdd-HHmm")
    $sanitizedTeamName = $TeamName -replace '[^a-zA-Z0-9_\-\s]', ''
    $logFile = "DeletedUsers_${TargetRole}_${sanitizedTeamName}_${timestamp}.log"
    $logPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot $logFile } else { Join-Path $PWD $logFile }

    $logContent = [System.Collections.Generic.List[string]]::new()
    $logContent.Add("==========================================")
    $logContent.Add("       USUARIOS ELIMINADOS (LOG)          ")
    $logContent.Add("==========================================")
    $logContent.Add("Equipo: $TeamName")
    $logContent.Add("Rol Objetivo: $TargetRole")
    if ($Domain) { $logContent.Add("Filtro Dominio: *@" + $Domain + " (y #EXT#)") }
    $logContent.Add("Fecha Ejecucion: $((Get-SpainDateTime).ToString('yyyy-MM-dd HH:mm:ss'))")
    $logContent.Add("------------------------------------------")
    foreach ($item in $deletedLog) { $logContent.Add($item) }
    $logContent.Add("------------------------------------------")
    $logContent.Add("Total: $($deletedLog.Count)")

    $logContent | Out-File -FilePath $logPath -Encoding utf8
    Write-Host "`n[INFO] Log guardado en: $logPath" -ForegroundColor Green
}
