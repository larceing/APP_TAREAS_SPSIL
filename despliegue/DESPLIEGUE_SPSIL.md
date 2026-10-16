# Demo de SPSIL: despliegue en el servidor

Este repositorio es la versión de SPSIL del Gestor de Tareas. Parte de la
**versión base** (`lharce/APP_TAREAS_BASE`) sin tocar su código: lo propio de
SPSIL son solo ficheros de configuración y despliegue, para que traer
mejoras de la base sea un `git merge`.

| Fichero | Qué es |
|---|---|
| `docker-compose.spsil.yml` | Capa sobre `docker-compose.yml`: sin puertos propios, unida a la red `web` del proxy |
| `.env.spsil.example` | Variables del despliegue (BD, admin, secretos) |
| `app_fastapi/.env.spsil.example` | Marca SPSIL, login y módulos |

## Cómo encaja en el servidor

Sigue el mismo patrón que las otras apps del servidor:

- carpeta `/opt/apps/spsil-tareas` (no `/opt/apps/spsil`, que puede ser de la app de stock), clonada con una deploy key propia (`/root/.ssh/deploy_spsil`);
- proyecto Docker `spsil-tareas` (contenedores `spsil-tareas-app-1` y `spsil-tareas-db-1`); la base es **MariaDB** (no Postgres, la app lo necesita);
- ningún puerto abierto: la app entra en la red Docker `web` como `spsil-tareas` y Nginx Proxy Manager
  (`/opt/apps/proxy`) publica `https://spsil.luiscontacto03.com` → `http://spsil-tareas:8000`.

## Instalación

Todos los secretos se generan **en el servidor** y no salen de él.

```bash
# 1) Deploy key de solo lectura para este repo
ssh-keygen -t ed25519 -C "deploy-spsil" -f /root/.ssh/deploy_spsil -N ""
cat /root/.ssh/deploy_spsil.pub
#    -> GitHub: larceing/APP_TAREAS_SPSIL > Settings > Deploy keys > Add (sin "write access")

# 2) Clonar
GIT_SSH_COMMAND="ssh -i /root/.ssh/deploy_spsil -o IdentitiesOnly=yes" \
  git clone git@github.com:larceing/APP_TAREAS_SPSIL.git /opt/apps/spsil-tareas
cd /opt/apps/spsil-tareas
git config core.sshCommand "ssh -i /root/.ssh/deploy_spsil -o IdentitiesOnly=yes"

# 3) Configuración
cp .env.spsil.example .env
cp app_fastapi/.env.spsil.example app_fastapi/.env
#    Rellena en .env DB_PASSWORD, DB_ROOT_PASSWORD, INSTALAR_ADMIN_PASSWORD y
#    SESSION_SECRET_KEY, cada uno con un valor distinto de:
openssl rand -hex 32
chmod 600 .env app_fastapi/.env

# 4) Arrancar (el primer arranque crea la BD, el admin y los datos de demo)
docker compose up -d --build
docker compose logs -f app
```

## DNS y proxy (Cloudflare + Nginx Proxy Manager)

1. **Cloudflare** → `luiscontacto03.com` → DNS → Records → *Add record*:
   tipo `A`, nombre `spsil`, IPv4 la del servidor (la misma que `citas`/`krearte`),
   proxy en **DNS only** (nube gris) para que Let's Encrypt emita el certificado sin problemas.
2. **Nginx Proxy Manager** → Hosts → Proxy Hosts → *Add Proxy Host*:
   - Domain Names: `spsil.luiscontacto03.com`
   - Scheme `http`, Forward Hostname `spsil-tareas`, Forward Port `8000`
   - Activa *Block Common Exploits* y *Websockets Support*
   - Pestaña SSL: *Request a new SSL Certificate*, *Force SSL*, *HTTP/2*
   - Pestaña Advanced: `client_max_body_size 50m;` (adjuntos)

No confundir con `spsil-web` (`stock.luiscontacto03.com`), que es otra app: por eso esta
usa la carpeta, el proyecto y el nombre `spsil-tareas`.

Abre `https://spsil.luiscontacto03.com` y entra con `INSTALAR_ADMIN` / `INSTALAR_ADMIN_PASSWORD`.
Los usuarios de demostración (`ana.lopez`, `carlos.ruiz`) usan la misma contraseña que el admin.

## Operación

```bash
cd /opt/apps/spsil-tareas

# Actualizar a una versión nueva
git pull && docker compose up -d --build

# Copia de la base de datos
docker compose exec db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction app_tareas_spsil' | gzip > copia_$(date +%F).sql.gz

# Usuarios
docker compose exec app python scripts/usuarios.py listar
docker compose exec app python scripts/usuarios.py crear ...

# Pasar de demo a uso real (BORRA los datos de ejemplo)
docker compose exec app python scripts/instalar.py --recrear --si --sin-demo
```

Con 4 GB compartidos con otras apps, la app y MariaDB juntas usan unos 400–600 MB.
Más detalle en [docs/ADMINISTRACION.md](../docs/ADMINISTRACION.md).

## Traer mejoras de la versión base

```bash
git remote add base https://github.com/lharce/APP_TAREAS_BASE.git   # una vez
git fetch base && git merge base/main
```

Como el código no se toca aquí, el merge no debería dar conflictos.
