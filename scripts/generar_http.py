#!/usr/bin/env python3
"""
Genera dos formatos con llamadas HTTP reales, pre-firmadas con AWS SigV4,
para comprobar todos los casos de uso del trabajo final contra Moto:

- `pruebas.http`       -> VS Code REST Client / JetBrains HTTP Client.
- `pruebas_httpie.json` -> export de HTTPie Desktop / Web (version 1.0.0),
                           importable desde Import > HTTPie Desktop.

Uso:
    python scripts/generar_http.py

Requiere haber ejecutado antes: scripts\\ejecutar.ps1
(para que existan las credenciales vigentes en .tmp\\).

Las firmas usan una fecha fija (20260101T000000Z). Moto calcula la firma con
la cabecera X-Amz-Date del propia petición, así que las firmas siguen siendo
válidas mientras no se regenere el entorno con ejecutar.ps1.
"""

from pathlib import Path
from urllib.parse import parse_qsl, urlsplit
import json
import urllib.error
import urllib.request

from botocore.auth import S3SigV4Auth, SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials

RAIZ = Path(__file__).resolve().parent.parent
ENDPOINT = "http://localhost:4566"
HOST = "localhost:4566"
REGION = "us-east-1"
TS = "20260101T000000Z"
SALIDA = RAIZ / "pruebas.http"
SALIDA_HTTPIE = RAIZ / "pruebas_httpie.json"

BUCKET = "evidencias-ucc"


def cargar_credenciales():
    requeridos = {
        "admin": (RAIZ / ".tmp" / "admin_creds.json", False),
        "lector": (RAIZ / ".tmp" / "cred_lector.json", True),
        "editor": (RAIZ / ".tmp" / "cred_editor.json", True),
    }
    credenciales = {}
    for nombre, (ruta, asumido) in requeridos.items():
        if not ruta.exists():
            raise SystemExit(
                f"Falta {ruta.relative_to(RAIZ)}. Ejecuta primero: scripts\\ejecutar.ps1"
            )
        datos = json.loads(ruta.read_text(encoding="utf-8-sig"))
        if asumido:
            c = datos["Credentials"]
            credenciales[nombre] = Credentials(
                c["AccessKeyId"], c["SecretAccessKey"], c["SessionToken"]
            )
        else:
            credenciales[nombre] = Credentials(
                datos["AccessKeyId"], datos["SecretAccessKey"]
            )
    return credenciales


CREDS = cargar_credenciales()


def firmar(perfil, metodo, ruta, cuerpo="", servicio="s3", content_type=None):
    """Devuelve (headers, cuerpo) con una firma SigV4 válida y estática."""
    headers = {"Host": HOST}
    if content_type:
        headers["Content-Type"] = content_type
    peticion = AWSRequest(
        method=metodo,
        url=ENDPOINT + ruta,
        data=cuerpo or None,
        headers=headers,
    )
    auth_cls = S3SigV4Auth if servicio == "s3" else SigV4Auth
    auth = auth_cls(CREDS[perfil], servicio, REGION)
    peticion.context["timestamp"] = TS
    auth._modify_request_before_signing(peticion)
    canonico = auth.canonical_request(peticion)
    a_firmar = auth.string_to_sign(peticion, canonico)
    auth._inject_signature_to_request(peticion, auth.signature(a_firmar, peticion))
    return dict(peticion.headers), cuerpo


FORM = "application/x-www-form-urlencoded; charset=utf-8"
ARN_LECTOR = "arn:aws:iam::000000000000:role/RolLector"
ARN_EDITOR = "arn:aws:iam::000000000000:role/RolEditor"


