<#
.SYNOPSIS
    Pruebas-Seeding - Generador de Correos de Prueba para Exchange Online (Seeding / Ruido).

.DESCRIPTION
    Script de pruebas que se conecta a Microsoft Graph API y genera correos simulados
    en un buzon de Exchange Online hacia un destinatario especifico.
    Crea mensajes con fechas simuladas en el pasado (algunos con mas de 6-8 meses de antiguedad y otros recientes),
    importancias variables y adjuntos reales (PDF, XLSX, ZIP, DOCX) para probar auditorias de espacio y limpieza.

.REQUISITOS Y COMPATIBILIDAD
    - Entorno: Windows PowerShell 5.1 / PowerShell 7+ / Azure Cloud Shell (Bash / PowerShell)
    - Modulo: Microsoft.Graph.Authentication (se instala automaticamente si no esta presente)
    - Permisos: Mail.ReadWrite, Mail.Send en Microsoft Graph API

.PARAMETER Mailbox
    Direccion de correo del buzon objetivo (UPN o Email, ej: "cliente@dominio.com").

.PARAMETER RecipientEmail
    Direccion de correo del destinatario objetivo para los mensajes de prueba (ej: "destinatario@empresa.com").

.PARAMETER OldMessagesCount
    Cantidad de correos antiguos (>6 meses) a generar (por defecto: 10).

.PARAMETER RecentMessagesCount
    Cantidad de correos recientes (<3 meses) a generar (por defecto: 5).

.PARAMETER Folder
    Carpeta del buzon donde colocar los correos de prueba ('SentItems' por defecto, o 'Inbox', 'JunkEmail', etc.).

.PARAMETER TenantId
    ID o dominio del tenant de Microsoft 365 (para autenticacion desatendida).

.PARAMETER ClientId
    ID de la aplicacion (App ID) de Entra ID.

.PARAMETER ClientSecret
    Secreto de aplicacion (Client Secret).

.EXAMPLE
    & '.\Pruebas-Seeding\Pruebas-Seeding - Generador_Datos_Exchange.ps1' -Mailbox "cliente@contoso.com" -RecipientEmail "destino@empresa.com"

.EXAMPLE
    & '.\Pruebas-Seeding\Pruebas-Seeding - Generador_Datos_Exchange.ps1' -Mailbox "cliente@contoso.com" -RecipientEmail "destino@empresa.com" -OldMessagesCount 15

.NOTES
    Nombre:   Pruebas-Seeding - Generador_Datos_Exchange.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.0.0
    Fecha:    2026-08-07
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Mailbox = "",

    [Parameter(Mandatory = $false)]
    [string]$RecipientEmail = "",

    [int]$OldMessagesCount = 10,
    [int]$RecentMessagesCount = 5,
    [string]$Folder = "SentItems",
    [string]$TenantId = "",
    [string]$ClientId = "",
    [string]$ClientSecret = ""
)

# Validar e instalar modulo requerido si no esta presente
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "  [*] Instalando modulo requerido 'Microsoft.Graph.Authentication' desde PowerShell Gallery..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

function Write-StatusMsg {
    param([string]$Message, [string]$Status = "INFO")
    switch ($Status) {
        "SUCCESS" { Write-Host "  [+] $Message" -ForegroundColor Green }
        "WORKING" { Write-Host "  [*] $Message" -ForegroundColor Yellow }
        "INFO"    { Write-Host "  [i]" $Message -ForegroundColor Cyan }
        "WARN"    { Write-Host "  [!]" $Message -ForegroundColor DarkYellow }
        "FAIL"    { Write-Host "  [x]" $Message -ForegroundColor Red }
        default   { Write-Host "  [-]" $Message -ForegroundColor Gray }
    }
}

