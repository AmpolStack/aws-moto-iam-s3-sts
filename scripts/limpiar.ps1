# Seccion 4.13 del documento: equivalente a "localstack rm" = borrar contenedor y estado
$Raiz = Split-Path -Parent $PSScriptRoot
Set-Location $Raiz
docker compose down --rmi local
Remove-Item -Recurse -Force (Join-Path $Raiz '.tmp') -ErrorAction SilentlyContinue
Write-Host 'Estado eliminado. Vuelve a ejecutar scripts\iniciar.ps1 y scripts\ejecutar.ps1.'
Write-Host 'Las evidencias en evidencias\ se conservan.'
