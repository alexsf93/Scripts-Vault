<#
.SYNOPSIS
    Exchange Online - Gestion y Automatizacion de Miembros en Listas de Distribucion (v1.0.0).

.DESCRIPTION
    Script generico y modular de administracion para Exchange Online enfocado en la gestion 
    automatizada de miembros en Listas de Distribucion (Distribution Lists) y Grupos de Seguridad 
    habilitados para correo en cualquier organizacion / tenant de Microsoft 365.
    
    Capacidades principales:
    - Añadir uno o multiples usuarios a una o varias listas de distribucion.
    - Eliminar uno o multiples usuarios de una o varias listas de distribucion.
    - Reemplazar/Sustituir automaticamente a un usuario saliente por otro entrante en listas especificas o en todas las listas del tenant donde sea miembro (Offboarding & Sustitucion).
    - Eliminar a un usuario de todas las listas de distribucion del tenant donde este presente (Offboarding total).
    - Consultar y auditar todas las listas de distribucion a las que pertenece un usuario en el tenant.
    - Soporte multi-cliente / Delegated Administration (CSP / GDAP / Partner) mediante -DelegatedOrganization.
    - Modo Interactivo mediante consola con menu guiado si se ejecuta sin parametros.
    - Soporte completo para ejecucion desatendida, canalizacion (pipeline), simulacion (-WhatIf) y throttling control.

.PARAMETER DistributionGroup
    Nombre, alias o direccion de correo de la(s) lista(s) de distribucion objetivo. Acepta array o cadena separada por comas.

.PARAMETER AddMember
    Direccion(es) de correo de los usuarios que se añadiran a la(s) lista(s). Acepta array o cadena separada por comas.

.PARAMETER RemoveMember
    Direccion(es) de correo de los usuarios que se eliminaran de la(s) lista(s). Acepta array o cadena separada por comas.

.PARAMETER ReplaceUser
    Direccion de correo del usuario saliente que se desea sustituir.

.PARAMETER WithUser
    Direccion de correo del nuevo usuario entrante que reemplazara al usuario saliente.

.PARAMETER ScanAllGroups
    Indica que se deben escanear todas las listas de distribucion del tenant (util para reemplazo global u offboarding).

.PARAMETER AuditUser
    Direccion de correo de un usuario para consultar en que listas de distribucion esta presente.

.PARAMETER DelegatedOrganization
    (Opcional) Dominio del tenant cliente (ej: "cliente.onmicrosoft.com") para administradores delegados / CSP / GDAP.

.PARAMETER UserPrincipalName
    (Opcional) Cuenta de administrador con la que autenticarse en Exchange Online.

.PARAMETER ExportCsv
    (Opcional) Ruta de archivo CSV para guardar el resumen de acciones realizadas.

.PARAMETER RequestDelayMs
    (Opcional) Tiempo de espera en milisegundos entre operaciones para evitar throttling de API. Por defecto: 200 ms.

.EXAMPLE
    & '.\Microsoft 365 - Exchange - Gestion_Listas_Distribucion.ps1' -DistributionGroup "it-soporte@naxvan.es" -AddMember "nuevo.usuario@naxvan.es" -RemoveMember "antiguo.usuario@naxvan.es"
    Añade a nuevo.usuario y elimina a antiguo.usuario de la lista de distribucion it-soporte@naxvan.es.

.EXAMPLE
    $listas = @("dl-ventas-madrid@naxvan.es", "dl-ventas-global@naxvan.es", "dl-operaciones@naxvan.es")
    & '.\Microsoft 365 - Exchange - Gestion_Listas_Distribucion.ps1' -DistributionGroup $listas -AddMember "juan.perez@naxvan.es" -RemoveMember "maria.lopez@naxvan.es"
    Aplica las altas y bajas en multiples listas simultaneamente en el tenant de naxvan.es.