function Invoke-MgGraphWithRetry {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Body = $null,
        [int]$MaxRetries = 5
    )
    $Attempt = 0
    while ($true) {
        $Attempt++
        try {
            $Params = @{
                Method      = $Method
                Uri         = $Uri
                ErrorAction = "Stop"
            }
            if ($Body) {
                $Params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
                $Params.ContentType = "application/json"
            }
            return Invoke-MgGraphRequest @Params
        } catch {
            $Ex = $_.Exception
            $StatusCode = 0
            if ($Ex.Response -and $Ex.Response.StatusCode) {
                $StatusCode = [int]$Ex.Response.StatusCode
            }
            if (($StatusCode -eq 429 -or $StatusCode -eq 503 -or $StatusCode -eq 504) -and $Attempt -le $MaxRetries) {
                $WaitTimeSec = 5 * $Attempt
                Write-StatusMsg "Limitacion Graph API (HTTP $StatusCode). Esperando $WaitTimeSec s (Intento $Attempt/$MaxRetries)..." -Status "WARN"
                Start-Sleep -Seconds $WaitTimeSec
            } else {
                throw $_
            }
        }
    }
}

Clear-Host
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "    GENERADOR DE CORREOS DE PRUEBA EN EXCHANGE ONLINE (SEEDING RUIDO)    " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Version: 1.0.0 | Graph API | Autor: Alejandro Suarez (@alexsf93)" -ForegroundColor DarkGray
Write-Host ""

# -------------------------------------------------------------------------
# AUTENTICACIÓN GRAPH API
# -------------------------------------------------------------------------
$Scopes = @("Mail.ReadWrite", "Mail.Send", "User.Read.All")

try {
    if ($TenantId -and $ClientId -and $ClientSecret) {
        Write-StatusMsg "Conectando mediante App Registration (Client Secret)..." -Status "WORKING"
        $Body = @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "https://graph.microsoft.com/.default"
        }
        $TokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $Body
        Connect-MgGraph -AccessToken ($TokenResponse.access_token | ConvertTo-SecureString -AsPlainText -Force) -ErrorAction Stop
        Write-StatusMsg "Conexion establecida mediante App Registration." -Status "SUCCESS"
    } else {
        $CurrentContext = Get-MgContext -ErrorAction SilentlyContinue
        if ($CurrentContext) {
            Write-StatusMsg "Sesion de Microsoft Graph detectada ($($CurrentContext.Account))." -Status "SUCCESS"
        } else {
            Write-StatusMsg "Iniciando sesion con Microsoft Graph..." -Status "WORKING"
            if ($env:ACC_CLOUD -or $env:AZURE_HTTP_USER_AGENT -match 'cloud-shell') {
                Connect-MgGraph -Scopes $Scopes -UseDeviceAuthentication -ErrorAction Stop
            } else {
                try {
                    Connect-MgGraph -Scopes $Scopes -ErrorAction Stop
                } catch {
                    Connect-MgGraph -Scopes $Scopes -UseDeviceAuthentication -ErrorAction Stop
                }
            }
            Write-StatusMsg "Autenticacion completada." -Status "SUCCESS"
        }
    }
} catch {
    Write-StatusMsg "Error fatal al conectar a Microsoft Graph: $_" -Status "FAIL"
    exit 1
}

# -------------------------------------------------------------------------
# VALIDACIÓN DE PARÁMETROS OBJETIVO
# -------------------------------------------------------------------------
# VALIDACIÓN Y PREGUNTAS INTERACTIVAS DE PARÁMETROS OBJETIVO
# -------------------------------------------------------------------------
if (-not $Mailbox) {
    $Mailbox = Read-Host "`nIngrese el BUZON donde se crearan los correos de prueba (ej. cliente@empresa.com)"
}
if ([string]::IsNullOrWhiteSpace($Mailbox)) {
    Write-StatusMsg "Debe indicar un buzon de correo valido." -Status "FAIL"
    exit 1
}

if (-not $RecipientEmail) {
    $RecipientEmail = Read-Host "`nIngrese el correo del DESTINATARIO objetivo (ej. destinatario@empresa.com)"
}
if ([string]::IsNullOrWhiteSpace($RecipientEmail)) {
    Write-StatusMsg "Debe indicar un correo de destinatario valido." -Status "FAIL"
    exit 1
}

# Preguntar la cantidad de correos a generar si no fueron especificados por parametro CLI
if (-not $PSBoundParameters.ContainsKey('OldMessagesCount')) {
    $InputOld = Read-Host "`n¿Cuantos correos ANTIGUOS (>6 meses) deseas generar? [Por defecto: 10]"
    if ($InputOld -match '^\d+$' -and [int]$InputOld -ge 0) {
        $OldMessagesCount = [int]$InputOld
    }
}

