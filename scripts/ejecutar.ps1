# =============================================================================
# Trabajo Final - Computacion en la Nube
# Gestion de identidades y permisos (AWS IAM + S3 + STS)
#
# Proveedor: Moto (AWS simulado en Docker, gratis, CON evaluacion real de IAM).
# Ejecuta todos los pasos del caso practico:
#   4.3 iniciar / 4.4 perfil AWS CLI / 4.5 bucket / 4.6 rol Lector /
#   4.7 rol Editor / 4.8 verificacion / 4.9-4.11 pruebas / 4.12 evidencias.
# Uso:  .\scripts\ejecutar.ps1
# =============================================================================

$ErrorActionPreference = 'Continue'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$Raiz    = Split-Path -Parent $PSScriptRoot
Set-Location $Raiz

$Endpoint = 'http://localhost:4566'
$Bucket   = 'evidencias-ucc'
$DirEvid  = Join-Path $Raiz 'evidencias'
$DirTmp   = Join-Path $Raiz '.tmp'
New-Item -ItemType Directory -Force -Path $DirEvid, $DirTmp | Out-Null

# Perfil local (credenciales ficticias) dentro del proyecto; no se toca el ~/.aws real.
$env:AWS_CONFIG_FILE             = Join-Path $Raiz '.aws\config'
$env:AWS_SHARED_CREDENTIALS_FILE = Join-Path $Raiz '.aws\credentials'
$env:AWS_DEFAULT_REGION          = 'us-east-1'
$env:AWS_EC2_METADATA_DISABLED   = 'true'
Remove-Item Env:\AWS_ACCESS_KEY_ID, Env:\AWS_SECRET_ACCESS_KEY, Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue

# AWS CLI instalado como modulo de Python; equivale al comando `aws`.
function aws { & python -m awscli --endpoint-url $Endpoint @args }
# Solo para el bootstrap: usa el perfil con credenciales ficticias.
function awsDummy { & python -m awscli --profile moto --endpoint-url $Endpoint @args }

$script:checks = @()

function Run-Step {
    param([string]$Titulo, [string]$Archivo, [string]$Comando, [scriptblock]$Accion)
    Write-Host "`n===== $Titulo =====" -ForegroundColor Cyan
    Write-Host "> $Comando" -ForegroundColor DarkGray
    $salida = (& $Accion 2>&1 | Out-String)
    # PowerShell 5.1 envuelve el stderr nativo como error records con la ruta
    # local del script. Se conserva el mensaje real de AWS y se descarta ese ruido.
    $salida = (($salida -split "`r?`n") | Where-Object {
        $_ -notmatch '^\s*En [A-Za-z]:\\' -and
        $_ -notmatch '^\s*\+\s' -and
        $_ -notmatch 'FullyQualifiedErrorId' -and
        $_ -notmatch '^\s*$'
    } | ForEach-Object { $_ -replace '^python\.exe :\s*', '' }) -join "`n"
    Write-Host $salida
    if ($Archivo) {
        $header = "===== $Titulo =====`nCOMANDO: $Comando`nFECHA: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n"
        Set-Content -Path (Join-Path $DirEvid $Archivo) -Value ($header + $salida) -Encoding UTF8
    }
    return $salida
}

function Assert-Step {
    param([bool]$Condicion, [string]$Mensaje)
    if ($Condicion) {
        Write-Host "  [OK] $Mensaje" -ForegroundColor Green
        $script:checks += "OK    - $Mensaje"
    } else {
        Write-Host "  [FALLO] $Mensaje" -ForegroundColor Red
        $script:checks += "FALLO - $Mensaje"
    }
}

