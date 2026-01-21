<#
.SYNOPSIS
    Script de prueba: Envío de mensaje UDP al puerto 8866 en localhost.

.DESCRIPTION
    Este script envía un mensaje UDP al puerto 8866 del servidor local (`localhost`) para validar la
    comunicación mediante el protocolo UDP.

.PARAMETER NoParameter
    Este script no acepta parámetros por línea de comandos actualmente.

.EXAMPLE
    .\Script - Sender_UDP.ps1
    Envía un mensaje de prueba al puerto 8866 en localhost.

.NOTES
    Nombre:   Script - Sender_UDP.ps1
    Autor:    Alejandro Suárez (@alexsf93)
    Versión:  1.0
#>

$server = "localhost"
$port = 8866
$udpclient = New-Object System.Net.Sockets.UdpClient
$msg = "PRUEBA_UDP_8866 desde CLIENTE " + (hostname)
$bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
$udpclient.Send($bytes, $bytes.Length, $server, $port) | Out-Null
$udpclient.Close()
Write-Host "Mensaje enviado"
