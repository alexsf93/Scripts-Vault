<#
.SYNOPSIS
    Instalacion desatendida de roles ADDS y DNS, y creacion de DominioA.local.

.DESCRIPTION
    Instalacion 100% desatendida de los roles ADDS y DNS.
    Crea automaticamente el dominio 'DominioA.local' con NetBIOS 'DOMINIOA'.
    Configura la contrasena DSRM y reinicia el servidor.

.PARAMETER NoParameter
    Este script utiliza variables internas para la configuracion.

.EXAMPLE
    .\Automatizaciones_Server_AADS_DNS_DOMINIOA.ps1
    Instala ADDS, DNS y promueve el servidor a controlador de dominio.

.NOTES
    Nombre:   Automatizaciones_Server_AADS_DNS_DOMINIOA.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.0
    Requisitos: Ejecutar como Administrador.
#>

$domainName = "DominioA.local"
$netbiosName = "DOMINIOA"
$dsrmPassword = ConvertTo-SecureString "Naxvan1993" -AsPlainText -Force  # Cambia la contrasena por seguridad

# Instala los roles
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

# Instala el dominio de manera desatendida
Install-ADDSForest `
  -DomainName $domainName `
  -DomainNetbiosName $netbiosName `
  -SafeModeAdministratorPassword $dsrmPassword `
  -InstallDns `
  -Force `
  -NoRebootOnCompletion:$false  # Reinicia automaticamente despues

# El servidor se reiniciara solo tras la promocion como DC.
