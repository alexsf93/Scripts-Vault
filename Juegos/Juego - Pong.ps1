<#
.SYNOPSIS
    Pong Retro en PowerShell.

.DESCRIPTION
    Este script ejecuta el clásico juego Pong directamente en la consola de Windows.
    Permite jugar contra la CPU usando las flechas del teclado.

.PARAMETER NoParameter
    Este script no requiere parámetros.

.EXAMPLE
    .\Juego - Pong.ps1
    Inicia el juego.

.NOTES
    Nombre:   Juego - Pong.ps1
    Autor:    Alejandro Suárez (@alexsf93)
    Versión:  1.0
#>

function Initialize-Game {
    $global:width = 40
    $global:height = 15
    $global:paddleSize = 4
    $global:playerPos = [math]::Floor(($global:height - $global:paddleSize) / 2)
    $global:cpuPos = [math]::Floor(($global:height - $global:paddleSize) / 2)
    $global:ballX = [math]::Floor($global:width / 2)
    $global:ballY = [math]::Floor($global:height / 2)
    $global:ballDirX = -1
    $global:ballDirY = 1
    $global:scorePlayer = 0
    $global:scoreCPU = 0
    $global:gameOver = $false
    $global:delay = 120      # velocidad inicial lenta (ms por frame)
    $global:minDelay = 8     # velocidad máxima (mínimo delay)
    $global:increaseSpeedStep = 8 # cuanto disminuye el delay cada rebote de pala
}

function Show-Screen {
    Clear-Host
    # Borde superior
    Write-Host (" " + ("-" * $global:width) + " ") -ForegroundColor Green

    for ($y = 0; $y -lt $global:height; $y++) {
        $line = "|"
        for ($x = 0; $x -lt $global:width; $x++) {
            if (($x -eq 0 -and $y -ge $global:playerPos -and $y -lt ($global:playerPos + $global:paddleSize)) -or
                ($x -eq ($global:width - 1) -and $y -ge $global:cpuPos -and $y -lt ($global:cpuPos + $global:paddleSize))) {
                $line += "|"
            }
            elseif ($x -eq $global:ballX -and $y -eq $global:ballY) {
                $line += "O"
            }
            else {
                $line += " "
            }
        }
        $line += "|"
        Write-Host $line -ForegroundColor Green
    }
    # Borde inferior
    Write-Host (" " + ("-" * $global:width) + " ") -ForegroundColor Green

    Write-Host ""
    Write-Host "Mover: [Flecha Arriba] / [Flecha Abajo]      Salir: pulsa [q]" -ForegroundColor Green
    Write-Host "Puntuación - Tú: $global:scorePlayer    CPU: $global:scoreCPU" -ForegroundColor White
    Write-Host "Velocidad de la bola: $(([math]::Round(1000/$global:delay))) fotogramas/seg" -ForegroundColor DarkGray
}

function Reset-Ball {
    $global:ballX = [math]::Floor($global:width / 2)
    $global:ballY = Get-Random -Minimum 2 -Maximum ($global:height - 2)
    $global:ballDirX = @(1, -1) | Get-Random
    $global:ballDirY = @(1, -1) | Get-Random
    $global:delay = 120  # reinicia velocidad lenta cada vez que hay gol
}

function Update-Ball {
    $global:ballX += $global:ballDirX
    $global:ballY += $global:ballDirY

    # Rebote superior e inferior (rebota en los bordes visibles)
    if ($global:ballY -lt 0) {
        $global:ballY = 0
        $global:ballDirY = - $global:ballDirY
    }
    elseif ($global:ballY -ge $global:height) {
        $global:ballY = $global:height - 1
        $global:ballDirY = - $global:ballDirY
    }

    # Rebote paleta derecha (CPU)
    if ($global:ballX -eq ($global:width - 2)) {
        if ($global:ballY -ge $global:cpuPos -and $global:ballY -lt ($global:cpuPos + $global:paddleSize)) {
            $global:ballDirX = - $global:ballDirX
            if ($global:delay -gt $global:minDelay) { $global:delay -= $global:increaseSpeedStep }
        }
    }
    # Rebote paleta izquierda (Jugador)
    elseif ($global:ballX -eq 1) {
        if ($global:ballY -ge $global:playerPos -and $global:ballY -lt ($global:playerPos + $global:paddleSize)) {
            $global:ballDirX = - $global:ballDirX
            if ($global:delay -gt $global:minDelay) { $global:delay -= $global:increaseSpeedStep }
        }
    }
}

function Update-CPU {
    $centerCPU = $global:cpuPos + [math]::Floor($global:paddleSize / 2)
    if ($global:ballY -lt $centerCPU -and $global:cpuPos -gt 0) {
        $global:cpuPos--
    }
    elseif ($global:ballY -gt $centerCPU -and $global:cpuPos -lt ($global:height - $global:paddleSize)) {
        $global:cpuPos++
    }
}

function Read-Key-NonBlocking {
    if ([System.Console]::KeyAvailable) {
        $key = [System.Console]::ReadKey($true)
        return $key
    }
    return $null
}

Initialize-Game
Show-Screen

while (-not $global:gameOver) {
    $key = Read-Key-NonBlocking
    if ($key) {
        if ($key.Key -eq 'UpArrow' -and $global:playerPos -gt 0) {
            $global:playerPos--
        }
        elseif ($key.Key -eq 'DownArrow' -and $global:playerPos -lt ($global:height - $global:paddleSize)) {
            $global:playerPos++
        }
        elseif ($key.KeyChar -eq 'q') {
            $global:gameOver = $true
            break
        }
    }

    $lastScorePlayer = $global:scorePlayer
    Update-Ball
    Update-CPU

    $gol = $false
    if ($global:ballX -lt 0) {
        $global:scoreCPU++
        $gol = $true
    }
    elseif ($global:ballX -ge $global:width) {
        $global:scorePlayer++
        $gol = $true
    }

    Show-Screen

    if ($gol) {
        Write-Host ""
        if ($global:scorePlayer -gt $lastScorePlayer) {
            Write-Host "¡Gol para TI! Puntuación: Tú $global:scorePlayer - CPU: $global:scoreCPU" -ForegroundColor Yellow
        }
        else {
            Write-Host "¡Gol para la CPU! Puntuación: Tú $global:scorePlayer - CPU: $global:scoreCPU" -ForegroundColor Yellow
        }
        Write-Host "Pulsa Enter para continuar..." -ForegroundColor Green
        while ($true) {
            $k = [System.Console]::ReadKey($true)
            if ($k.Key -eq "Enter") { break }
            if ($k.KeyChar -eq 'q') { $global:gameOver = $true; break }
        }
        if (-not $global:gameOver) { Reset-Ball }
    }

    Start-Sleep -Milliseconds $global:delay
}

Clear-Host
Write-Host "Juego terminado. Puntuación final: Tú $global:scorePlayer - CPU: $global:scoreCPU" -ForegroundColor Yellow
Write-Host "Pulsa Enter para salir..." -ForegroundColor Green
Read-Host | Out-Null
Write-Host "Gracias por jugar!" -ForegroundColor Green