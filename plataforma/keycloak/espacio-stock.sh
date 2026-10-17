#!/bin/sh
# Espacio de la app Stock / Páginas en un realm ya creado (se puede repetir sin problema):
#   - grupo Stock con sus subgrupos (Admin, un departamento por sección de informes, Config)
#   - "ruta completa" de los grupos (/Stock/Compras) en los clientes portal, app-stock y app-linai
# Uso, desde la carpeta plataforma:
#   docker compose exec -T keycloak sh -s < keycloak/espacio-stock.sh
# Solo usa órdenes de la propia shell: la imagen de Keycloak no trae grep, awk ni sed.
set -e
K=/opt/keycloak/bin/kcadm.sh
$K config credentials --server http://localhost:8080/auth --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"

SID=""
GRUPOS=$($K get groups -r spsil --fields id,name --format csv --noquotes)
while IFS=, read -r ID NOMBRE; do
  if [ "$NOMBRE" = "Stock" ]; then SID="$ID"; fi
done <<FIN
$GRUPOS
FIN
[ -n "$SID" ] || SID=$($K create groups -r spsil -s name=Stock -i)

HIJOS=" "
LISTA=$($K get "groups/$SID/children" -r spsil --fields name --format csv --noquotes)
while read -r NOMBRE; do HIJOS="$HIJOS$NOMBRE "; done <<FIN
$LISTA
FIN
for N in Admin Almacén Compras Cobros Pedidos Ventas Pendientes Logística Config; do
  case "$HIJOS" in
    *" $N "*) echo "ya existe /Stock/$N" ;;
    *) $K create "groups/$SID/children" -r spsil -s "name=$N" >/dev/null && echo "creado /Stock/$N" ;;
  esac
done

for C in portal app-stock app-linai; do
  CID=$($K get clients -r spsil -q clientId=$C --fields id --format csv --noquotes)
  [ -n "$CID" ] || { echo "no existe el cliente $C"; continue; }
  MAPPERS=$($K get "clients/$CID/protocol-mappers/models" -r spsil --fields id,protocolMapper --format csv --noquotes)
  while IFS=, read -r MID TIPO; do
    [ "$TIPO" = "oidc-group-membership-mapper" ] || continue
    $K update "clients/$CID/protocol-mappers/models/$MID" -r spsil -s 'config."full.path"="true"'
    echo "$C: grupos con ruta completa"
  done <<FIN
$MAPPERS
FIN
done
