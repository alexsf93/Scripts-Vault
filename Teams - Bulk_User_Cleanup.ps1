<#
===========================================================
        Microsoft Teams - Eliminación Masiva por Fecha
-----------------------------------------------------------
Autor: Alejandro Suárez (@alexsf93)
===========================================================

.DESCRIPCIÓN
    Este script elimina usuarios (Invitados o Miembros) de un equipo.
    Puede funcionar en dos modos:
    1. FILTRO POR FECHA: Elimina usuarios creados en un rango específico.
    2. MODO ALL: Elimina TODOS los usuarios del rol seleccionado (sin importar fecha).
    
    CARACTERÍSTICAS:
    - Selección de rol objetivo: 'Guest', 'Member' o 'Both'.
    - PROTECCIÓN: Excluye automáticamente a los Propietarios (Owners).
    - Genera un log detallado con los usuarios eliminados.
    - Soporte para Azure Cloud Shell y autenticación por Device Code.

.REQUISITOS
    - Módulo MicrosoftTeams
    - Módulo Microsoft.Graph.Users (solo si se usa filtro por fecha)
    - Permisos de administrador/propietario.

.EJEMPLOS DE USO
    # 1. Eliminar INVITADOS creados en una fecha específica:
    .\Teams-Delete_Guest_By_Date.ps1 -TeamName "Proyecto X" -StartDate "2024-01-01"

    # 2. Eliminar TODOS los INVITADOS (sin importar fecha):
    .\Teams-Delete_Guest_By_Date.ps1 -TeamName "Proyecto X" -All

    # 3. Eliminar TODOS los MIEMBROS (excepto owners):
    .\Teams-Delete_Guest_By_Date.ps1 -TeamName "Proyecto X" -TargetRole Member -All
===========================================================
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'ByDate')]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$TeamName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByDate')]
    [DateTime]$StartDate,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByDate')]
    [DateTime]$EndDate,

    [Parameter(Mandatory = $true, ParameterSetName = 'AllUsers')]
    [switch]$All,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Guest', 'Member', 'Both')]
    [string]$TargetRole = 'Guest'
)

# Configuración de fechas (Solo si estamos en modo fecha)
if ($PSCmdlet.ParameterSetName -eq 'ByDate') {
    if (-not $PSBoundParameters.ContainsKey('EndDate')) {
        $EndDate = $StartDate.Date.AddDays(1).AddTicks(-1)
    }
    else {
        $EndDate = $EndDate.Date.AddDays(1).AddTicks(-1)
    }
    $StartDate = $StartDate.Date
    Write-Host "Modo: Filtrado por Fecha ($StartDate - $EndDate)" -ForegroundColor Gray
}
else {
    Write-Host "Modo: TODOS los usuarios (Sin filtro de fecha)" -ForegroundColor Magenta
}

Write-Host "Rol objetivo: $TargetRole" -ForegroundColor Gray

# Forzar UTF-8
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

# ---------------------------------------------------------
# 1. Conexión a Microsoft Teams
# ---------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
    Install-Module MicrosoftTeams -Scope CurrentUser -Force
}
Import-Module MicrosoftTeams 6>$null

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
# 2. Conexión a Microsoft Graph (Solo si es necesario para fechas)
# ---------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'ByDate') {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
        Write-Warning "El módulo 'Microsoft.Graph.Users' es necesario para verificar fechas. Instalando..."
        Install-Module Microsoft.Graph.Users -Scope CurrentUser -Force
    }
    Import-Module Microsoft.Graph.Users 6>$null

    Write-Host "Conectando a Microsoft Graph..." -ForegroundColor Cyan
    try {
        Connect-MgGraph -Scopes "User.Read.All" -NoWelcome
    }
    catch {
        Write-Warning "Error conectando a Graph. Intentando DeviceCode..."
        Connect-MgGraph -Scopes "User.Read.All" -UseDeviceAuthentication -NoWelcome
    }
}

# ---------------------------------------------------------
# 3. Obtener Equipo y Miembros
# ---------------------------------------------------------
Write-Host "Buscando equipo '$TeamName'..." -ForegroundColor Cyan
try {
    $team = Get-Team -DisplayName $TeamName -ErrorAction Stop
    if ($team.Count -gt 1) {
        Write-Error "Múltiples equipos encontrados con ese nombre. Sé más específico."; exit
    }
}
catch {
    Write-Error "No se encontró el equipo '$TeamName'."; exit
}

Write-Host "Analizando miembros del equipo (esto puede tardar)..." -ForegroundColor Cyan
$members = Get-TeamUser -GroupId $team.GroupId