.EXAMPLE
    & '.\Microsoft 365 - Exchange - Gestion_Listas_Distribucion.ps1' -ReplaceUser "baja.empleado@naxvan.es" -WithUser "alta.empleado@naxvan.es" -ScanAllGroups
    Busca todas las listas de distribucion del tenant donde 'baja.empleado' es miembro, lo retira y añade en su lugar a 'alta.empleado'.

.EXAMPLE
    & '.\Microsoft 365 - Exchange - Gestion_Listas_Distribucion.ps1' -AuditUser "usuario.auditar@naxvan.es"
    Muestra un reporte de todas las listas de distribucion a las que pertenece el usuario en naxvan.es.

.EXAMPLE
    & '.\Microsoft 365 - Exchange - Gestion_Listas_Distribucion.ps1' -DelegatedOrganization "naxvan.onmicrosoft.com"
    Inicia el asistente interactivo conectado directamente al tenant de naxvan.es mediante administración delegada.

.NOTES
    Nombre:      Microsoft 365 - Exchange - Gestion_Listas_Distribucion.ps1
    Autor:       Alejandro Suarez (@alexsf93)
    Version:     1.0.0
    Fecha:       2026-08-22
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('Identity', 'Group', 'DistributionList', 'DL')]
    [string[]]$DistributionGroup,

    [Parameter(Mandatory = $false)]
    [Alias('Add', 'AddMembers')]
    [string[]]$AddMember,

    [Parameter(Mandatory = $false)]
    [Alias('Remove', 'RemoveMembers')]
    [string[]]$RemoveMember,

    [Parameter(Mandatory = $false)]
    [Alias('OldUser', 'UserToReplace')]
    [string]$ReplaceUser,

    [Parameter(Mandatory = $false)]
    [Alias('NewUser', 'ReplacementUser')]
    [string]$WithUser,

    [Parameter(Mandatory = $false)]
    [Alias('All', 'ScanAll')]
    [switch]$ScanAllGroups,

    [Parameter(Mandatory = $false)]
    [Alias('SearchUser', 'CheckUser')]
    [string]$AuditUser,

    [Parameter(Mandatory = $false)]
    [Alias('Tenant', 'Organization', 'DelegatedTenant', 'ClientTenant')]
    [string]$DelegatedOrganization,

    [Parameter(Mandatory = $false)]
    [Alias('AdminUPN', 'AdminEmail', 'User')]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [string]$ExportCsv,

    [Parameter(Mandatory = $false, HelpMessage = "Tiempo de pausa en ms entre operaciones para evitar throttling")]
    [int]$RequestDelayMs = 200
)

# Forzar consola a UTF-8
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

# Obtiene la fecha y hora convertida explicitamente a la zona horaria de España
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

# Funcion para normalizar y desglosar listas de correos / identificadores
function ConvertTo-CleanList {
    param($InputList)
    if ($null -eq $InputList) { return @() }
    $clean = @()
    foreach ($item in $InputList) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        # Separar por comas, puntos y comas, espacios o saltos de linea si vienen pegados en un bloque
        $tokens = $item -split "[\r\n,;]+"
        foreach ($t in $tokens) {
            $trimmed = $t.Trim()
            # Limpiar etiquetas mailto: o corchetes tipicos de tickets
            $trimmed = $trimmed -replace '(?i)^mailto:', ''
            $trimmed = $trimmed -replace '[<>\[\]\(\)]', ''
            $trimmed = $trimmed.Trim()
            if ($trimmed -and $trimmed -notin $clean) {
                $clean += $trimmed
            }
        }
    }
    return $clean
}

