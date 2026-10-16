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

- carpeta `/opt/apps/spsil`, clonada con una deploy key propia (`/root/.ssh/deploy_spsil`);
- contenedores `spsil-app` y `spsil-db-1`; la base es **MariaDB** (no Postgres, la app lo necesita);
- ningún puerto abierto: la app entra en la red Docker `web` como `spsil-app` y el proxy
  compartido (`/opt/apps/proxy`) publica `https://spsil.luiscontacto03.com` → `http://spsil-app:8000`.

## Instalación

Todos los secretos se generan **en el servidor** y no salen de él.

```bash
# 1) Deploy key de solo lectura para este repo
ssh-keygen -t ed25519 -C "deploy-spsil" -f /root/.ssh/deploy_spsil -N ""
cat /root/.ssh/deploy_spsil.pub
#    -> GitHub: larceing/APP_TAREAS_SPSIL > Settings > Deploy keys > Add (sin "write access")

# 2) Clonar
GIT_SSH_COMMAND="ssh -i /root/.ssh/deploy_spsil -o IdentitiesOnly=yes" \
  git clone git@github.com:larceing/APP_TAREAS_SPSIL.git /opt/apps/spsil
cd /opt/apps/spsil
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

## Proxy compartido

Añade el subdominio al proxy de `/opt/apps/proxy` igual que `citas` y `krearte`,
con destino `spsil-app:8000`. Según el proxy:

```nginx
# nginx
server {
    server_name spsil.luiscontacto03.com;
    client_max_body_size 50m;
    location / {
        proxy_pass http://spsil-app:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    # + el bloque listen 443 / certificado que usen los demás sitios
}
```

```caddy
# Caddy
spsil.luiscontacto03.com {
    reverse_proxy spsil-app:8000
}
```

Traefik: en vez de tocar el proxy, añade a `app` en `docker-compose.spsil.yml` las
labels `traefik.enable=true`, `traefik.http.routers.spsil.rule=Host(\`spsil.luiscontacto03.com\`)`
y `traefik.http.services.spsil.loadbalancer.server.port=8000`, más el entrypoint/certresolver
que usen las otras apps.

Antes: un registro DNS `A` de `spsil` apuntando a la IP del servidor.

Abre `https://spsil.luiscontacto03.com` y entra con `INSTALAR_ADMIN` / `INSTALAR_ADMIN_PASSWORD`.
Los usuarios de demostración (`ana.lopez`, `carlos.ruiz`) usan la misma contraseña que el admin.

## Operación

```bash
cd /opt/apps/spsil

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
