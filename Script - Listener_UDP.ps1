<#
.SYNOPSIS
    Script de prueba: Envio de mensaje UDP al puerto 8866 en localhost.

.DESCRIPTION
    Este script inicia un listener UDP en el puerto especificado (por defecto 8866) para validar la
    comunicacion mediante el protocolo UDP. Es util para pruebas de conectividad.

.PARAMETER Port
    El puerto UDP donde escuchar. Por defecto es 8866.

.EXAMPLE
    & '.\Script - Listener_UDP.ps1'
    Inicia la escucha en el puerto 8866.

.EXAMPLE
    & '.\Script - Listener_UDP.ps1' -Port 9000
    Inicia la escucha en el puerto 9000.

.NOTES
    Nombre:   Script - Listener_UDP.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.0
#>

param(
    [int]$Port = 8866
)
$script:udp = $null
$script:keepRunning = $true

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
$script:endPoint = $null
$eventRegistration = $null

try {
    Write-Host "Iniciando listener UDP en puerto $Port..."
    $script:udp = New-Object System.Net.Sockets.UdpClient($Port)
    $script:endPoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

    $eventRegistration = Register-EngineEvent -SourceIdentifier ConsoleCancelEvent -Action {
        Write-Host "`n[Evento] Ctrl+C detectado. Cerrando listener..."
        $script:keepRunning = $false
        try {
            if ($null -ne $script:udp) {
                $script:udp.Close()
            }
        }
        catch {
        }
    }

    Write-Host "Escuchando... pulsa Ctrl+C para detener y cerrar el puerto."
    while ($script:keepRunning) {
        try {
            $bytes = $script:udp.Receive([ref]$script:endPoint)
            if ($null -ne $bytes -and $bytes.Length -gt 0) {
                $msg = [System.Text.Encoding]::UTF8.GetString($bytes)
                $now = (Get-SpainDateTime).ToString("yyyy-MM-dd HH:mm:ss")
                Write-Host ("{0} <- {1}:{2}  |  {3}" -f $now, $script:endPoint.Address, $script:endPoint.Port, $msg)
            }
        }
        catch [System.ObjectDisposedException] {
            break
        }
        catch [System.Net.Sockets.SocketException] {
            Write-Host "[SocketException] $_"
            break
        }
        catch {
            Write-Host "[Error] $_"
            break
        }
    }

}
finally {
    try {
        if ($null -ne $script:udp) {
            $script:udp.Close()
            $script:udp = $null
        }
    }
    catch { }

    if ($null -ne $eventRegistration) {
        try { Unregister-Event -SourceIdentifier ConsoleCancelEvent -ErrorAction SilentlyContinue } catch {}
        try { Remove-Event -SourceIdentifier ConsoleCancelEvent -ErrorAction SilentlyContinue } catch {}
    }

    Write-Host "Listener detenido y socket cerrado."
}