# ---------------------------------------------------------
# 1. Conexion a Exchange Online (con soporte multi-tenant)
# ---------------------------------------------------------
function Ensure-ExchangeConnection {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        Write-Host "Instalando modulo requerido 'ExchangeOnlineManagement'..." -ForegroundColor Yellow
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }

    if (-not (Get-Module -Name ExchangeOnlineManagement)) {
        Import-Module ExchangeOnlineManagement -ErrorAction Stop
    }

    # Comprobar si ya existe sesion y no se requiere un cambio explicito de tenant
    $activeSession = Get-PSSession | Where-Object { $_.ConfigurationName -eq 'Microsoft.Exchange' -and $_.State -eq 'Opened' }
    
    if (-not $activeSession -or $DelegatedOrganization -or $UserPrincipalName) {
        Write-Host "Conectando a Exchange Online..." -ForegroundColor Cyan
        
        $connectParams = @{}
        if ($DelegatedOrganization) {
            $connectParams['DelegatedOrganization'] = $DelegatedOrganization
            Write-Host "  -> Tenant delegado objetivo: $DelegatedOrganization" -ForegroundColor Cyan
        }
        if ($UserPrincipalName) {
            $connectParams['UserPrincipalName'] = $UserPrincipalName
            Write-Host "  -> Cuenta de administrador: $UserPrincipalName" -ForegroundColor Cyan
        }

        try {
            if ($env:ACC_CLOUD -or $env:AZURE_HTTP_USER_AGENT -match 'cloud-shell') {
                Connect-ExchangeOnline -Device @connectParams -ErrorAction Stop
            } else {
                Connect-ExchangeOnline @connectParams -ErrorAction Stop
            }
        } catch {
            Write-Host "Intentando conexion interactiva estándar..." -ForegroundColor Yellow
            Connect-ExchangeOnline @connectParams
        }
    } else {
        Write-Host "Sesion activa de Exchange Online detectada." -ForegroundColor Green
    }

    # Mostrar informacion del tenant conectado
    try {
        $orgConfig = Get-OrganizationConfig -ErrorAction SilentlyContinue
        if ($orgConfig) {
            $orgName = if ($orgConfig.DisplayName) { $orgConfig.DisplayName } else { $orgConfig.Identity }
            Write-Host "Organizacion / Tenant conectado: $orgName" -ForegroundColor Green
        }
    } catch { }
}

# Coleccion de registros para reporte
$global:ReportLog = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-LogEntry {
    param(
        [string]$Group,
        [string]$User,
        [string]$Action,
        [string]$Status,
        [string]$Detail
    )
    $entry = [PSCustomObject]@{
        Fecha         = (Get-SpainDateTime).ToString("yyyy-MM-dd HH:mm:ss")
        Grupo         = $Group
        Usuario       = $User
        Accion        = $Action
        Estado        = $Status
        Detalle       = $Detail
    }
    $global:ReportLog.Add($entry)
    
    $color = switch ($Status) {
        'Exito'      { 'Green' }
        'Omitido'    { 'Yellow' }
        'Aviso'      { 'Yellow' }
        'Error'      { 'Red' }
        'Simulado'   { 'Cyan' }
        Default      { 'White' }
    }
    Write-Host "[$Status] ($Group) -> $Action '$User': $Detail" -ForegroundColor $color
}

# ---------------------------------------------------------
# 2. Funciones de Operaciones en Listas de Distribucion
# ---------------------------------------------------------

function Resolve-DistributionGroup {
    param([string]$Identity)
    try {
        $dg = Get-DistributionGroup -Identity $Identity -ErrorAction Stop
        return $dg
    } catch {
        # Probar como recipient general o mail-enabled group
        try {
            $rec = Get-Recipient -Identity $Identity -ErrorAction Stop
            if ($rec.RecipientTypeDetails -in @('MailUniversalDistributionGroup', 'MailUniversalSecurityGroup', 'MailNonUniversalGroup', 'DynamicDistributionGroup')) {
                return $rec
            }
        } catch { }
        return $null
    }
}

function Get-GroupMembersList {
    param($GroupIdentity)
    try {
        $members = Get-DistributionGroupMember -Identity $GroupIdentity -ResultSize Unlimited -ErrorAction Stop
        return @($members)
    } catch {
        return @()
    }
}

