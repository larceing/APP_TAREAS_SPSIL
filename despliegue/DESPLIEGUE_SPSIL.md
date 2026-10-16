# Demo de SPSIL: despliegue en el servidor

Este repositorio es la versión de SPSIL del Gestor de Tareas. Parte de la
**versión base** (`lharce/APP_TAREAS_BASE`): lo propio de SPSIL son ficheros de
configuración y despliegue, más dos mejoras genéricas que conviene subir también
a la base (servir la app bajo una ruta, `ruta_base.py`, y el login único
`AUTH_MODO=sso`). Traer mejoras de la base sigue siendo un `git merge`.

| Fichero | Qué es |
|---|---|
| `docker-compose.spsil.yml` | Capa sobre `docker-compose.yml`: sin puertos propios, unida a la red `proxy_default` del proxy |
| `plataforma/` | Portada, reparto por rutas y Keycloak (común a todas las apps de SPSIL) |
| `.env.spsil.example` | Variables del despliegue (BD, admin, secretos) |
| `app_fastapi/.env.spsil.example` | Marca SPSIL, login y módulos |

## Cómo encaja en el servidor

Todo cuelga de `https://spsil.luiscontacto03.com`, con una portada para elegir app
y un solo inicio de sesión (Keycloak) para todas:

| Ruta | App |
|---|---|
| `/` | Portada (`plataforma/`) |
| `/tareas/` | Este Gestor de Tareas |
| `/stock/` | Stock (`APP_DATA_SPSIL`, contenedor `spsil-web`) |
| `/auth/` | Keycloak (`plataforma/`) |

- Carpeta `/opt/apps/spsil-tareas` (no `/opt/apps/spsil`, que puede ser de la app de stock),
  clonada con una deploy key propia (`/root/.ssh/deploy_spsil`).
- Proyecto Docker `spsil-tareas`; la base es **MariaDB** propia (no Postgres, la app lo necesita).
- Ningún puerto abierto: todo entra en la red `proxy_default` de Nginx Proxy Manager.
  La app de tareas es `spsil-tareas:8000` y sabe vivir en `/tareas` (`APP_RUTA_BASE`).

## 1. DNS (Cloudflare)

`luiscontacto03.com` → DNS → Records → *Add record*: tipo `A`, nombre `spsil`,
IPv4 la del servidor, proxy en **DNS only** (nube gris).

## 2. Código y deploy key

```bash
ssh-keygen -t ed25519 -C "deploy-spsil" -f /root/.ssh/deploy_spsil -N ""
cat /root/.ssh/deploy_spsil.pub
#    -> GitHub: larceing/APP_TAREAS_SPSIL > Settings > Deploy keys > Add (sin "write access")

GIT_SSH_COMMAND="ssh -i /root/.ssh/deploy_spsil -o IdentitiesOnly=yes" \
  git clone git@github.com:larceing/APP_TAREAS_SPSIL.git /opt/apps/spsil-tareas
cd /opt/apps/spsil-tareas
git config core.sshCommand "ssh -i /root/.ssh/deploy_spsil -o IdentitiesOnly=yes"
```

## 3. Portada y Keycloak

Ver [plataforma/README.md](../plataforma/README.md): `docker compose up -d` en
`plataforma/`, y en Keycloak copiar el secreto de `app-tareas` y crear los usuarios.

## 4. Gestor de Tareas

Todos los secretos se generan **en el servidor** y no salen de él.

```bash
cd /opt/apps/spsil-tareas
cp .env.spsil.example .env
cp app_fastapi/.env.spsil.example app_fastapi/.env
#    .env: DB_PASSWORD, DB_ROOT_PASSWORD, INSTALAR_ADMIN_PASSWORD y SESSION_SECRET_KEY,
#          cada uno distinto, de:
openssl rand -hex 32
#    app_fastapi/.env: KEYCLOAK_CLIENT_SECRET (el de app-tareas en Keycloak)
chmod 600 .env app_fastapi/.env
docker compose up -d --build
docker compose logs -f app
```

Con `AUTH_MODO=sso` se entra siempre por Keycloak: los usuarios (y quién es de IT,
grupo `IT`) se gestionan allí, y cada persona aparece en la app la primera vez que
entra. Los usuarios de demostración (`admin`, `ana.lopez`, `carlos.ruiz`) existen
en la base pero no pueden entrar mientras el modo sea `sso`.

## 5. Nginx Proxy Manager

Hosts → Proxy Hosts → *Add Proxy Host*:
- Domain Names: `spsil.luiscontacto03.com`
- Scheme `http`, Forward Hostname `spsil-portal`, Forward Port `80`
- Activa *Block Common Exploits* y **Websockets Support** (el agente de stock lo usa)
- Pestaña SSL: *Request a new SSL Certificate*, *Force SSL*, *HTTP/2*
- Pestaña Advanced: `client_max_body_size 50m;`

`stock.luiscontacto03.com` puede seguir como está mientras el agente de SPSIL
apunte allí.

Abre `https://spsil.luiscontacto03.com`: sale la portada; Gestor de Tareas te
lleva a Keycloak y, una vez dentro, ya no vuelve a pedir contraseña en ninguna app.

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
