# Demo de SPSIL: despliegue en el servidor

Este repositorio es la versión de SPSIL del Gestor de Tareas. Parte de la
**versión base** (`lharce/APP_TAREAS_BASE`) sin tocar su código: lo propio de
SPSIL son solo ficheros de configuración y despliegue, para que traer
mejoras de la base sea un `git merge`.

| Fichero | Qué es |
|---|---|
| `docker-compose.spsil.yml` | Capa sobre `docker-compose.yml`: app solo en localhost + Caddy con HTTPS |
| `despliegue/Caddyfile` | Proxy HTTPS (certificado automático de Let's Encrypt) |
| `.env.spsil.example` | Variables del despliegue (BD, admin, dominio, secretos) |
| `app_fastapi/.env.spsil.example` | Marca SPSIL, login y módulos |

## Requisitos del servidor

- Linux (Ubuntu 22.04/24.04 o Debian 12 recomendados), 2 GB de RAM y 10 GB de disco libres.
- Docker con Compose v2.24 o superior.
- Para HTTPS con Caddy: un dominio cuyo DNS apunte al servidor y los puertos 80 y 443 abiertos.
  Si el servidor ya tiene nginx/IIS/Traefik, se usa ese y se quita el perfil `https`.

## Instalación

```bash
git clone https://github.com/larceing/APP_TAREAS_SPSIL.git app_tareas_spsil
cd app_tareas_spsil
cp .env.spsil.example .env                                  # dominio + contraseñas
cp app_fastapi/.env.spsil.example app_fastapi/.env          # marca SPSIL
python3 -c "import secrets; print(secrets.token_urlsafe(32))"   # para SESSION_SECRET_KEY y contraseñas
docker compose -f docker-compose.yml -f docker-compose.spsil.yml up -d --build
docker compose -f docker-compose.yml -f docker-compose.spsil.yml logs -f app   # ver el primer arranque
```

Abre `https://<DOMINIO>` y entra con `INSTALAR_ADMIN` / `INSTALAR_ADMIN_PASSWORD`.
Los usuarios de demostración (`ana.lopez`, `carlos.ruiz`) usan la misma contraseña que el admin.

Para no escribir los dos `-f` cada vez, añade al `.env`:
`COMPOSE_FILE=docker-compose.yml:docker-compose.spsil.yml`.

## Operación

```bash
# Actualizar a una versión nueva
git pull && docker compose up -d --build

# Copia de la base de datos
docker compose exec db mariadb-dump -uroot -p"$DB_ROOT_PASSWORD" --single-transaction app_tareas_spsil | gzip > copia_$(date +%F).sql.gz

# Usuarios
docker compose exec app python scripts/usuarios.py listar
docker compose exec app python scripts/usuarios.py crear ...

# Pasar de demo a uso real (BORRA los datos de ejemplo)
docker compose exec app python scripts/instalar.py --recrear --si --sin-demo
```

Más detalle en [docs/ADMINISTRACION.md](../docs/ADMINISTRACION.md).

## Traer mejoras de la versión base

```bash
git remote add base https://github.com/lharce/APP_TAREAS_BASE.git   # una vez
git fetch base && git merge base/main
```

Como el código no se toca aquí, el merge no debería dar conflictos.