function Invoke-AddMemberToGroup {
    param(
        [Parameter(Mandatory = $true)]$GroupObject,
        [Parameter(Mandatory = $true)][string]$UserEmail
    )
    
    $groupName = $GroupObject.PrimarySmtpAddress
    if (-not $groupName) { $groupName = $GroupObject.DisplayName }

    # Comprobar si el usuario ya es miembro
    $currentMembers = Get-GroupMembersList -GroupIdentity $GroupObject.Identity
    $isAlreadyMember = $currentMembers | Where-Object { 
        $_.PrimarySmtpAddress -eq $UserEmail -or $_.Name -eq $UserEmail -or $_.WindowsEmailAddress -eq $UserEmail -or $_.UserPrincipalName -eq $UserEmail 
    }

    if ($isAlreadyMember) {
        Add-LogEntry -Group $groupName -User $UserEmail -Action "Añadir" -Status "Omitido" -Detail "El usuario ya es miembro de la lista."
        return
    }

    if ($PSCmdlet.ShouldProcess("Lista '$groupName'", "Añadir miembro '$UserEmail'")) {
        try {
            Add-DistributionGroupMember -Identity $GroupObject.Identity -Member $UserEmail -ErrorAction Stop -BypassSecurityGroupManagerCheck
            Add-LogEntry -Group $groupName -User $UserEmail -Action "Añadir" -Status "Exito" -Detail "Usuario añadido correctamente."
        } catch {
            Add-LogEntry -Group $groupName -User $UserEmail -Action "Añadir" -Status "Error" -Detail $_.Exception.Message
        }
    } else {
        Add-LogEntry -Group $groupName -User $UserEmail -Action "Añadir" -Status "Simulado" -Detail "Modo WhatIf: Se añadiria a la lista."
    }

    if ($RequestDelayMs -gt 0) { Start-Sleep -Milliseconds $RequestDelayMs }
}

function Invoke-RemoveMemberFromGroup {
    param(
        [Parameter(Mandatory = $true)]$GroupObject,
        [Parameter(Mandatory = $true)][string]$UserEmail
    )
    
    $groupName = $GroupObject.PrimarySmtpAddress
    if (-not $groupName) { $groupName = $GroupObject.DisplayName }

    # Comprobar si el usuario es miembro
    $currentMembers = Get-GroupMembersList -GroupIdentity $GroupObject.Identity
    $memberMatch = $currentMembers | Where-Object { 
        $_.PrimarySmtpAddress -eq $UserEmail -or $_.Name -eq $UserEmail -or $_.WindowsEmailAddress -eq $UserEmail -or $_.UserPrincipalName -eq $UserEmail 
    }

    if (-not $memberMatch) {
        Add-LogEntry -Group $groupName -User $UserEmail -Action "Eliminar" -Status "Omitido" -Detail "El usuario no pertenece a la lista."
        return
    }

    if ($PSCmdlet.ShouldProcess("Lista '$groupName'", "Eliminar miembro '$UserEmail'")) {
        try {
            Remove-DistributionGroupMember -Identity $GroupObject.Identity -Member $UserEmail -Confirm:$false -ErrorAction Stop -BypassSecurityGroupManagerCheck
            Add-LogEntry -Group $groupName -User $UserEmail -Action "Eliminar" -Status "Exito" -Detail "Usuario eliminado correctamente de la lista."
        } catch {
            Add-LogEntry -Group $groupName -User $UserEmail -Action "Eliminar" -Status "Error" -Detail $_.Exception.Message
        }
    } else {
        Add-LogEntry -Group $groupName -User $UserEmail -Action "Eliminar" -Status "Simulado" -Detail "Modo WhatIf: Se eliminaria de la lista."
    }

    if ($RequestDelayMs -gt 0) { Start-Sleep -Milliseconds $RequestDelayMs }
}

