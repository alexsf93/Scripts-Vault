<#
.SYNOPSIS
    Pruebas-Seeding - Generador de Usuarios e Invitados de Prueba para Microsoft Teams.

.DESCRIPTION
    Script de pruebas (seeding) que se conecta a Microsoft Teams via modulo MicrosoftTeams / Graph API,
    resuelve un equipo de prueba ('Equipo_Pruebas_Eliminacion'), y agrega miembros e invitados (Guests) de prueba
    con dominios externos para poder simular y auditar el script de eliminacion masiva de usuarios en Teams.

.REQUISITOS Y COMPATIBILIDAD
    - Entorno: Windows PowerShell 5.1 / PowerShell 7+ / Azure cloud shell
    - Modulo: MicrosoftTeams (se instala automaticamente si no esta presente)

.PARAMETER TeamName
    Nombre del equipo de Microsoft Teams a poblar (por defecto: "Equipo_Pruebas_Eliminacion").

.PARAMETER GuestDomain
    Dominio externo de los invitados de prueba (por defecto: "externo.com").

.PARAMETER GuestCount
    Numero de usuarios invitados a agregar (por defecto: 5).

.EXAMPLE
    & '.\Pruebas-Seeding\Pruebas-Seeding - Generador_Usuarios_Teams.ps1' -TeamName "Proyecto X"

.NOTES
    Nombre:   Pruebas-Seeding - Generador_Usuarios_Teams.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.0.0
    Fecha:    2026-08-10
#>

[CmdletBinding()]
param(
    [string]$TeamName = "Equipo_Pruebas_Eliminacion",
    [string]$GuestDomain = "externo.com",
    [int]$GuestCount = 5
)

# Validar e instalar modulo requerido si no esta presente
if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
    Write-Host "  [*] Instalando modulo requerido 'MicrosoftTeams' desde PowerShell gallery..." -ForegroundColor Yellow
    Install-Module MicrosoftTeams -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module MicrosoftTeams -ErrorAction Stop

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

Clear-Host
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "    GENERADOR DE USUARIOS DE PRUEBA EN TEAMS (SEEDING DE INVITADOS)     " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Version: 1.0.0 | MicrosoftTeams | Autor: Alejandro Suarez (@alexsf93)" -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------------------------------
# CONEXION A MICROSOFT TEAMS
# -------------------------------------------------------------------------
Write-StatusMsg "Conectando a Microsoft Teams..." -Status "WORKING"
try {
    if ($env:ACC_CLOUD -or $env:AZURE_HTTP_USER_AGENT -match 'cloud-shell') {
        Connect-MicrosoftTeams -UseDeviceAuthentication
    } else {
        try {
            Connect-MicrosoftTeams -ErrorAction Stop
        } catch {
            Connect-MicrosoftTeams -UseDeviceAuthentication
        }
    }
    Write-StatusMsg "Conexion establecida con Microsoft Teams." -Status "SUCCESS"
} catch {
    Write-StatusMsg "Error al conectar a Microsoft Teams: $_" -Status "FAIL"
    exit 1
}

# -------------------------------------------------------------------------
# LOCALIZAR O CREAR EQUIPO DE PRUEBA
# -------------------------------------------------------------------------
Write-StatusMsg "Buscando equipo '$TeamName'..." -Status "WORKING"
$TargetTeam = Get-Team -DisplayName $TeamName -ErrorAction SilentlyContinue

if (-not $TargetTeam) {
    Write-StatusMsg "Creando nuevo equipo de prueba '$TeamName'..." -Status "WORKING"
    try {
        $TargetTeam = New-Team -DisplayName $TeamName -Visibility Private -ErrorAction Stop
        Write-StatusMsg "Equipo '$TeamName' creado exitosamente." -Status "SUCCESS"
    } catch {
        Write-StatusMsg "No se pudo crear el equipo '$TeamName': $_" -Status "FAIL"
        exit 1
    }
} else {
    if ($TargetTeam.Count -gt 1) {
        $TargetTeam = $TargetTeam[0]
    }
    Write-StatusMsg "Equipo encontrado: '$($TargetTeam.DisplayName)' (GroupID: $($TargetTeam.GroupId))" -Status "SUCCESS"
}

# -------------------------------------------------------------------------
# AGREGAR INVITADOS DE PRUEBA
# -------------------------------------------------------------------------
Write-StatusMsg "Agregando $GuestCount usuarios invitados del dominio '$GuestDomain'..." -Status "WORKING"

$AddedCount = 0
for ($i = 1; $i -le $GuestCount; $i++) {
    $GuestUser = "invitado.demo${i}@${GuestDomain}"
    Write-StatusMsg "Agregando usuario '$GuestUser'..." -Status "WORKING"

    try {
        Add-TeamUser -GroupId $TargetTeam.GroupId -User $GuestUser -Role Guest -ErrorAction Stop
        Write-StatusMsg "  Usuario '$GuestUser' agregado como invitado." -Status "SUCCESS"
        $AddedCount++
    } catch {
        Write-StatusMsg "  No se pudo agregar '$GuestUser': $_" -Status "WARN"
    }
}

Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                 RESUMEN DE SEEDING DE USUARIOS TEAMS                    " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Equipo objetivo                  : {0}" -f $TargetTeam.DisplayName) -ForegroundColor White
Write-Host (" Invitados agregados exitosamente : {0}" -f $AddedCount) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

Write-StatusMsg "Proceso finalizado con exito." -Status "SUCCESS"
Write-StatusMsg "Ahora puede ejecutar 'Microsoft 365 - Teams - Eliminacion_Masiva_Usuarios.ps1' para probar la eliminacion masiva." -Status "INFO"