# Anade a la evidencia la identidad AWS real con la que se hizo la prueba.
# Asi se puede comprobar que el AccessDenied corresponde al rol asumido.
function Add-IdentityToEvidence {
    param([string]$Archivo, [string]$Titulo)
    $identidad = (aws sts get-caller-identity 2>&1 | Out-String)
    Add-Content -Path (Join-Path $DirEvid $Archivo) `
        -Value ("`n--- $Titulo ---`n" + $identidad) -Encoding UTF8
}

# ---------------------------------------------------------------------------
# 0. Comprobar que el emulador este escuchando (esto NO es una llamada AWS API,
#    por lo que no consume el contador INITIAL_NO_AUTH_ACTION_COUNT de Moto).
# ---------------------------------------------------------------------------
Write-Host "`n===== 0. Comprobando el emulador en $Endpoint =====" -ForegroundColor Cyan
$listo = $false
for ($i = 1; $i -le 30; $i++) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect('localhost', 4566)
        $tcp.Close()
        $listo = $true
        break
    } catch {
        Write-Host "  esperando al emulador ($i/30)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }
}
if (-not $listo) { Write-Error 'El emulador no responde. Ejecuta primero: docker compose up -d --build'; exit 1 }
Write-Host '  Emulador respondiendo en el puerto 4566.' -ForegroundColor DarkGray