function Invoke-UserAudit {
    param([string]$UserEmail)
    
    Write-Host "`nBuscando pertenencia de '$UserEmail' en todas las listas de distribucion del tenant..." -ForegroundColor Cyan
    $allGroups = Get-DistributionGroup -ResultSize Unlimited
    $foundIn = @()

    $i = 0
    $total = $allGroups.Count
    foreach ($grp in $allGroups) {
        $i++
        Write-Progress -Activity "Auditando listas de distribucion" -Status "Analizando ($i/$total): $($grp.DisplayName)" -PercentComplete (($i / $total) * 100)
        
        $members = Get-GroupMembersList -GroupIdentity $grp.Identity
        $isMember = $members | Where-Object { 
            $_.PrimarySmtpAddress -eq $UserEmail -or $_.Name -eq $UserEmail -or $_.WindowsEmailAddress -eq $UserEmail -or $_.UserPrincipalName -eq $UserEmail 
        }

        if ($isMember) {
            $foundIn += [PSCustomObject]@{
                NombreGrupo          = $grp.DisplayName
                EmailGrupo           = $grp.PrimarySmtpAddress
                TipoGrupo            = $grp.RecipientTypeDetails
                RequiereAprobacion   = $grp.MemberDepartRestriction
            }
            Add-LogEntry -Group $grp.PrimarySmtpAddress -User $UserEmail -Action "Auditoria" -Status "Exito" -Detail "Es miembro de esta lista."
        }
    }
    Write-Progress -Activity "Auditando listas de distribucion" -Completed

    Write-Host "`n--- RESULTADOS DE AUDITORIA PARA '$UserEmail' ---" -ForegroundColor Yellow
    if ($foundIn.Count -gt 0) {
        Write-Host "El usuario pertenece a $($foundIn.Count) lista(s) de distribucion:" -ForegroundColor Green
        $foundIn | Format-Table -AutoSize
    } else {
        Write-Host "El usuario no pertenece a ninguna lista de distribucion en el tenant." -ForegroundColor Yellow
    }
    return $foundIn
}

# ---------------------------------------------------------
# 3. Flujo Principal y Menu Interactivo
# ---------------------------------------------------------

Ensure-ExchangeConnection

$cleanGroups = ConvertTo-CleanList -InputList $DistributionGroup
$cleanAdd = ConvertTo-CleanList -InputList $AddMember
$cleanRemove = ConvertTo-CleanList -InputList $RemoveMember

$isInteractive = (-not $cleanGroups -and -not $cleanAdd -and -not $cleanRemove -and -not $ReplaceUser -and -not $AuditUser)

