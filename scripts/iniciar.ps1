# Levanta el emulador AWS (Moto) en Docker y espera a que escuche en 4566
$Raiz = Split-Path -Parent $PSScriptRoot
Set-Location $Raiz

docker compose up -d --build
if ($LASTEXITCODE -ne 0) { throw 'No se pudo levantar el emulador con docker compose.' }

Write-Host 'Esperando a que el emulador este listo...'
for ($i = 1; $i -le 30; $i++) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect('localhost', 4566)
        $tcp.Close()
        Write-Host 'Listo: AWS simulado respondiendo en http://localhost:4566' -ForegroundColor Green
        return
    } catch {
        Start-Sleep -Seconds 2
    }
}
throw 'El emulador no respondio en el puerto 4566 tras 60 segundos.'
