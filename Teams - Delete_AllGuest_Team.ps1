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

# Conectar a Microsoft Teams (interactivo si no hay token)
Connect-MicrosoftTeams 6>$null

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
    Write-Host "Se han encontrado $guestCount invitados. Procesando eliminación..." -ForegroundColor Cyan

    foreach ($guest in $guests) {
        if ($PSCmdlet.ShouldProcess("Usuario: $($guest.User)", "Eliminar del equipo '$TeamName'")) {
            try {
                Remove-TeamUser -GroupId $team.GroupId -User $guest.User -ErrorAction Stop
                Write-Host " [OK] Eliminado: $($guest.User)" -ForegroundColor Green
            }
            catch {
                Write-Warning " [ERROR] No se pudo eliminar $($guest.User): $_"
            }
        }
    }
}

Disconnect-MicrosoftTeams -Confirm:$false
Write-Host "Desconectado de Microsoft Teams." -ForegroundColor Green
