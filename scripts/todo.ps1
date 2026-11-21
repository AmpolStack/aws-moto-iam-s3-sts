# =============================================================================
# Ejecucion completa en un solo paso:
#   1) levantar Moto en Docker
#   2) crear infraestructura, credenciales y evidencias
#   3) generar y verificar pruebas.http y pruebas_httpie.json
# Uso: powershell -ExecutionPolicy Bypass -File .\scripts\todo.ps1
# =============================================================================

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
Set-Location $Raiz

Write-Host "`n[1/3] Levantando el emulador AWS (Moto)..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'iniciar.ps1')
if (-not $?) { throw 'No se pudo iniciar el emulador.' }

Write-Host "`n[2/3] Creando bucket, roles y evidencias..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'ejecutar.ps1')
if (-not $?) { throw 'La ejecucion del caso practico fallo.' }

Write-Host "`n[3/3] Generando las llamadas HTTP firmadas..." -ForegroundColor Cyan
& python (Join-Path $PSScriptRoot 'generar_http.py')
if ($LASTEXITCODE -ne 0) { throw 'No se pudieron generar/verificar las pruebas HTTP.' }

Write-Host "`nListo. Todo fue recreado y verificado." -ForegroundColor Green