if ($isInteractive) {
    Clear-Host
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "   EXCHANGE ONLINE - GESTION DE LISTAS DE DISTRIBUCION" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "1. Añadir / Quitar usuarios de listas de distribucion especificas"
    Write-Host "2. Sustituir / Reemplazar un usuario por otro (en listas indicadas o en todo el tenant)"
    Write-Host "3. Retirar a un usuario saliente de TODAS las listas donde pertenezca (Offboarding)"
    Write-Host "4. Auditar / Consultar en que listas de distribucion esta un usuario"
    Write-Host "5. Listar todos los miembros de una lista de distribucion"
    Write-Host "Q. Salir"
    Write-Host "----------------------------------------------------------------"
    
    $opcion = Read-Host "Seleccione una opcion [1-5 o Q]"
    
    switch ($opcion) {
        '1' {
            $rawGroups = Read-Host "`nIntroduce la(s) lista(s) de distribucion (separadas por coma o espacio)"
            $cleanGroups = ConvertTo-CleanList -InputList $rawGroups
            
            $rawAdd = Read-Host "Introduce los usuario(s) a AÑADIR (opcional, separados por coma)"
            $cleanAdd = ConvertTo-CleanList -InputList $rawAdd

            $rawRemove = Read-Host "Introduce los usuario(s) a ELIMINAR (opcional, separados por coma)"
            $cleanRemove = ConvertTo-CleanList -InputList $rawRemove
        }
        '2' {
            $ReplaceUser = (Read-Host "`nIntroduce el correo del usuario SALIENTE (a quitar)").Trim()
            $WithUser = (Read-Host "Introduce el correo del usuario ENTRANTE (a añadir)").Trim()
            
            $scope = Read-Host "¿Deseas buscar en TODAS las listas del tenant donde este '$ReplaceUser'? (S/N)"
            if ($scope -match '^(s|si|y|yes)$') {
                $ScanAllGroups = $true
            } else {
                $rawGroups = Read-Host "Introduce la(s) lista(s) objetivo (separadas por coma)"
                $cleanGroups = ConvertTo-CleanList -InputList $rawGroups
            }
        }
        '3' {
            $userToOffboard = (Read-Host "`nIntroduce el correo del usuario a retirar de TODAS las listas").Trim()
            $cleanRemove = @($userToOffboard)
            $ScanAllGroups = $true
        }
        '4' {
            $AuditUser = (Read-Host "`nIntroduce el correo del usuario a auditar").Trim()
        }
        '5' {
            $groupQuery = (Read-Host "`nIntroduce el nombre o correo de la lista de distribucion").Trim()
            $grpObj = Resolve-DistributionGroup -Identity $groupQuery
            if ($grpObj) {
                Write-Host "`nObteniendo miembros de '$($grpObj.DisplayName)' ($($grpObj.PrimarySmtpAddress))..." -ForegroundColor Cyan
                $members = Get-GroupMembersList -GroupIdentity $grpObj.Identity
                if ($members.Count -gt 0) {
                    $members | Select-Object DisplayName, PrimarySmtpAddress, RecipientTypeDetails | Format-Table -AutoSize
                } else {
                    Write-Host "La lista no tiene miembros actualmente." -ForegroundColor Yellow
                }
            } else {
                Write-Error "No se encontro la lista de distribucion '$groupQuery'."
            }
            Disconnect-ExchangeOnline -Confirm:$false
            exit 0
        }
        Default {
            Write-Host "Operacion cancelada por el usuario." -ForegroundColor Yellow
            Disconnect-ExchangeOnline -Confirm:$false
            exit 0
        }
    }
}

# --- CASO 1: Auditoria de usuario ---
if ($AuditUser) {
    $auditResult = Invoke-UserAudit -UserEmail $AuditUser
    if ($ExportCsv) {
        $auditResult | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Reporte de auditoria exportado a: $ExportCsv" -ForegroundColor Green
    }
    Disconnect-ExchangeOnline -Confirm:$false
    exit 0
}

