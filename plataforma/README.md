# Plataforma SPSIL

Lo común a todas las apps de `https://spsil.luiscontacto03.com`. Cada app sigue
siendo independiente (su repo, su carpeta, su base de datos, su `docker compose`);
aquí solo está lo que las une:

| Ruta | Qué es | Contenedor |
|---|---|---|
| `/` | Portada: elegir aplicación | `spsil-portal` (este compose) |
| `/tareas/` | Gestor de Tareas (este repo) | `spsil-tareas` |
| `/stock/` | Stock (repo `APP_DATA_SPSIL`) | `spsil-web` |
| `/auth/` | Keycloak: usuarios e inicio de sesión único | `spsil-keycloak` (este compose) |

Nginx Proxy Manager tiene **un solo** proxy host, `spsil.luiscontacto03.com → spsil-portal:80`,
y el portal (`portal/nginx.conf`) reparte por rutas. Todo va por la red Docker `proxy_default`.

## Arranque

```bash
cd /opt/apps/spsil-tareas/plataforma
cp .env.example .env && chmod 600 .env     # rellena con: openssl rand -hex 32
docker compose up -d
docker compose logs -f keycloak            # espera a "Keycloak ... started"
```

Keycloak usa ~600 MB de RAM (limitado a 512 MB de heap).

## Keycloak

Entra en `https://spsil.luiscontacto03.com/auth/admin/` con `KEYCLOAK_ADMIN` /
`KEYCLOAK_ADMIN_PASSWORD`. El realm **spsil** se crea solo la primera vez
(`keycloak/spsil-realm.json`) con:

- clientes `app-tareas` y `app-stock` (con sus URLs de vuelta ya puestas);
- grupos `IT` (administración en todas las apps), `Tareas`, `Stock`, `Stock Tabla`, `Stock Config`.

Después:

1. **Secretos de los clientes**: Clients → `app-tareas` → Credentials → copia el
   *Client secret* al `app_fastapi/.env` de tareas (`KEYCLOAK_CLIENT_SECRET`), en el
   propio servidor. Igual con `app-stock` para la app de stock.
2. **Usuarios**: Users → Add user, y en *Credentials* una contraseña temporal. En
   *Groups*, los que le toquen.
3. **Cambiar el admin**: crea tu propio usuario administrador en el realm `master`
   y borra el usuario de arranque.

El realm solo se importa si aún no existe: los cambios hechos en la consola se
conservan entre reinicios. Por eso, en un realm creado antes de que el fichero
los trajera, hay dos ajustes que se ponen a mano una vez:

- **Aspecto SPSIL del login** (`keycloak/themes/spsil`): Realm settings → Themes →
  *Login theme* = `spsil`.
- **Sesión larga** (no volver a pedir contraseña): Realm settings → Sessions →
  *SSO Session Idle/Max* = 30 días, y las de *Remember Me* = 90 días.