if (-not $PSBoundParameters.ContainsKey('RecentMessagesCount')) {
    $InputRecent = Read-Host "`n¿Cuantos correos RECIENTES (<3 meses) deseas generar? [Por defecto: 5]"
    if ($InputRecent -match '^\d+$' -and [int]$InputRecent -ge 0) {
        $RecentMessagesCount = [int]$InputRecent
    }
}

if (-not $PSBoundParameters.ContainsKey('Folder')) {
    Write-Host "`nSeleccione la carpeta donde colocar los correos de prueba:" -ForegroundColor Yellow
    Write-Host " [ 1 ] Elementos Enviados (SentItems) [Predeterminado]" -ForegroundColor White
    Write-Host " [ 2 ] Bandeja de Entrada (Inbox)" -ForegroundColor White
    Write-Host " [ 3 ] Correo No Deseado / Spam (JunkEmail)" -ForegroundColor White
    Write-Host " [ 4 ] Elementos Eliminados (DeletedItems)" -ForegroundColor White
    Write-Host " [ 5 ] Borradores (Drafts)" -ForegroundColor White
    
    $FolderSel = Read-Host "Seleccione una opcion (1-5, por defecto 1)"
    switch ($FolderSel) {
        "2" { $Folder = "Inbox" }
        "3" { $Folder = "JunkEmail" }
        "4" { $Folder = "DeletedItems" }
        "5" { $Folder = "Drafts" }
        default { $Folder = "SentItems" }
    }
}

# -------------------------------------------------------------------------
# PLANTILLAS Y TIPOS DE CORREOS SIMULADOS
# -------------------------------------------------------------------------
Write-StatusMsg "Generando $OldMessagesCount correos antiguos (>6 meses) y $RecentMessagesCount correos recientes (<3 meses) en '$Folder'..." -Status "WORKING"

# Resolver endpoint de carpeta
$FolderEndpoint = if ($Folder -eq "All" -or $Folder -eq "SentItems") {
    "v1.0/users/$Mailbox/mailFolders/sentitems/messages"
} else {
    "v1.0/users/$Mailbox/mailFolders/$Folder/messages"
}

