<#
.SYNOPSIS
    Exchange Online - Informe Detallado de Buzones

.DESCRIPTION
    Este script se conecta a Exchange Online y obtiene informacion detallada de todos los buzones de usuario, excluyendo buzones de sistema.
    Permite buscar un buzon concreto con -User o mostrar todos los buzones.
    Presenta los datos en una tabla interactiva (Out-GridView) en Windows o por consola (Format-Table) en Cloud Shell.

.PARAMETER User
    Nombre del usuario (UPN) para filtrar un buzon especifico. Si se omite, se muestran todos.

.EXAMPLE
    & '.\Microsoft 365 - Exchange - Recopilacion_Buzones.ps1'

.EXAMPLE
    & '.\Microsoft 365 - Exchange - Recopilacion_Buzones.ps1' -User usuario@dominio.com

.NOTES
    Nombre:      Microsoft 365 - Exchange - Recopilacion_Buzones.ps1
    Autor:       Alejandro Suarez (@alexsf93)
    Version:     1.1.0
    Requisitos:  PowerShell 5.1 / 7.x ejecutado localmente en Windows (Recomendado por Out-GridView y la pila de conexion de Exchange).
#>

param(
    [Parameter(Position=0, Mandatory=$false)]
    [string]$User
)

# Forzar consola a UTF-8
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "Instalando modulo requerido 'ExchangeOnlineManagement' desde PowerShell Gallery..." -ForegroundColor Yellow
    Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}

Import-Module ExchangeOnlineManagement -ErrorAction Stop

Write-Host "Conectando a Exchange Online..." -ForegroundColor Cyan
try {
    if ($env:ACC_CLOUD -or $env:AZURE_HTTP_USER_AGENT -match 'cloud-shell') {
        Connect-ExchangeOnline -Device -ErrorAction Stop
    } else {
        if ($User) {
            Connect-ExchangeOnline -UserPrincipalName $User -ErrorAction SilentlyContinue
        } else {
            Connect-ExchangeOnline -ErrorAction Stop
        }
    }
} catch {
    Connect-ExchangeOnline
}

Write-Host "Obteniendo buzones de Exchange (excluyendo buzones de sistema)..." -ForegroundColor Cyan

if ($null -ne $User -and $User.Trim() -ne "") {
    $mailboxes = Get-Mailbox -Identity $User -ErrorAction SilentlyContinue | Where-Object {
        $_.UserPrincipalName -notmatch '(?i)^(DiscoverySearchMailbox|SystemMailbox|FederatedEmail|HealthMailbox|Migration|O365Services|SPO_Admin|SpfAutoDiscover|sipfed|exclaimer|sharepoint|admin|system|microsoft)'
    }
    if (-not $mailboxes) {
        Write-Warning "No se encontro ningun buzon para el usuario '$User'."
        Disconnect-ExchangeOnline -Confirm:$false
        exit 0
    }
} else {
    $mailboxes = Get-Mailbox -ResultSize Unlimited | Where-Object {
        $_.UserPrincipalName -notmatch '(?i)^(DiscoverySearchMailbox|SystemMailbox|FederatedEmail|HealthMailbox|Migration|O365Services|SPO_Admin|SpfAutoDiscover|sipfed|exclaimer|sharepoint|admin|system|microsoft)'
    }
}

function Convert-ToMB {
    param([string]$sizeStr)
    if ([string]::IsNullOrWhiteSpace($sizeStr)) { return $null }
    if ($sizeStr -match '([\d\.]+)\s*(Bytes|KB|MB|GB|TB)') {
        $num = [double]$matches[1]
        $unit = $matches[2].ToUpper()
        switch ($unit) {
            'BYTES' { return [math]::Round($num / 1MB, 4) }
            'KB'    { return [math]::Round($num / 1KB, 4) }
            'MB'    { return $num }
            'GB'    { return [math]::Round($num * 1024, 2) }
            'TB'    { return [math]::Round($num * 1024 * 1024, 2) }
        }
    }
    return $null
}

$resultados = @()
foreach ($mb in $mailboxes) {
    try {
        $stats = Get-MailboxStatistics -Identity $mb.UserPrincipalName -ErrorAction SilentlyContinue
        $aliases = $mb.EmailAddresses | Where-Object { $_ -like "smtp:*" } | ForEach-Object { $_ -replace "^smtp:", "" }

        $consumidoStr = if ($stats.TotalItemSize) { $stats.TotalItemSize.Value.ToString() } else { "N/A" }
        $limiteStr    = if ($mb.ProhibitSendQuota) { $mb.ProhibitSendQuota.Value.ToString() } else { "N/A" }

        $consumidoMB = Convert-ToMB $consumidoStr
        $limiteMB = Convert-ToMB $limiteStr
        if (($null -ne $consumidoMB) -and ($null -ne $limiteMB) -and ($limiteMB -gt 0)) {
            $porcentaje = [math]::Round(($consumidoMB / $limiteMB) * 100, 2)
            $porcentajeTxt = "$porcentaje`%"
        } else {
            $porcentajeTxt = "No disponible"
        }

        $resultados += [PSCustomObject]@{
            Nombre                = $mb.DisplayName
            Usuario               = $mb.UserPrincipalName
            TipoBuzon             = $mb.RecipientTypeDetails
            Alias                 = if ($aliases) { $aliases -join ", " } else { "No" }
            Consumido             = $consumidoStr
            Total                 = $limiteStr
            PorcentajeUso         = $porcentajeTxt
            ElementosAlmacenados  = $stats.ItemCount
            ElementosEliminados   = $stats.DeletedItemCount
            LitigationHold        = if ($mb.LitigationHoldEnabled) { "Si" } else { "No" }
            LastSignIn            = $stats.LastLogonTime
            Archivado             = if ($mb.ArchiveStatus -eq 'Active') { 'Habilitado' } else { 'No habilitado' }
            PoliticaRetencion     = if ($mb.RetentionPolicy) { $mb.RetentionPolicy } else { 'No asignada' }
        }
    } catch {
        Write-Warning "No se pudo obtener estadisticas para $($mb.UserPrincipalName)"
    }
}

# Mostrar resultados con fallback para Cloud Shell / Linux PS7 (donde Out-GridView no esta disponible)
if ($resultados.Count -gt 0) {
    $isCloudShell = $env:ACC_CLOUD -or $env:AZURE_HTTP_USER_AGENT -match 'cloud-shell'
    if (-not $isCloudShell -and (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
        try {
            $resultados | Out-GridView -Title "Resumen de buzones Exchange Online"
        } catch {
            Write-Host "`nResumen de buzones Exchange Online:" -ForegroundColor Yellow
            $resultados | Format-Table -AutoSize
        }
    } else {
        Write-Host "`nResumen de buzones Exchange Online:" -ForegroundColor Yellow
        $resultados | Format-Table -AutoSize
    }
} else {
    Write-Host "No hay datos para mostrar." -ForegroundColor Yellow
}

Disconnect-ExchangeOnline -Confirm:$false
Write-Host "Desconectado de Exchange Online." -ForegroundColor Green