# Filtrado según TargetRole
switch ($TargetRole) {
    'Guest' { $usersToCheck = $members | Where-Object { $_.Role -eq "Guest" } }
    'Member' { 
        $usersToCheck = $members | Where-Object { $_.Role -eq "Member" } 
        Write-Warning "Se excluirán automáticamente los Propietarios (Owners) para proteger el equipo."
    }
    'Both' { 
        $usersToCheck = $members | Where-Object { $_.Role -ne "Owner" }
        Write-Warning "Se excluirán automáticamente los Propietarios (Owners) para proteger el equipo."
    }
}

if (-not $usersToCheck) {
    Write-Host "No hay usuarios del rol '$TargetRole' en este equipo." -ForegroundColor Yellow
    exit
}

# ---------------------------------------------------------
# 4. Filtrar (Por Fecha o Todos)
# ---------------------------------------------------------
$targets = @()
$totalUsers = @($usersToCheck).Count

if ($All) {
    # Modo ALL: Agregamos todos directamente
    Write-Host "Seleccionando TODOS los $totalUsers usuarios encontrados..." -ForegroundColor Magenta
    foreach ($u in $usersToCheck) {
        $targets += @{
            User    = $u.User
            Role    = $u.Role
            Created = "N/A (Modo All)"
        }
    }
}
else {
    # Modo FECHA: Verificamos en Graph
    $current = 0
    foreach ($u in $usersToCheck) {
        $current++
        Write-Progress -Activity "Verificando fechas de usuarios" -Status "$current / $totalUsers" -PercentComplete (($current / $totalUsers) * 100)
        
        try {
            $userGraph = Get-MgUser -UserId $u.User -Property CreatedDateTime -ErrorAction Stop
            
            if ($userGraph.CreatedDateTime -ge $StartDate -and $userGraph.CreatedDateTime -le $EndDate) {
                $targets += @{
                    User    = $u.User
                    Role    = $u.Role
                    Created = $userGraph.CreatedDateTime
                }
            }
        }
        catch {
            Write-Warning "No se pudo obtener info para $($u.User)"
        }
    }
    Write-Progress -Activity "Verificando fechas de usuarios" -Completed
}

# ---------------------------------------------------------
# 5. Confirmación y Borrado
# ---------------------------------------------------------
$count = $targets.Count

if ($count -eq 0) {
    Write-Host "No se encontraron usuarios ($TargetRole) que coincidan con el criterio." -ForegroundColor Yellow
    exit
}

Write-Host "`nSe han encontrado $count usuarios para eliminar." -ForegroundColor Cyan
$targets | ForEach-Object { Write-Host " - $($_.User) [$($_.Role)] (Creado: $($_.Created))" -ForegroundColor Gray }

Write-Warning "`n¡ATENCIÓN! Se eliminarán estos $count usuarios del equipo '$TeamName'."
$confirm = Read-Host "¿Está seguro de que desea continuar? (S/N)"

if ($confirm -notmatch '^[sS]$') {
    Write-Warning "Cancelado."
    exit
}

$deletedLog = @()
foreach ($target in $targets) {
    if ($PSCmdlet.ShouldProcess("Usuario: $($target.User)", "Eliminar del equipo")) {
        try {
            Remove-TeamUser -GroupId $team.GroupId -User $target.User -ErrorAction Stop
            Write-Host " [OK] Eliminado: $($target.User)" -ForegroundColor Green
            $deletedLog += $target.User
        }
        catch {
            Write-Warning " [ERROR] Falló eliminación de $($target.User): $_"
        }
    }
}

# ---------------------------------------------------------
# 6. Log Final
# ---------------------------------------------------------
if ($deletedLog.Count -gt 0) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmm"
    $sanitizedTeamName = $TeamName -replace '[\\/:*?"<>|]', ''
    $logFile = "DeletedUsers_${TargetRole}_${sanitizedTeamName}_${timestamp}.log"
    $logPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot $logFile } else { Join-Path $PWD $logFile }

    $logContent = @(
        "==========================================",
        "       USUARIOS ELIMINADOS (LOG)          ",
        "==========================================",
        "Equipo: $TeamName",
        "Rol Objetivo: $TargetRole",
        "Modo: $(if($All){'TODO (Sin filtro fecha)'}else{"Fecha: $StartDate a $EndDate"})",
        "Fecha Ejecución: $(Get-Date)",
        "------------------------------------------"
    )
    $logContent += $deletedLog
    $logContent += "------------------------------------------"
    $logContent += "Total: $($deletedLog.Count)"
    
    $logContent | Out-File -FilePath $logPath -Encoding utf8
    Write-Host "`n[INFO] Log guardado en: $logPath" -ForegroundColor Green
}