# Definición de biblioteca amplia de tipos de correo (asuntos, cuerpos HTML complejos, importancias y adjuntos)
$MailTemplates = @(
    @{
        Subject = "RE: Informe financiero del Proyecto Alpha - Revision de presupuesto Q3"
        Importance = "high"
        Body = "Hola,<br><br>Adjunto enviamos el desglose del presupuesto actualizado para el Proyecto Alpha correspondiente al tercer trimestre.<br><br><table border='1' style='border-collapse:collapse; padding:5px;'><tr style='background:#f1f5f9;'><th>Concepto</th><th>Importe</th></tr><tr><td>Infraestructura Cloud</td><td>€12.500,00</td></tr><tr><td>Licenciamiento M365</td><td>€8.400,00</td></tr></table><br>Quedamos a la espera de sus comentarios.<br><br>Saludos cordiales,<br><strong>Departamento Financiero</strong>"
        AttachName = "Presupuesto_Proyecto_Alpha_Q3.xlsx"
        AttachType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        AttachHeader = "504B0304" # ZIP/XLSX header
        SizeKB = 350
    },
    @{
        Subject = "Fwd: Especificaciones tecnicas y requerimientos de arquitectura M365"
        Importance = "normal"
        Body = "Estimado equipo,<br><br>Revisar el archivo adjunto con la arquitectura propuesta para la migracion de servicios.<br><p style='color:#0284c7;'><strong>Resumen de hitos:</strong></p><ul><li>Fase 1: Auditoria y Discovery</li><li>Fase 2: Despliegue de identidades</li><li>Fase 3: Migracion de buzones</li></ul><br>Atentamente,<br><strong>Equipo de Arquitectura</strong>"
        AttachName = "Especificacion_Tecnica_M365.pdf"
        AttachType = "application/pdf"
        AttachHeader = "25504446" # PDF header
        SizeKB = 450
    },
    @{
        Subject = "Solicitud urgente de confirmacion de propuesta comercial #4092"
        Importance = "high"
        Body = "Hola,<br><br>Nos gustaria saber si han podido revisar la propuesta comercial #4092 enviada la semana pasada. La oferta vence a final de mes.<br><br>Adjuntamos copia escaneada del contrato marco para su firma.<br><br>Un saludo,<br><strong>Area Ventas Enterprise</strong>"
        AttachName = "Contrato_Marco_Firmado.pdf"
        AttachType = "application/pdf"
        AttachHeader = "25504446"
        SizeKB = 280
    },
    @{
        Subject = "Minuta de la reunion mensual de estrategia de ciberseguridad"
        Importance = "normal"
        Body = "Buenos dias,<br><br>A continuacion compartimos el resumen de la sesion mensual de ciberseguridad y los acuerdos alcanzados:<br><ol><li>Habilitacion obligatoria de MFA en Entra ID.</li><li>Revision de politicas de retencion en Exchange Online.</li><li>Auditoria dinamica de accesos externos.</li></ol><br>Ver adjunto comprimido con los logs detallados.<br><br>Saludos,<br><strong>SOC / Ciberseguridad</strong>"
        AttachName = "Logs_Auditoria_SOC.zip"
        AttachType = "application/zip"
        AttachHeader = "504B0304"
        SizeKB = 520
    },
    @{
        Subject = "Notificacion de cambio en la configuracion de servicios de red"
        Importance = "low"
        Body = "Hola,<br><br>Informamos que este fin de semana se realizara una ventana de mantenimiento programada en la infraestructura de red central.<br><br>No se preven cortes prolongados del servicio.<br><br>Atentamente,<br><strong>Sistemas & Redes</strong>"
        AttachName = "Plan_Mantenimiento_Red.docx"
        AttachType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        AttachHeader = "504B0304"
        SizeKB = 200
    },
    @{
        Subject = "Propuesta de optimizacion de costes de infraestructura cloud Azure"
        Importance = "normal"
        Body = "Estimado cliente,<br><br>Tras analizar la telemetria de sus cargas de trabajo en Azure, hemos identificado una oportunidad de ahorro del 28% mediante el uso de Instancias Reservadas.<br><br>Adjuntamos el informe ejecutivo completo.<br><br>Saludos,<br><strong>Cloud FinOps Team</strong>"
        AttachName = "Informe_FinOps_Azure.pdf"
        AttachType = "application/pdf"
        AttachHeader = "25504446"
        SizeKB = 410
    },
    @{
        Subject = "Seguimiento de acuerdo de nivel de servicio (SLA) - Reporte mensual"
        Importance = "normal"
        Body = "Hola,<br><br>Cumplimiento del SLA en el ultimo periodo: <strong>99,98%</strong>.<br>Tiempo medio de respuesta (MTTR): 14 minutos.<br><br>Gracias por su confianza.<br><br>Atentamente,<br><strong>Service Desk Lead</strong>"
        AttachName = "Reporte_SLA_Mensual.pdf"
        AttachType = "application/pdf"
        AttachHeader = "25504446"
        SizeKB = 310
    },
    @{
        Subject = "Confirmacion de recepcion de facturas y ordenes de compra"
        Importance = "normal"
        Body = "Estimados,<br><br>Confirmamos la correcta recepcion de la orden de compra #88192 y la factura correspondiente.<br><br>Pasamos el expediente al departamento de contabilidad para su tramitacion.<br><br>Saludos,<br><strong>Administracion & Facturacion</strong>"
        AttachName = "Factura_OC88192.pdf"
        AttachType = "application/pdf"
        AttachHeader = "25504446"
        SizeKB = 190
    }
)

function New-SimulatedBase64Attachment {
    param([int]$SizeKB)
    $TotalBytes = $SizeKB * 1024
    $Bytes = [byte[]](1..$TotalBytes | ForEach-Object { Get-Random -Minimum 32 -Maximum 126 })
    return [Convert]::ToBase64String($Bytes)
}

$CreatedCount = 0

