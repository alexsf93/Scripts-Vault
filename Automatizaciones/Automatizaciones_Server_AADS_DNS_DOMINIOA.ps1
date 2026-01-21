<#
.SYNOPSIS
    Instalación desatendida de roles ADDS y DNS, y creación de DominioA.local.

.DESCRIPTION
    Instalación 100% desatendida de los roles ADDS y DNS.
    Crea automáticamente el dominio 'DominioA.local' con NetBIOS 'DOMINIOA'.
    Configura la contraseña DSRM y reinicia el servidor.

.PARAMETER NoParameter
    Este script utiliza variables internas para la configuración.

.EXAMPLE
    .\Automatizaciones_Server_AADS_DNS_DOMINIOA.ps1
    Instala ADDS, DNS y promueve el servidor a controlador de dominio.

.NOTES
    Nombre:   Automatizaciones_Server_AADS_DNS_DOMINIOA.ps1
    Autor:    Alejandro Suárez (@alexsf93)
    Versión:  1.0
    Requisitos: Ejecutar como Administrador.
#>


$domainName = "DominioA.local"
$netbiosName = "DOMINIOA"
$dsrmPassword = ConvertTo-SecureString "Naxvan1993" -AsPlainText -Force  # Cambia la contraseña por seguridad

# Instala los roles
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

# Instala el dominio de manera desatendida
Install-ADDSForest `
  -DomainName $domainName `
  -DomainNetbiosName $netbiosName `
  -SafeModeAdministratorPassword $dsrmPassword `
  -InstallDns `
  -Force `
  -NoRebootOnCompletion:$false  # Reinicia automáticamente después

# El servidor se reiniciará solo tras la promoción como DC.
