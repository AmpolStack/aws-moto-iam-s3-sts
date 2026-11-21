# Emulador AWS libre con evaluacion real de politicas IAM.
# Moto cubre IAM + S3 + STS, que son exactamente los servicios del trabajo final.
FROM python:3.13-slim

RUN pip install --no-cache-dir "moto[server]==5.2.5"

EXPOSE 4566

# INITIAL_NO_AUTH_ACTION_COUNT se define en docker-compose.yml:
# las 3 primeras peticiones crean el usuario admin, su access key y le
# adjuntan la politica de administrador; a partir de ahi TODA peticion
# se autoriza contra las politicas IAM.
CMD ["moto_server", "-H", "0.0.0.0", "-p", "4566"]
