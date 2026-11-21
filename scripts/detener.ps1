# Seccion 4.13 del documento: detener el emulador (sin borrar la configuracion)
$Raiz = Split-Path -Parent $PSScriptRoot
Set-Location $Raiz
docker compose stop
Write-Host 'Emulador detenido. Para borrar todo el estado ejecuta scripts\limpiar.ps1'