# (titulo, perfil, metodo, ruta, cuerpo, servicio, content_type, estados_aceptados)
CASOS = [
    ("Ver el panel web de Moto", None, "GET", "/moto-api", "", None, None, [200]),
    ("Ver el estado interno de Moto", None, "GET", "/moto-api/data.json", "", None, None, [200]),

    ("ADMIN: identidad (debe ser user/admin)", "admin", "POST", "/",
     "Action=GetCallerIdentity&Version=2011-06-15", "sts", FORM, [200]),
    ("ADMIN: listar roles (RolLector y RolEditor)", "admin", "POST", "/",
     "Action=ListRoles&Version=2010-05-08", "iam", FORM, [200]),
    ("ADMIN: politicas del RolLector (SoloLectura)", "admin", "POST", "/",
     "Action=ListRolePolicies&Version=2010-05-08&RoleName=RolLector", "iam", FORM, [200]),
    ("ADMIN: politicas del RolEditor (LecturaEscritura)", "admin", "POST", "/",
     "Action=ListRolePolicies&Version=2010-05-08&RoleName=RolEditor", "iam", FORM, [200]),

    ("LECTOR: identidad asumida via STS", "lector", "POST", "/",
     "Action=GetCallerIdentity&Version=2011-06-15", "sts", FORM, [200]),
    ("LECTOR: listar el bucket (PERMITIDO)", "lector", "GET",
     f"/{BUCKET}?list-type=2", "", "s3", None, [200]),
    ("LECTOR: leer archivo_lectura.txt (PERMITIDO)", "lector", "GET",
     f"/{BUCKET}/archivo_lectura.txt", "", "s3", None, [200]),
    ("LECTOR: subir prueba_http_lector.txt (DENEGADO -> 403)", "lector", "PUT",
     f"/{BUCKET}/prueba_http_lector.txt", "", "s3", None, [403]),

    ("EDITOR: identidad asumida via STS", "editor", "POST", "/",
     "Action=GetCallerIdentity&Version=2011-06-15", "sts", FORM, [200]),
    ("EDITOR: listar el bucket (PERMITIDO)", "editor", "GET",
     f"/{BUCKET}?list-type=2", "", "s3", None, [200]),
    ("EDITOR: subir evidencia_http_editor.txt (PERMITIDO -> 200)", "editor", "PUT",
     f"/{BUCKET}/evidencia_http_editor.txt", "", "s3", None, [200]),

    ("ADMIN: comprobar que el archivo del Editor SI esta", "admin", "GET",
     f"/{BUCKET}?list-type=2", "", "s3", None, [200]),
    ("ADMIN: borrar el archivo temporal del Editor", "admin", "DELETE",
     f"/{BUCKET}/evidencia_http_editor.txt", "", "s3", None, [200, 204]),
    ("ADMIN: estado final (solo los 2 archivos del trabajo)", "admin", "GET",
     f"/{BUCKET}?list-type=2", "", "s3", None, [200]),
]


def preparar():
    lista = []
    for titulo, perfil, metodo, ruta, cuerpo, servicio, content_type, estados in CASOS:
        if perfil:
            headers, cuerpo = firmar(perfil, metodo, ruta, cuerpo, servicio, content_type)
        else:
            headers, cuerpo = ({"Accept": "text/html" if ruta == "/moto-api" else "application/json"}, "")
        lista.append((titulo, perfil, metodo, ruta, headers, cuerpo, estados))
    return lista


def escribir_http(lista):
    lineas = [
        "# =============================================================================",
        "# PRUEBAS HTTP DEL TRABAJO FINAL - AWS simulado con Moto en Docker",
        "# =============================================================================",
        "# Generado por: python scripts/generar_http.py",
        "# Abrir con: VS Code (REST Client), JetBrains HTTP Client o similar.",
        "#",
        "# Las peticiones ya llevan firma AWS SigV4 valida con fecha fija",
        "# 20260101T000000Z. No las edites: cambiar cualquier cabecera o cuerpo",
        "# invalida la firma. Si vuelves a ejecutar scripts\\ejecutar.ps1,",
        "# regenera este archivo con python scripts\\generar_http.py.",
        "#",
        "# Esperado: todas 200 salvo 'LECTOR: subir ...' que debe ser 403 AccessDenied.",
        "# =============================================================================",
        "",
        "@host = http://localhost:4566",
        "",
    ]
    for i, (titulo, perfil, metodo, ruta, headers, cuerpo, estados) in enumerate(lista, 1):
        esperado = " o ".join(str(e) for e in estados)
        lineas += [
            f"### {i}. {titulo}",
            f"# Esperado: HTTP {esperado}",
            f"{metodo} {{{{host}}}}{ruta}",
        ]
        for k, v in headers.items():
            lineas.append(f"{k}: {v}")
        lineas.append("")
        if cuerpo:
            lineas.append(cuerpo)
        lineas.append("")
    SALIDA.write_text("\n".join(lineas), encoding="utf-8")
    print(f"Generado: {SALIDA.relative_to(RAIZ)}")


