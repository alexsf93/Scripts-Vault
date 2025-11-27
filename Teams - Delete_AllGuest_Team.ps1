<#
===========================================================
        Microsoft Teams - Eliminación Masiva de Invitados
-----------------------------------------------------------
Autor: Alejandro Suárez (@alexsf93)
===========================================================

.DESCRIPCIÓN
    Este script se conecta a Microsoft Teams y elimina todos los usuarios con rol de 'Invitado' (Guest) 
    de un equipo específico.
    Requiere el nombre exacto del equipo para evitar errores.

.REQUISITOS
    - PowerShell 7.x o Windows PowerShell 5.1
    - Módulo MicrosoftTeams instalado (el script lo instala si falta)
    - Permisos de propietario o administrador en el equipo

.EJEMPLOS DE USO
    # Eliminar invitados de un equipo concreto:
    .\Teams-Delete_AllGuest_Team.ps1 -TeamName "Nombre del Equipo"

    # Simular la eliminación (WhatIf):
    .\Teams-Delete_AllGuest_Team.ps1 -TeamName "Nombre del Equipo" -WhatIf

.NOTAS
    - El borrado es irreversible, úsalo con precaución.
    - Se recomienda usar -WhatIf primero para verificar.

===========================================================
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$TeamName
)

# Forzar consola a UTF-8
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
    Install-Module MicrosoftTeams -Scope CurrentUser -Force
}

Import-Module MicrosoftTeams 6>$null

# Conectar a Microsoft Teams
if ($env:ACC_CLOUD -or $env:AZURE_HTTP_USER_AGENT -match 'cloud-shell') {
    Write-Host "Entorno Azure Cloud Shell detectado." -ForegroundColor Cyan
    Write-Host "Iniciando autenticación por código de dispositivo..." -ForegroundColor Yellow
    Connect-MicrosoftTeams -UseDeviceAuthentication
}
else {
    try {
        Connect-MicrosoftTeams -ErrorAction Stop
    }
    catch {
        Write-Warning "No se pudo conectar interactivamente. Intentando Device Code..."
        Connect-MicrosoftTeams -UseDeviceAuthentication
    }
}

Write-Host "Buscando equipo '$TeamName' en Microsoft Teams..." -ForegroundColor Cyan

try {
    $team = Get-Team -DisplayName $TeamName -ErrorAction Stop
    
    if ($team.Count -gt 1) {
        Write-Warning "Se han encontrado múltiples equipos con el nombre '$TeamName'. Por favor, sé más específico."
        Disconnect-MicrosoftTeams -Confirm:$false
        exit
    }
    
    if (-not $team) {
        Write-Warning "No se encontró ningún equipo con el nombre '$TeamName'."
        Disconnect-MicrosoftTeams -Confirm:$false
        exit
    }
}
catch {
    Write-Warning "Error al buscar el equipo: $_"
    Disconnect-MicrosoftTeams -Confirm:$false
    exit
}

Write-Host "Equipo encontrado: $($team.DisplayName) ($($team.GroupId))" -ForegroundColor Green
Write-Host "Obteniendo miembros del equipo..." -ForegroundColor Cyan

try {
    $members = Get-TeamUser -GroupId $team.GroupId -ErrorAction Stop
    $guests = $members | Where-Object { $_.Role -eq "Guest" }
}
catch {
    Write-Warning "Error al obtener los miembros: $_"
    Disconnect-MicrosoftTeams -Confirm:$false
    exit
}

if (-not $guests) {
    Write-Host "No se encontraron invitados en el equipo." -ForegroundColor Yellow
}
else {
    $guestCount = @($guests).Count
    Write-Host "Se han encontrado $guestCount invitados." -ForegroundColor Cyan
    
    # Confirmación antes de borrar
    Write-Warning "¡ATENCIÓN! Se van a eliminar $guestCount usuarios del equipo '$TeamName'."
    $confirm = Read-Host "¿Está seguro de que desea continuar? (S/N)"
    
    if ($confirm -notmatch '^[sS]$') {
        Write-Warning "Operación cancelada por el usuario."
        Disconnect-MicrosoftTeams -Confirm:$false
        exit
    }

    Write-Host "Procesando eliminación..." -ForegroundColor Cyan
    $deletedLog = @()

    foreach ($guest in $guests) {
        if ($PSCmdlet.ShouldProcess("Usuario: $($guest.User)", "Eliminar del equipo '$TeamName'")) {
            try {
                Remove-TeamUser -GroupId $team.GroupId -User $guest.User -ErrorAction Stop
                Write-Host " [OK] Eliminado: $($guest.User)" -ForegroundColor Green
                $deletedLog += $guest.User
            }
            catch {
                Write-Warning " [ERROR] No se pudo eliminar $($guest.User): $_"
            }
        }
    }

    # Log final de usuarios eliminados
    if ($deletedLog.Count -gt 0) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmm"
        $sanitizedTeamName = $TeamName -replace '[\\/:*?"<>|]', ''
        $logFile = "DeletedGuests_${sanitizedTeamName}_${timestamp}.log"
        
        # Determine path (script directory or current)
        $logPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot $logFile } else { Join-Path $PWD $logFile }

        $logContent = @(
            "==========================================",
            "       LISTA DE USUARIOS ELIMINADOS       ",
            "==========================================",
            "Equipo: $TeamName",
            "Fecha: $(Get-Date)",
            "------------------------------------------"
        )
        $logContent += $deletedLog
        $logContent += "------------------------------------------"
        $logContent += "Total: $($deletedLog.Count) usuarios eliminados."
        $logContent += "=========================================="

        $logContent | Out-File -FilePath $logPath -Encoding utf8

        Write-Host "`n[INFO] Se ha generado el fichero de log: $logPath" -ForegroundColor Green
        Write-Host "Total eliminados: $($deletedLog.Count)" -ForegroundColor Green
    }
}

Disconnect-MicrosoftTeams -Confirm:$false
Write-Host "Desconectado de Microsoft Teams." -ForegroundColor Green
