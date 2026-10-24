# Plataforma SPSIL

Lo común a todas las apps de `https://spsil.luiscontacto03.com`. Cada app sigue
siendo independiente (su repo, su carpeta, su base de datos, su `docker compose`);
aquí solo está lo que las une:

| Ruta | Qué es | Contenedor |
|---|---|---|
| `/` | Portada: elegir aplicación | `spsil-portal` (este compose) |
| `/tareas/` | Gestor de Tareas (este repo) | `spsil-tareas` |
| `/linai/` | Lin-AI, chat de IA (repo `spsil-proyecto`, carpeta `lin-ai`) | `spsil-linai` |
| `/paginas/` | Páginas, tablas tipo Power BI (sustituye a Stock; mismo contenedor) | `spsil-linai` |
| `/stock/` | Redirige a `/paginas/` (el Stock antiguo ya no existe) | — |
| `/auth/` | Keycloak: usuarios e inicio de sesión único | redirige a `users.luiscontacto03.com` → `keycloak:8080` (este compose) |

Nginx Proxy Manager tiene un proxy host para SPSIL, `spsil.luiscontacto03.com → spsil-portal:80`,
y otro para Keycloak, común a todo el servidor, `users.luiscontacto03.com → keycloak:8080`
(con SSL, y en *Advanced* `proxy_buffer_size 128k; proxy_buffers 4 256k;`). El portal (`portal/nginx.conf`) reparte por rutas. Todo va por la red Docker `proxy_default`.

## Arranque

```bash
cd /opt/apps/spsil-tareas/plataforma
cp .env.example .env && chmod 600 .env     # rellena con: openssl rand -hex 32
docker compose up -d
docker compose logs -f keycloak            # espera a "Keycloak ... started"
```

Keycloak usa ~600 MB de RAM (limitado a 512 MB de heap).

## Keycloak

La primera vez, entra en `https://users.luiscontacto03.com/auth/admin/` con `KEYCLOAK_ADMIN` /
`KEYCLOAK_ADMIN_PASSWORD` (el admin de arranque; Keycloak solo lo crea con la base vacía).
El realm **general** se crea solo la primera vez
(`keycloak/spsil-realm.json`) con:

- clientes `app-tareas`, `app-linai` y `app-stock` (con sus URLs de vuelta ya puestas) y
  `portal` (público: la portada pide la cuenta antes de enseñar las apps y solo
  enseña Lin-AI y Páginas a quien está en sus grupos o en `IT`);
- grupos `IT` (administración en todas las apps), `Tareas`, `Lin-AI` (chat de IA),
  `Lin-AI Editor` (además cambia las fichas de negocio), y `Stock`, `Stock Tabla`,
  `Stock Config` (dan acceso a Páginas; `Stock Config` además cambia las páginas).

Después:

1. **Secretos de los clientes**: Clients → `app-tareas` → Credentials → copia el
   *Client secret* al `app_fastapi/.env` de tareas (`KEYCLOAK_CLIENT_SECRET`), en el
   propio servidor. Igual con `app-linai` (`.env` de Lin-AI) y `app-stock`.
2. **Usuarios**: Users → Add user, y en *Credentials* una contraseña temporal. En
   *Groups*, los que le toquen.
3. **Cambiar el admin**: crea tu propio usuario administrador en el realm `master`
   (con 2FA) y borra el usuario de arranque. Antes, comprueba que el servidor tiene su
   cuenta de servicio (`KEYCLOAK_ADMIN_CLIENTE` y `KEYCLOAK_ADMIN_SECRETO` en
   `/opt/apps/servidor/servidor.env`): los scripts de `keycloak/` y las órdenes `kcadm` de
   abajo entran con ella a través de `keycloak/entrar.sh`. Con el usuario de arranque ya
   borrado, quita `KEYCLOAK_ADMIN_PASSWORD` del `.env` y aplica con
   `docker compose up -d keycloak`.

El realm solo se importa si aún no existe: los cambios hechos en la consola se
conservan entre reinicios. Por eso, en un realm creado antes de que el fichero
los trajera, hay dos ajustes que se ponen a mano una vez:

- **Aspecto SPSIL del login** (`keycloak/themes/spsil`): Realm settings → Themes →
  *Login theme* = `spsil`.
- **Login en la portada** (cliente público `portal`): con el realm ya creado,
  `bash keycloak/entrar.sh && docker compose exec -T keycloak sh -c '/opt/keycloak/bin/kcadm.sh create clients -r general -f -' < keycloak/cliente-portal.json`
- **Sesión larga** (no volver a pedir contraseña): Realm settings → Sessions →
  *SSO Session Idle/Max* = 30 días, y las de *Remember Me* = 90 días.
- **Lin-AI** (cliente `app-linai` y grupos `Lin-AI`, `Lin-AI Editor`): con el realm ya creado,
  `bash keycloak/entrar.sh && docker compose exec -T keycloak sh -c '/opt/keycloak/bin/kcadm.sh create clients -r general -f - && /opt/keycloak/bin/kcadm.sh create groups -r general -s name=Lin-AI && /opt/keycloak/bin/kcadm.sh create groups -r general -s "name=Lin-AI Editor"' < keycloak/cliente-linai.json`
  Si el cliente ya existía (antes de Páginas), para añadirle la vuelta de `/paginas`:
  `bash keycloak/entrar.sh && docker compose exec -T keycloak sh -c 'ID=$(/opt/keycloak/bin/kcadm.sh get clients -r general -q clientId=app-linai --fields id --format csv --noquotes) && /opt/keycloak/bin/kcadm.sh update clients/$ID -r general -f -' < keycloak/cliente-linai.json`
- **Espacio Stock / Páginas** (grupo `Stock` con `Admin`, un subgrupo por departamento
  —`Almacén`, `Compras`, `Cobros`, `Pedidos`, `Ventas`, `Pendientes`, `Logística`— y `Config`;
  grupos con ruta completa, `/Stock/Compras`, en `portal`, `app-stock` y `app-linai`):
  `bash keycloak/entrar.sh && docker compose exec -T keycloak sh -s < keycloak/espacio-stock.sh` (se puede repetir).
  `/Stock` entra en Páginas, `/Stock/<Departamento>` ve los informes de ese departamento,
  `/Stock/Admin` lo ve todo y cambia páginas, `/Stock/Config` cambia páginas. Los grupos
  sueltos de antes (`Stock Config`, `Informes`, `Informes Cobros`...) siguen valiendo.
- **Espacio Tareas** (grupo `Tareas` con `Admin` en la raíz, y grupos con ruta completa en
  `app-tareas`): `bash keycloak/entrar.sh && docker exec -i keycloak sh -s < keycloak/espacio-tareas.sh` (se puede repetir).
  Solo entran en el Gestor de Tareas de SPSIL `/Tareas`, sus subgrupos e `IT`
  (`KEYCLOAK_GRUPO_APP=Tareas` en `app_fastapi/.env`); `/DEV/Tareas` y `/PRO/Tareas` no. El
  portal tampoco enseña la tarjeta, y quien no tiene ninguna app ve "Sin acceso a SPSIL".
- **Dar acceso a alguien**: `bash keycloak/entrar.sh && docker exec -i keycloak bash -s USUARIO spsil < keycloak/dar-acceso.sh`
  lo mete en todo SPSIL (`/Tareas/Admin`, `/Lin-AI`, `Lin-AI Editor`, `/Stock/Admin`), sin ser IT.
  Con grupos sueltos: `... bash -s USUARIO /Tareas /Stock/Compras < ...`; para sacarlo:
  `... bash -s USUARIO quitar /Tareas < ...`.