# --- CASO 2: Reemplazo / Sustitucion de usuario ---
if ($ReplaceUser) {
    if (-not $WithUser -and -not $ScanAllGroups) {
        Write-Error "Para reemplazar un usuario debes indicar el parametro -WithUser con el nuevo usuario."
        Disconnect-ExchangeOnline -Confirm:$false
        exit 1
    }

    if ($ScanAllGroups) {
        Write-Host "`nEscaneando todas las listas de distribucion del tenant para sustituir a '$ReplaceUser'..." -ForegroundColor Cyan
        $groupsToProcess = @()
        $allGroups = Get-DistributionGroup -ResultSize Unlimited
        $i = 0
        $total = $allGroups.Count
        foreach ($grp in $allGroups) {
            $i++
            Write-Progress -Activity "Buscando listas del usuario saliente" -Status "Verificando ($i/$total): $($grp.DisplayName)" -PercentComplete (($i / $total) * 100)
            $members = Get-GroupMembersList -GroupIdentity $grp.Identity
            $match = $members | Where-Object { 
                $_.PrimarySmtpAddress -eq $ReplaceUser -or $_.Name -eq $ReplaceUser -or $_.WindowsEmailAddress -eq $ReplaceUser -or $_.UserPrincipalName -eq $ReplaceUser 
            }
            if ($match) {
                $groupsToProcess += $grp
            }
        }
        Write-Progress -Activity "Buscando listas del usuario saliente" -Completed
        
        Write-Host "Se encontro al usuario '$ReplaceUser' en $($groupsToProcess.Count) lista(s)." -ForegroundColor Yellow
    } else {
        if (-not $cleanGroups) {
            Write-Error "Debes especificar al menos una lista con -DistributionGroup o usar -ScanAllGroups."
            Disconnect-ExchangeOnline -Confirm:$false
            exit 1
        }
        $groupsToProcess = @()
        foreach ($g in $cleanGroups) {
            $resolved = Resolve-DistributionGroup -Identity $g
            if ($resolved) {
                $groupsToProcess += $resolved
            } else {
                Add-LogEntry -Group $g -User $ReplaceUser -Action "Resolver" -Status "Error" -Detail "No se encontro la lista de distribucion."
            }
        }
    }

    if ($groupsToProcess.Count -eq 0) {
        Write-Host "No hay listas para procesar." -ForegroundColor Yellow
    } else {
        Write-Host "`nIniciando proceso de reemplazo:" -ForegroundColor Cyan
        Write-Host "  [-] Saliente: $ReplaceUser" -ForegroundColor Red
        if ($WithUser) {
            Write-Host "  [+] Entrante: $WithUser" -ForegroundColor Green
        }
        Write-Host ""

        foreach ($grp in $groupsToProcess) {
            # 1. Quitar saliente
            Invoke-RemoveMemberFromGroup -GroupObject $grp -UserEmail $ReplaceUser
            # 2. Añadir entrante (si se especifico)
            if ($WithUser) {
                Invoke-AddMemberToGroup -GroupObject $grp -UserEmail $WithUser
            }
        }
    }
}
# --- CASO 3: Adicion / Eliminacion estandar sobre listas ---
elseif ($cleanGroups -or ($ScanAllGroups -and $cleanRemove)) {
    if ($ScanAllGroups -and $cleanRemove) {
        Write-Host "`nEscaneando todas las listas del tenant para dar de baja a: $($cleanRemove -join ', ')..." -ForegroundColor Cyan
        $allGroups = Get-DistributionGroup -ResultSize Unlimited
        $groupsToProcess = $allGroups
    } else {
        if (-not $cleanGroups) {
            Write-Error "No se han especificado listas de distribucion objetivo (-DistributionGroup)."
            Disconnect-ExchangeOnline -Confirm:$false
            exit 1
        }
        $groupsToProcess = @()
        foreach ($g in $cleanGroups) {
            $resolved = Resolve-DistributionGroup -Identity $g
            if ($resolved) {
                $groupsToProcess += $resolved
            } else {
                Add-LogEntry -Group $g -User "-" -Action "Resolver" -Status "Error" -Detail "No se encontro la lista de distribucion."
            }
        }
    }

    foreach ($grp in $groupsToProcess) {
        # Ejecutar eliminaciones
        foreach ($remUser in $cleanRemove) {
            Invoke-RemoveMemberFromGroup -GroupObject $grp -UserEmail $remUser
        }
        # Ejecutar adiciones
        foreach ($addUser in $cleanAdd) {
            Invoke-AddMemberToGroup -GroupObject $grp -UserEmail $addUser
        }
    }
} else {
    Write-Warning "No se especificaron acciones para realizar. Ejecute con -Help para ver ejemplos de uso."
}

# ---------------------------------------------------------
# 4. Resumen final y exportacion
# ---------------------------------------------------------
Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "                    RESUMEN DE OPERACIONES" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ($global:ReportLog.Count -gt 0) {
    $global:ReportLog | Format-Table -Property Fecha, Grupo, Usuario, Accion, Estado, Detalle -AutoSize

    if ($ExportCsv) {
        try {
            $global:ReportLog | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
            Write-Host "`nReporte guardado exitosamente en: $ExportCsv" -ForegroundColor Green
        } catch {
            Write-Warning "No se pudo exportar el CSV: $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "No se registraron cambios o acciones." -ForegroundColor Yellow
}

Disconnect-ExchangeOnline -Confirm:$false
Write-Host "`nDesconectado de Exchange Online." -ForegroundColor Green
