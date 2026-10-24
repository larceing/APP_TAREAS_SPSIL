#!/bin/sh
# Quién entra en el Gestor de Tareas de SPSIL (se puede repetir sin problema):
#   - grupo /Tareas con el subgrupo Admin, en la raíz del realm (son los de SPSIL;
#     /DEV/Tareas y /PRO/Tareas son de los entornos y no dan entrada aquí)
#   - "ruta completa" de los grupos en el cliente app-tareas: sin ella, alguien de
#     /DEV/Tareas llegaría como "Tareas" y entraría.
# Uso, en el servidor:
#   docker exec -i keycloak sh -s < plataforma/keycloak/espacio-tareas.sh
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

TID=""
GRUPOS=$($K get groups -r "$R" --fields id,name --format csv --noquotes)
while IFS=, read -r ID NOMBRE; do
  if [ "$NOMBRE" = "Tareas" ]; then TID="$ID"; fi
done <<FIN
$GRUPOS
FIN
if [ -n "$TID" ]; then echo "ya existe /Tareas"; else TID=$($K create groups -r "$R" -s name=Tareas -i); echo "creado /Tareas"; fi

HAY=""
LISTA=$($K get "groups/$TID/children" -r "$R" --fields name --format csv --noquotes)
while read -r NOMBRE; do [ "$NOMBRE" = "Admin" ] && HAY=1; done <<FIN
$LISTA
FIN
if [ -n "$HAY" ]; then echo "ya existe /Tareas/Admin"; else $K create "groups/$TID/children" -r "$R" -s name=Admin >/dev/null; echo "creado /Tareas/Admin"; fi

CID=$($K get clients -r "$R" -q clientId=app-tareas --fields id --format csv --noquotes)
[ -n "$CID" ] || { echo "no existe el cliente app-tareas"; exit 1; }
MAPPERS=$($K get "clients/$CID/protocol-mappers/models" -r "$R" --fields id,protocolMapper --format csv --noquotes)
while IFS=, read -r MID TIPO; do
  [ "$TIPO" = "oidc-group-membership-mapper" ] || continue
  $K update "clients/$CID/protocol-mappers/models/$MID" -r "$R" -s 'config."full.path"="true"'
  echo "app-tareas: grupos con ruta completa"
done <<FIN
$MAPPERS
FIN