# Empezar desde un estado limpio y fijar exactamente 3 llamadas sin autenticar
# (las del bootstrap). Esto hace el script repetible sin reiniciar el contenedor.
# Se reintenta porque, justo tras `docker compose up`, el puerto ya acepta TCP
# pero el servidor HTTP puede cerrar la primera conexion.
function Reset-Moto {
    param([string]$Uri, [string]$Cuerpo)
    for ($i = 1; $i -le 10; $i++) {
        try {
            if ($Cuerpo) {
                $null = Invoke-RestMethod -Method Post -Uri $Uri -Body $Cuerpo -ContentType 'text/plain' -TimeoutSec 10
            } else {
                $null = Invoke-RestMethod -Method Post -Uri $Uri -TimeoutSec 10
            }
            return
        } catch {
            if ($i -eq 10) { throw "No se pudo reiniciar Moto en $Uri : $_" }
            Start-Sleep -Milliseconds 500
        }
    }
}
Reset-Moto -Uri "$Endpoint/moto-api/reset"
Reset-Moto -Uri "$Endpoint/moto-api/reset-auth" -Cuerpo '3'
Remove-Item (Join-Path $DirTmp 'admin_creds.json') -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Arranque de Moto con autorizacion IAM activada.
# Las 3 PRIMERAS llamadas AWS API se hacen sin autorizacion y crean:
#   1) usuario admin   2) su access key   3) su politica AdminTodo
# Despues, Moto autoriza TODA llamada contra las politicas IAM.
# ---------------------------------------------------------------------------
# JSON compacto: la CLI v1 de AWS no acepta bien el documento con saltos de linea.
# PowerShell 5.1 necesita escapar las comillas dobles al pasar JSON a un nativo.
$adminDoc = (Get-Content (Join-Path $Raiz 'iam\politica_admin.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10).Replace('"', '\"')
$archivoAdmin = Join-Path $DirTmp 'admin_creds.json'

if (-not (Test-Path $archivoAdmin)) {
    Write-Host "`n===== 1. Bootstrap: usuario administrador del entorno local =====" -ForegroundColor Cyan
    $null = (& awsDummy iam create-user --user-name admin 2>&1 | Out-String)
    $claveJson = (awsDummy iam create-access-key --user-name admin 2>&1 | Out-String)
    if ($claveJson -notmatch 'AccessKeyId') { Write-Host "DEBUG create-access-key: $claveJson" -ForegroundColor Yellow }
    $clave = ($claveJson | ConvertFrom-Json).AccessKey
    $salidaPol = (& awsDummy iam put-user-policy --user-name admin --policy-name AdminTodo --policy-document $adminDoc 2>&1 | Out-String)
    if ($salidaPol.Trim()) { Write-Host "DEBUG put-user-policy [$adminDoc]: $salidaPol" -ForegroundColor Yellow }
    $admin = @{
        AccessKeyId     = $clave.AccessKeyId
        SecretAccessKey = $clave.SecretAccessKey
    }
    Set-Content -Path $archivoAdmin -Value ($admin | ConvertTo-Json) -Encoding UTF8
    Write-Host '  Usuario admin creado; autorizacion IAM activada a partir de aqui.' -ForegroundColor DarkGray
} else {
    Write-Host "`n  Reutilizando credenciales admin guardadas en .tmp\admin_creds.json" -ForegroundColor DarkGray
}

$admin = Get-Content $archivoAdmin -Raw | ConvertFrom-Json
$env:AWS_ACCESS_KEY_ID    = $admin.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $admin.SecretAccessKey
Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 4.4 Configurar AWS CLI contra el emulador (get-caller-identity)
# ---------------------------------------------------------------------------
$id = Run-Step -Titulo '4.4 - Identidad del perfil' `
    -Archivo '00_get_caller_identity.txt' `
    -Comando 'aws sts get-caller-identity' `
    -Accion { aws sts get-caller-identity }
Assert-Step ($id -match '000000000000') 'AWS CLI apunta al emulador (cuenta 000000000000)'

# ---------------------------------------------------------------------------
# 4.5 Crear el bucket S3 privado y subir el archivo inicial
# ---------------------------------------------------------------------------
$head = (& aws s3api head-bucket --bucket $Bucket 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $head -match 'NotFound|404') {
    $null = Run-Step -Titulo '4.5 - Crear bucket privado' `
        -Archivo '01_crear_bucket.txt' `
        -Comando "aws s3api create-bucket --bucket $Bucket" `
        -Accion { aws s3api create-bucket --bucket $Bucket }
} else {
    Write-Host "`n  El bucket $Bucket ya existe (ejecucion idempotente)." -ForegroundColor DarkGray
}

Set-Content -Path (Join-Path $Raiz 'archivo_lectura.txt') -Value 'Evidencia academica ficticia - archivo de lectura' -Encoding ASCII
$null = Run-Step -Titulo '4.5 - Subir archivo inicial' `
    -Archivo '02_subir_archivo_inicial.txt' `
    -Comando "aws s3 cp archivo_lectura.txt s3://$Bucket/" `
    -Accion { aws s3 cp archivo_lectura.txt s3://$Bucket/ }

$listaInicial = Run-Step -Titulo '4.5 - Listado inicial del bucket' `
    -Archivo '03_listado_inicial.txt' `
    -Comando "aws s3 ls s3://$Bucket/" `
    -Accion { aws s3 ls s3://$Bucket/ }
Assert-Step ($listaInicial -match 'archivo_lectura.txt') 'El bucket contiene archivo_lectura.txt'

# ---------------------------------------------------------------------------
# 4.6 / 4.7 Crear roles y politicas
# ---------------------------------------------------------------------------
# Se pasa el JSON como cadena (en Windows `file:///C:/...` no es una ruta valida
# para la AWS CLI v1; el contenido inline es equivalente al file:// original).
$trustDoc   = (Get-Content (Join-Path $Raiz 'iam\trust.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10).Replace('"', '\"')
$lecturaDoc = (Get-Content (Join-Path $Raiz 'iam\politica_lectura.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10).Replace('"', '\"')
$editorDoc  = (Get-Content (Join-Path $Raiz 'iam\politica_editor.json') -Raw | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10).Replace('"', '\"')

$rolesActuales = (aws iam list-roles --query 'Roles[].RoleName' --output text | Out-String)
if ($rolesActuales -notmatch 'RolLector') {
    $null = Run-Step -Titulo '4.6 - Crear rol RolLector' `
        -Archivo '04_crear_rol_lector.txt' `
        -Comando 'aws iam create-role --role-name RolLector --assume-role-policy-document file://iam/trust.json' `
        -Accion { aws iam create-role --role-name RolLector --assume-role-policy-document $trustDoc }
} else { Write-Host "`n  RolLector ya existe (ejecucion idempotente)." -ForegroundColor DarkGray }

$null = Run-Step -Titulo '4.6 - Politica SoloLectura' `
    -Archivo '05_politica_lector.txt' `
    -Comando 'aws iam put-role-policy --role-name RolLector --policy-name SoloLectura ...' `
    -Accion { aws iam put-role-policy --role-name RolLector --policy-name SoloLectura --policy-document $lecturaDoc }

if ($rolesActuales -notmatch 'RolEditor') {
    $null = Run-Step -Titulo '4.7 - Crear rol RolEditor' `
        -Archivo '06_crear_rol_editor.txt' `
        -Comando 'aws iam create-role --role-name RolEditor --assume-role-policy-document file://iam/trust.json' `
        -Accion { aws iam create-role --role-name RolEditor --assume-role-policy-document $trustDoc }
} else { Write-Host "`n  RolEditor ya existe (ejecucion idempotente)." -ForegroundColor DarkGray }

$null = Run-Step -Titulo '4.7 - Politica LecturaEscritura' `
    -Archivo '07_politica_editor.txt' `
    -Comando 'aws iam put-role-policy --role-name RolEditor --policy-name LecturaEscritura ...' `
    -Accion { aws iam put-role-policy --role-name RolEditor --policy-name LecturaEscritura --policy-document $editorDoc }

# ---------------------------------------------------------------------------
# 4.8 Verificar roles creados
# ---------------------------------------------------------------------------
$verRoles = Run-Step -Titulo '4.8 - Roles creados' `
    -Archivo '08_roles_creados.txt' `
    -Comando 'aws iam list-roles --query Roles[].RoleName' `
    -Accion { aws iam list-roles --query 'Roles[].RoleName' }
Assert-Step ($verRoles -match 'RolLector' -and $verRoles -match 'RolEditor') 'Ambos roles IAM existen'

$polLector = Run-Step -Titulo '4.8 - Politicas del Lector' `
    -Archivo '09_politicas_lector.txt' `
    -Comando 'aws iam list-role-policies --role-name RolLector' `
    -Accion { aws iam list-role-policies --role-name RolLector }
Assert-Step ($polLector -match 'SoloLectura') 'RolLector tiene la politica SoloLectura'

$polEditor = Run-Step -Titulo '4.8 - Politicas del Editor' `
    -Archivo '10_politicas_editor.txt' `
    -Comando 'aws iam list-role-policies --role-name RolEditor' `
    -Accion { aws iam list-role-policies --role-name RolEditor }
Assert-Step ($polEditor -match 'LecturaEscritura') 'RolEditor tiene la politica LecturaEscritura'

# ---------------------------------------------------------------------------
# 4.9 / 4.10 Pruebas con el rol Lector
# ---------------------------------------------------------------------------
$arnLector = (aws iam get-role --role-name RolLector --query 'Role.Arn' --output text | Out-String).Trim()
$credLectorJson = (aws sts assume-role --role-arn $arnLector --role-session-name SesionLector | Out-String)
Set-Content -Path (Join-Path $DirTmp 'cred_lector.json') -Value $credLectorJson -Encoding UTF8
$credLector = ($credLectorJson | ConvertFrom-Json).Credentials
Assert-Step ($credLector.AccessKeyId -and $credLector.SessionToken) 'STS entrego credenciales temporales al Lector'

$env:AWS_ACCESS_KEY_ID    = $credLector.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $credLector.SecretAccessKey
$env:AWS_SESSION_TOKEN     = $credLector.SessionToken

$lecturaLector = Run-Step -Titulo '4.9 - EVIDENCIA A: Lector lee' `
    -Archivo '11_evidencia_A_lector_lee.txt' `
    -Comando 'aws s3 ls s3://evidencias-ucc/  (credenciales del Lector)' `
    -Accion { aws s3 ls s3://$Bucket/ }
Assert-Step ($lecturaLector -match 'archivo_lectura.txt') 'Evidencia A: el Lector puede listar/leer el bucket'
Add-IdentityToEvidence '11_evidencia_A_lector_lee.txt' 'Identidad AWS usada (STS)'

Set-Content -Path (Join-Path $Raiz 'prueba_lector.txt') -Value 'intento de subida con Lector' -Encoding ASCII
$escrituraLector = Run-Step -Titulo '4.10 - EVIDENCIA B: Lector no escribe' `
    -Archivo '12_evidencia_B_lector_no_escribe.txt' `
    -Comando 'aws s3 cp prueba_lector.txt s3://evidencias-ucc/prueba_lector.txt  (credenciales del Lector)' `
    -Accion { aws s3 cp prueba_lector.txt s3://$Bucket/prueba_lector.txt }
Assert-Step ($escrituraLector -match 'AccessDenied') 'Evidencia B: escritura del Lector denegada (AccessDenied real)'
Add-IdentityToEvidence '12_evidencia_B_lector_no_escribe.txt' 'Identidad AWS usada (STS)'

# ---------------------------------------------------------------------------
# 4.11 Pruebas con el rol Editor
# ---------------------------------------------------------------------------
# Volver a ser admin para poder consultar IAM y pedir el segundo rol.
$env:AWS_ACCESS_KEY_ID    = $admin.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $admin.SecretAccessKey
Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue

$arnEditor = (aws iam get-role --role-name RolEditor --query 'Role.Arn' --output text | Out-String).Trim()
$credEditorJson = (aws sts assume-role --role-arn $arnEditor --role-session-name SesionEditor | Out-String)
Set-Content -Path (Join-Path $DirTmp 'cred_editor.json') -Value $credEditorJson -Encoding UTF8
$credEditor = ($credEditorJson | ConvertFrom-Json).Credentials
Assert-Step ($credEditor.AccessKeyId -and $credEditor.SessionToken) 'STS entrego credenciales temporales al Editor'

$env:AWS_ACCESS_KEY_ID    = $credEditor.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $credEditor.SecretAccessKey
$env:AWS_SESSION_TOKEN     = $credEditor.SessionToken

$lecturaEditor = Run-Step -Titulo '4.11 - Editor lee' `
    -Archivo '13_evidencia_C_editor_lee.txt' `
    -Comando 'aws s3 ls s3://evidencias-ucc/  (credenciales del Editor)' `
    -Accion { aws s3 ls s3://$Bucket/ }
Assert-Step ($lecturaEditor -match 'archivo_lectura.txt') 'El Editor puede listar/leer el bucket'
Add-IdentityToEvidence '13_evidencia_C_editor_lee.txt' 'Identidad AWS usada (STS)'

Set-Content -Path (Join-Path $Raiz 'evidencia_subida.txt') -Value 'Evidencia subida por el rol Editor' -Encoding ASCII
$escrituraEditor = Run-Step -Titulo '4.11 - EVIDENCIA C: Editor escribe' `
    -Archivo '14_evidencia_C_editor_escribe.txt' `
    -Comando 'aws s3 cp evidencia_subida.txt s3://evidencias-ucc/evidencia_subida.txt  (credenciales del Editor)' `
    -Accion { aws s3 cp evidencia_subida.txt s3://$Bucket/evidencia_subida.txt }
Assert-Step ($escrituraEditor -match 'upload:') 'Evidencia C: el Editor puede subir archivos'
Add-IdentityToEvidence '14_evidencia_C_editor_escribe.txt' 'Identidad AWS usada (STS)'

# Restaurar administrador y ver estado final
$env:AWS_ACCESS_KEY_ID    = $admin.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $admin.SecretAccessKey
Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue

$estadoFinal = Run-Step -Titulo '4.12 - EVIDENCIA D: estado final del bucket' `
    -Archivo '15_evidencia_D_estado_final.txt' `
    -Comando "aws s3 ls s3://$Bucket/" `
    -Accion { aws s3 ls s3://$Bucket/ }
Assert-Step ($estadoFinal -match 'archivo_lectura.txt' -and $estadoFinal -match 'evidencia_subida.txt') 'Evidencia D: el bucket contiene los dos archivos'
Assert-Step ($estadoFinal -notmatch 'prueba_lector.txt') 'El archivo denegado al Lector NO esta en el bucket'

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
$resumen = "RESUMEN DE VERIFICACION - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n" +
           ($script:checks -join "`n") + "`n"
Set-Content -Path (Join-Path $DirEvid '00_resumen_verificacion.txt') -Value $resumen -Encoding UTF8
Write-Host "`n$resumen" -ForegroundColor White

$fallos = @($script:checks | Where-Object { $_ -like 'FALLO*' }).Count
if ($fallos -gt 0) {
    Write-Host " Hay $fallos comprobacion(es) fallida(s). Revisa evidencias\" -ForegroundColor Red
    exit 1
}
Write-Host " Todas las comprobaciones pasaron. Evidencias guardadas en evidencias\" -ForegroundColor Green