def escribir_httpie(lista):
    """Escribe un export JSON de HTTPie Desktop/Web (esquema v1.0.0).

    La guia oficial de export/import de HTTPie usa un JSON versionado con
    `meta` y `entry`. Aqui se genera una workspace con una coleccion y los
    16 requests. Se usa `queryParams` para los parametros de URL y `body`
    tipo `text` para los cuerpos form-urlencoded (asi el cuerpo enviado es
    byte a byte el mismo que se firmo).
    """
    requests_json = []
    for i, (titulo, perfil, metodo, ruta, headers, cuerpo, estados) in enumerate(lista, 1):
        partes = urlsplit(ruta)
        query = [
            {"name": nombre, "value": valor, "enabled": True}
            for nombre, valor in parse_qsl(partes.query, keep_blank_values=True)
        ]
        cabeceras = [
            {"name": clave, "value": valor, "enabled": True}
            for clave, valor in headers.items()
            # HTTPie genera Host desde la URL; coincide con el host firmado.
            if clave.lower() != "host"
        ]
        cuerpo_json = (
            {"type": "none"}
            if not cuerpo
            else {"type": "text", "text": {"format": "text/plain", "value": cuerpo}}
        )
        requests_json.append({
            "id": f"caso-{i:02d}",
            "name": f"{i}. {titulo} (esperado: {'/'.join(map(str, estados))})",
            "url": ENDPOINT + partes.path,
            "method": metodo,
            "headers": cabeceras,
            "queryParams": query,
            "pathParams": [],
            "auth": {"type": "none"},
            "body": cuerpo_json,
        })

    export = {
        "meta": {
            "format": "httpie",
            "version": "1.0.0",
            "contentType": "workspace",
            "schema": "https://github.com/httpie/schema/blob/main/versions/1.0.0/schema.json",
            "docs": "https://httpie.io/docs/desktop/export",
        },
        "entry": {
            "id": "trabajo-final-nube-moto",
            "name": "Trabajo Final Nube - AWS con Moto",
            "icon": {"name": "cloud", "color": "blue"},
            "collections": [{
                "id": "casos-de-uso",
                "name": "Casos de uso (16 llamadas)",
                "icon": {"name": "database", "color": "green"},
                "auth": {"type": "none"},
                "requests": requests_json,
            }],
            "drafts": [],
            "environments": [],
        },
    }
    SALIDA_HTTPIE.write_text(
        json.dumps(export, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Generado: {SALIDA_HTTPIE.relative_to(RAIZ)}")


def verificar(lista):
    print("\nVerificando las llamadas generadas...")
    fallos = 0
    for titulo, perfil, metodo, ruta, headers, cuerpo, estados in lista:
        req = urllib.request.Request(
            ENDPOINT + ruta,
            data=cuerpo.encode() if cuerpo else None,
            headers=headers,
            method=metodo,
        )
        try:
            resp = urllib.request.urlopen(req, timeout=15)
            estado = resp.status
            resp.read()
        except urllib.error.HTTPError as e:
            estado = e.code
            e.read()
        ok = estado in estados
        if not ok:
            fallos += 1
        marca = "OK  " if ok else "FALLO"
        print(f"  [{marca}] {estado} (esperado { '/'.join(map(str, estados)) })  {titulo}")
    print(f"\nResultado: {len(lista) - fallos}/{len(lista)} llamadas correctas.")
    if fallos:
        raise SystemExit(1)


if __name__ == "__main__":
    casos = preparar()
    escribir_http(casos)
    escribir_httpie(casos)
    verificar(casos)
