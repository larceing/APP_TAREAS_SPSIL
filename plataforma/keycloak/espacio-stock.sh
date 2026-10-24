#!/bin/sh
# Espacio de la app Stock / Páginas en un realm ya creado (se puede repetir sin problema):
#   - grupo Stock con sus subgrupos (Admin, un departamento por sección de informes, Config)
#   - "ruta completa" de los grupos (/Stock/Compras) en los clientes portal, app-stock y app-linai
# Uso, desde la carpeta plataforma:
#   docker compose exec -T keycloak sh -s < keycloak/espacio-stock.sh
# Solo usa órdenes de la propia shell: la imagen de Keycloak no trae grep, awk ni sed.
set -e
R=${REALM:-general}
K=/opt/keycloak/bin/kcadm.sh
# Sesión de administrador: la deja antes plataforma/keycloak/entrar.sh (la cuenta de
# servicio del servidor). Si no hay, prueba el admin de arranque, mientras exista.
$K get realms/master --fields realm >/dev/null 2>&1 \
  || $K config credentials --server http://localhost:8080/auth --realm master \
       --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1 \
  || { echo "no se pudo entrar en Keycloak: ejecuta antes, en el servidor, bash plataforma/keycloak/entrar.sh"; exit 1; }

SID=""
GRUPOS=$($K get groups -r "$R" --fields id,name --format csv --noquotes)
while IFS=, read -r ID NOMBRE; do
  if [ "$NOMBRE" = "Stock" ]; then SID="$ID"; fi
done <<FIN
$GRUPOS
FIN
[ -n "$SID" ] || SID=$($K create groups -r "$R" -s name=Stock -i)

HIJOS=" "
LISTA=$($K get "groups/$SID/children" -r "$R" --fields name --format csv --noquotes)
while read -r NOMBRE; do HIJOS="$HIJOS$NOMBRE "; done <<FIN
$LISTA
FIN
for N in Admin Almacén Compras Cobros Pedidos Ventas Pendientes Logística Config; do
  case "$HIJOS" in
    *" $N "*) echo "ya existe /Stock/$N" ;;
    *) $K create "groups/$SID/children" -r "$R" -s "name=$N" >/dev/null && echo "creado /Stock/$N" ;;
  esac
done

for C in portal app-stock app-linai; do
  CID=$($K get clients -r "$R" -q clientId=$C --fields id --format csv --noquotes)
  [ -n "$CID" ] || { echo "no existe el cliente $C"; continue; }
  MAPPERS=$($K get "clients/$CID/protocol-mappers/models" -r "$R" --fields id,protocolMapper --format csv --noquotes)
  while IFS=, read -r MID TIPO; do
    [ "$TIPO" = "oidc-group-membership-mapper" ] || continue
    $K update "clients/$CID/protocol-mappers/models/$MID" -r "$R" -s 'config."full.path"="true"'
    echo "$C: grupos con ruta completa"
  done <<FIN
$MAPPERS
FIN
done
