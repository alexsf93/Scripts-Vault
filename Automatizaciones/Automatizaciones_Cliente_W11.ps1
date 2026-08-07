<#
.SYNOPSIS
    Configuracion automatica de VM Windows 11.

.DESCRIPTION
    Configuracion automatica de VM Windows 11:
    - Region, zona horaria (Madrid) y teclado espanol (ES).
    - Instalacion de software basico (Notepad++, 7-Zip).
    - Limpieza del sistema y eliminacion de bloatware.
    - Configuracion de Windows Update y Storage Sense.

.PARAMETER NoParameter
    Este script no requiere parametros.

.EXAMPLE
    .\Automatizaciones_Cliente_W11.ps1
    Ejecuta la configuracion automatica y reinicia el equipo.

.NOTES
    Nombre:   Automatizaciones_Cliente_W11.ps1
    Autor:    Alejandro Suarez (@alexsf93)
    Version:  1.0
    Requisitos: Ejecutar como Administrador.
#>


# --------- ZONA HORARIA (Madrid) ---------
Set-TimeZone -Id "Romance Standard Time"

# --------- TECLADO ESPANOL (Espana) ---------
$LangList = Get-WinUserLanguageList
$LangList[0].InputMethodTips.Clear()
$LangList[0].InputMethodTips.Add("040a:0000040a")
Set-WinUserLanguageList $LangList -Force
Set-WinDefaultInputMethodOverride -InputTip "040a:0000040a"

# --------- WINDOWS UPDATE OPCIONES AVANZADAS ---------
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "IsContinuousInnovationOptedIn" -Value 1 -Type DWord

try {
  $ServiceManager = New-Object -ComObject Microsoft.Update.ServiceManager
  $ServiceManager.ClientApplicationID = "My App"
  $ServiceManager.AddService2("7971f918-a847-4430-9279-4a52d1efe18d", 7, "")
}
catch {
  Write-Output "Microsoft Update ya estaba registrado o no es necesario registrar."
}

Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "RestartForFeatureUpdatesEnabled" -Value 1 -Type DWord

# --------- INSTALACION DE SOFTWARE BASICO (Notepad++ y 7-Zip) ---------
# Instala 7-Zip
Invoke-WebRequest -Uri "https://www.7-zip.org/a/7z2301-x64.exe" -OutFile "$env:TEMP\7z.exe"
Start-Process "$env:TEMP\7z.exe" -ArgumentList "/S" -Wait

# Instala Notepad++
Invoke-WebRequest -Uri "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.6.8/npp.8.6.8.Installer.x64.exe" -OutFile "$env:TEMP\npp.exe"
Start-Process "$env:TEMP\npp.exe" -ArgumentList "/S" -Wait

# --------- LIMPIEZA DE TEMPORALES Y LOGS ---------
Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
wevtutil el | Foreach-Object { wevtutil cl "$_" } 2>$null

# --------- HABILITAR STORAGE SENSE (Limpiador automatico) ---------
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Name "01" -Value 1 -Type DWord
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Name "08" -Value 30 -Type DWord
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" -Name "32" -Value 30 -Type DWord

# --------- ELIMINAR BLOATWARE ---------
$unwantedApps = @(
  "king.com.CandyCrushSaga",
  "king.com.CandyCrushSodaSaga",
  "Microsoft.SkypeApp",
  "Microsoft.ZuneMusic",
  "Microsoft.ZuneVideo",
  "Microsoft.XboxApp",
  "Microsoft.XboxGameOverlay",
  "Microsoft.XboxGamingOverlay",
  "Microsoft.XboxIdentityProvider",
  "Microsoft.XboxSpeechToTextOverlay",
  "Microsoft.Xbox.TCUI",
  "SpotifyAB.SpotifyMusic",
  "Microsoft.GetHelp",
  "Microsoft.Getstarted",
  "Microsoft.Microsoft3DViewer",
  "Microsoft.MicrosoftSolitaireCollection",
  "Microsoft.MicrosoftStickyNotes",
  "Microsoft.MixedReality.Portal",
  "Microsoft.OneConnect",
  "Microsoft.People",
  "Microsoft.Print3D",
  "Microsoft.WindowsAlarms",
  "Microsoft.WindowsFeedbackHub",
  "Microsoft.WindowsMaps",
  "Microsoft.WindowsSoundRecorder",
  "Microsoft.YourPhone",
  "Microsoft.Office.OneNote"
)
foreach ($app in $unwantedApps) {
  Get-AppxPackage -Name $app -AllUsers | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
  Get-AppxProvisionedPackage -Online | Where-Object DisplayName -EQ $app | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
}

# --------- DESACTIVAR SERVICIOS INNECESARIOS (Ejemplo: Xbox Game Bar) ---------
Stop-Service -Name "XboxNetApiSvc" -ErrorAction SilentlyContinue
Set-Service -Name "XboxNetApiSvc" -StartupType Disabled -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -Type DWord
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord

# --------- REINICIO FINAL ---------
Restart-Computer -Force