# -------------------------------------------------------------------------
# 1. CREACIÓN DE MENSAJES ANTIGUOS (>6 A 12 MESES EN EL PASADO)
# -------------------------------------------------------------------------
if ($OldMessagesCount -gt 0) {
    for ($i = 1; $i -le $OldMessagesCount; $i++) {
        Write-Progress -Activity "Creando correos de prueba" -Status "Creando correo antiguo $i de $OldMessagesCount..." -PercentComplete (($i / $OldMessagesCount) * 50)
        
        $DaysBack = Get-Random -Minimum 190 -Maximum 365
        $FakeDate = (Get-Date).AddDays(-$DaysBack).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        
        $Tpl = $MailTemplates[($i - 1) % $MailTemplates.Count]
        $Subject = "$($Tpl.Subject) (Prueba antigua #$i)"
        $BodyContent = "$($Tpl.Body)<br><hr><span style='color:#64748b; font-size:11px;'>ID auditoria: TEST-OLD-$i-$DaysBack | Fecha simulada: $FakeDate</span>"
        $Base64Content = New-SimulatedBase64Attachment -SizeKB $Tpl.SizeKB

        $MessageBody = @{
            subject          = $Subject
            importance       = $Tpl.Importance
            isDraft          = $false
            sentDateTime     = $FakeDate
            receivedDateTime = $FakeDate
            body             = @{
                contentType = "HTML"
                content     = $BodyContent
            }
            toRecipients     = @(
                @{ emailAddress = @{ address = $RecipientEmail } }
            )
            attachments      = @(
                @{
                    "@odata.type" = "#microsoft.graph.fileAttachment"
                    name          = "Antiguo_$i`_$($Tpl.AttachName)"
                    contentType   = $Tpl.AttachType
                    contentBytes  = $Base64Content
                }
            )
            singleValueExtendedProperties = @(
                @{
                    id    = "SystemTime 0x0E06"
                    value = $FakeDate
                },
                @{
                    id    = "SystemTime 0x0039"
                    value = $FakeDate
                }
            )
        }

        try {
            $Resp = Invoke-MgGraphWithRetry -Method POST -Uri $FolderEndpoint -Body $MessageBody
            $CreatedCount++
            Write-Host "     [+] Correo antiguo #$i creado (Fecha: $((Get-Date).AddDays(-$DaysBack).ToString('dd/MM/yyyy')), Asunto: '$Subject')" -ForegroundColor DarkGray
        } catch {
            # Fallback sin propiedades extendidas en caso de que el tenant restrinja extended properties
            try {
                $FallbackBody = @{
                    subject          = $Subject
                    importance       = $Tpl.Importance
                    isDraft          = $false
                    sentDateTime     = $FakeDate
                    receivedDateTime = $FakeDate
                    body             = @{ contentType = "HTML"; content = $BodyContent }
                    toRecipients     = @( @{ emailAddress = @{ address = $RecipientEmail } } )
                    attachments      = @(
                        @{
                            "@odata.type" = "#microsoft.graph.fileAttachment"
                            name          = "Antiguo_$i`_$($Tpl.AttachName)"
                            contentType   = $Tpl.AttachType
                            contentBytes  = $Base64Content
                        }
                    )
                }
                $Resp = Invoke-MgGraphWithRetry -Method POST -Uri $FolderEndpoint -Body $FallbackBody
                $CreatedCount++
                Write-Host "     [+] Correo antiguo #$i creado (Fecha: $((Get-Date).AddDays(-$DaysBack).ToString('dd/MM/yyyy')))" -ForegroundColor DarkGray
            } catch {
                Write-StatusMsg "Error al generar correo antiguo #$($i): $_" -Status "WARN"
            }
        }
    }
}

