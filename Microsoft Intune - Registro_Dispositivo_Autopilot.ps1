<#
.SYNOPSIS
    Registro de dispositivo en Autopilot y apagado condicional.

.DESCRIPTION
    Este script ejecuta el modulo `Get-WindowsAutopilotInfo` para registrar el dispositivo
    en Microsoft Autopilot con los parametros proporcionados (TenantID, AppId, AppSecret).
    Si la ejecucion es correcta, el equipo se apaga automaticamente; en caso de error, se muestra un
    mensaje en rojo y no se apaga.

    Funcionalidad:
    1. Establece TLS 1.2.
    2. Ajusta ExecutionPolicy en el ambito del proceso.
    3. Guarda modelo y numero de serie en `Informacion_dispositivos.txt`.
    4. Ejecuta `Get-WindowsAutopilotInfo.ps1` con parametros.
    5. Apaga si la ejecucion es exitosa.

.PARAMETER TenantID
    (Hardcoded en el script) ID del Tenant de Azure.

.PARAMETER AppId
    (Hardcoded en el script) ID de la Aplicacion.

.PARAMETER AppSecret
    (Hardcoded en el script) Secreto de la Aplicacion.

.EXAMPLE
    & '.\Microsoft Intune - Registro_Dispositivo_Autopilot.ps1'
    Ejecuta el proceso de registro y apagado.

.NOTES
    Nombre:   Microsoft Intune - Registro_Dispositivo_Autopilot.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.0
    Requisitos: PowerShell 5.1+, Privilegios de Administrador.
#>

$TenantID = "TENANT-ID"
$AppId = "APP-ID"
$AppSecret = "APP-SECRET"
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

$LogFile = "$env:ProgramData\AutopilotRegister\AutopilotRun_$((Get-SpainDateTime).ToString('yyyyMMdd_HHmmss')).log"

# Validar sistema operativo (Requiere Windows para WMI/CIM y Autopilot)
if ($IsLinux -or $IsMacOS) {
    Write-Host "ERROR: Este script requiere un entorno Windows (Windows PowerShell / PowerShell 7 en Windows) para acceder a WMI/CIM y registrar el dispositivo en Autopilot." -ForegroundColor Red
    exit 1
}

New-Item -Path (Split-Path $LogFile) -ItemType Directory -Force | Out-Null

function Log { param([string]$m); "$((Get-SpainDateTime).ToString('yyyy-MM-dd HH:mm:ss'))`t$m" | Out-File -FilePath $LogFile -Append -Encoding UTF8 }
function Write-ErrorRed { param([string]$m); Write-Host $m -ForegroundColor Red; Log "ERROR: $m" }
function Write-Info { param([string]$m); Write-Host $m -ForegroundColor Cyan; Log "INFO : $m" }

Write-Info "Inicio del proceso de registro Autopilot."
Log "Parámetros: TenantID=$TenantID, AppId=$AppId, Script=$ScriptName"

try {
    # Guardar modelo y numero de serie si no existe
    $deviceFile = Join-Path (Get-Location) "Informacion_dispositivos.txt"
    $sysInfo = Get-CimInstance -ClassName Win32_ComputerSystem
    $biosInfo = Get-CimInstance -ClassName Win32_BIOS
    $model = $sysInfo.Model
    $serial = $biosInfo.SerialNumber

    $exists = $false
    if (Test-Path $deviceFile) {
        $exists = Select-String -Path $deviceFile -Pattern ([regex]::Escape($serial)) -Quiet
    }

    if (-not $exists) {
        "-----------------" | Out-File -FilePath $deviceFile -Append -Encoding UTF8
        $model            | Out-File -FilePath $deviceFile -Append -Encoding UTF8
        $serial           | Out-File -FilePath $deviceFile -Append -Encoding UTF8
        "-----------------" | Out-File -FilePath $deviceFile -Append -Encoding UTF8
        Write-Info "Información de dispositivo guardada en $deviceFile"
        Log "Guardado modelo=$model, serial=$serial en $deviceFile"
    }
    else {
        Write-Info "El número de serie $serial ya existe en $deviceFile. No se añadirá."
        Log "Serial $serial ya presente en $deviceFile"
    }

    # TLS y ExecutionPolicy
    Write-Info "Estableciendo TLS 1.2..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Info "ExecutionPolicy (Process=RemoteSigned)..."
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force

    # Verificar disponibilidad de Get-WindowsAutopilotInfo y auto-instalar si no existe
    if (-not (Get-Command "Get-WindowsAutopilotInfo" -ErrorAction SilentlyContinue) -and -not (Test-Path $ScriptName)) {
        Write-Info "Instalando script 'Get-WindowsAutopilotInfo' desde PowerShell Gallery..."
        Install-Script -Name Get-WindowsAutopilotInfo -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        $ScriptName = "Get-WindowsAutopilotInfo"
    }

    # Ejecutar script Autopilot
    Write-Info "Ejecutando $ScriptName con parámetros..."
    $t0 = Get-Date
    $output = & $ScriptName -Online -TenantID $TenantID -appid $AppId -appsecret $AppSecret *>&1

    if ($null -ne $output) {
        $output | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }

    $exitOk = $true
    if ($output -match "(?i)\b(error|exception|fail(ed)?)\b") {
        $exitOk = $false
        Log "Texto de error detectado en la salida del script."
    }

    $dur = (Get-Date) - $t0
    Write-Info ("Ejecución completada en {0:N1} segundos." -f $dur.TotalSeconds)

    if ($exitOk) {
        Write-Host "Autopilot ejecutado correctamente. Apagando en 5 segundos..." -ForegroundColor Green
        Log "Resultado OK: apagando equipo"
        Start-Sleep -Seconds 5
        shutdown.exe /s /f /t 0
    }
    else {
        Write-ErrorRed "Se detectaron errores durante la ejecución. No se apagará el equipo."
        Write-ErrorRed "Revisa el log: $LogFile"
        throw "ExecutionHeuristicDetectedError"
    }
}
catch {
    $err = $_.Exception.Message
    Write-ErrorRed "ERROR FATAL: $err"
    Write-ErrorRed "Detalles: $($_ | Out-String)"
    Log "EXCEPTION: $($_ | Out-String)"
    Write-ErrorRed "No se apagará el equipo. Log: $LogFile"
}
finally {
    Write-Info "Fin del script. Log en: $LogFile"
}