# -------------------------------------------------------------------------
# 2. CREACIÓN DE MENSAJES RECIENTES (<1 A 2 MESES EN EL PASADO)
# -------------------------------------------------------------------------
if ($RecentMessagesCount -gt 0) {
    for ($j = 1; $j -le $RecentMessagesCount; $j++) {
        Write-Progress -Activity "Creando correos de prueba" -Status "Creando correo reciente $j de $RecentMessagesCount..." -PercentComplete (50 + (($j / $RecentMessagesCount) * 50))
        
        $DaysBack = Get-Random -Minimum 5 -Maximum 45
        $FakeDate = (Get-Date).AddDays(-$DaysBack).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        
        $Tpl = $MailTemplates[($j + 2) % $MailTemplates.Count]
        $Subject = "$($Tpl.Subject) (Prueba reciente #$j)"
        $BodyContent = "$($Tpl.Body)<br><hr><span style='color:#64748b; font-size:11px;'>ID auditoria: TEST-RECENT-$j-$DaysBack | Fecha simulada: $FakeDate</span>"
        $Base64Content = New-SimulatedBase64Attachment -SizeKB ($Tpl.SizeKB - 50)

        $MessageBody = @{
            subject          = $Subject
            importance       = $Tpl.Importance
            isDraft          = $false
            sentDateTime     = $FakeDate
            receivedDateTime = $FakeDate
            body             = @{
                contentType = "HTML"
                content     = $BodyContent
            }
            toRecipients     = @(
                @{ emailAddress = @{ address = $RecipientEmail } }
            )
            attachments      = @(
                @{
                    "@odata.type" = "#microsoft.graph.fileAttachment"
                    name          = "Reciente_$j`_$($Tpl.AttachName)"
                    contentType   = $Tpl.AttachType
                    contentBytes  = $Base64Content
                }
            )
            singleValueExtendedProperties = @(
                @{
                    id    = "SystemTime 0x0E06"
                    value = $FakeDate
                },
                @{
                    id    = "SystemTime 0x0039"
                    value = $FakeDate
                }
            )
        }

        try {
            $Resp = Invoke-MgGraphWithRetry -Method POST -Uri $FolderEndpoint -Body $MessageBody
            $CreatedCount++
            Write-Host "     [+] Correo reciente #$j creado (Fecha: $((Get-Date).AddDays(-$DaysBack).ToString('dd/MM/yyyy')), Asunto: '$Subject')" -ForegroundColor DarkGray
        } catch {
            # Fallback sin propiedades extendidas
            try {
                $FallbackBody = @{
                    subject          = $Subject
                    importance       = $Tpl.Importance
                    isDraft          = $false
                    sentDateTime     = $FakeDate
                    receivedDateTime = $FakeDate
                    body             = @{ contentType = "HTML"; content = $BodyContent }
                    toRecipients     = @( @{ emailAddress = @{ address = $RecipientEmail } } )
                    attachments      = @(
                        @{
                            "@odata.type" = "#microsoft.graph.fileAttachment"
                            name          = "Reciente_$j`_$($Tpl.AttachName)"
                            contentType   = $Tpl.AttachType
                            contentBytes  = $Base64Content
                        }
                    )
                }
                $Resp = Invoke-MgGraphWithRetry -Method POST -Uri $FolderEndpoint -Body $FallbackBody
                $CreatedCount++
                Write-Host "     [+] Correo reciente #$j creado (Fecha: $((Get-Date).AddDays(-$DaysBack).ToString('dd/MM/yyyy')))" -ForegroundColor DarkGray
            } catch {
                Write-StatusMsg "Error al generar correo reciente #$($j): $_" -Status "WARN"
            }
        }
    }
}

Write-Progress -Activity "Creando correos de prueba" -Completed

Write-Host "`n=========================================================================" -ForegroundColor Green
Write-Host "                CORREOS DE PRUEBA GENERADOS EN EXCHANGE                  " -ForegroundColor White
Write-Host "=========================================================================" -ForegroundColor Green
Write-Host (" Buzon Objetivo                        : {0}" -f $Mailbox) -ForegroundColor White
Write-Host (" Destinatario Filtro                   : {0}" -f $RecipientEmail) -ForegroundColor Yellow
Write-Host (" Carpeta del Buzon                     : {0}" -f $Folder) -ForegroundColor White
Write-Host (" Correos Antiguos (>6 meses) Creados   : {0}" -f $OldMessagesCount) -ForegroundColor Red
Write-Host (" Correos Recientes (<3 meses) Creados  : {0}" -f $RecentMessagesCount) -ForegroundColor White
Write-Host (" Total de Mensajes Generados           : {0}" -f $CreatedCount) -ForegroundColor Green
Write-Host "=========================================================================`n" -ForegroundColor Green

Write-Host "💡 AHORA PUEDES PROBAR EL SCRIPT DE AUDITORIA Y LIMPIEZA CON ESTE COMANDO:" -ForegroundColor Yellow
Write-Host "   .\'Microsoft 365 - Exchange - Limpieza_Correos_Destinatario.ps1' -Mailbox '$Mailbox' -RecipientEmail '$RecipientEmail' -MonthsOld 6 -Folder '$Folder'`n" -ForegroundColor Cyan
