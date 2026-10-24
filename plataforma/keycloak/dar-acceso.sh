#!/bin/bash
# Mete a una persona en grupos del realm (se puede repetir sin problema).
# Uso, en el servidor (desde /opt/apps/spsil-tareas):
#   docker exec -i keycloak bash -s USUARIO GRUPO... < plataforma/keycloak/dar-acceso.sh
#   docker exec -i keycloak bash -s USUARIO spsil    < ...   todo SPSIL (sin ser IT)
#   docker exec -i keycloak bash -s USUARIO quitar GRUPO... < ...   la saca de esos grupos
# GRUPO es la ruta: /Tareas, /Tareas/Admin, /Lin-AI, /Stock/Compras...
# Solo usa órdenes de la propia shell: la imagen de Keycloak no trae grep, awk ni sed.
R=${REALM:-general}
K=/opt/keycloak/bin/kcadm.sh
U=${1:?falta el usuario}; shift
ACCION=entrar
[ "${1:-}" = quitar ] && { ACCION=quitar; shift; }
[ "${1:-}" = spsil ] && { shift; set -- /Tareas/Admin /Lin-AI "/Lin-AI Editor" /Stock/Admin "$@"; }
[ $# -gt 0 ] || { echo "faltan los grupos (o «spsil»)"; exit 1; }
# Sesión de administrador: la deja antes plataforma/keycloak/entrar.sh (la cuenta de
# servicio del servidor). Si no hay, prueba el admin de arranque, mientras exista.
$K get realms/master --fields realm >/dev/null 2>&1 \
  || $K config credentials --server http://localhost:8080/auth --realm master \
       --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1 \
  || { echo "no se pudo entrar en Keycloak: ejecuta antes, en el servidor, bash plataforma/keycloak/entrar.sh"; exit 1; }
UID_=$($K get users -r "$R" -q username="$U" -q exact=true --fields id --format csv --noquotes)
[ -n "$UID_" ] || { echo "no existe el usuario $U en el realm $R"; exit 1; }
for G in "$@"; do
  G="/${G#/}"
  GID=$($K get "group-by-path${G// /%20}" -r "$R" --fields id --format csv --noquotes 2>/dev/null)
  if [ -z "$GID" ]; then echo "no existe el grupo $G (saltado)"; continue; fi
  if [ "$ACCION" = quitar ]; then
    $K delete "users/$UID_/groups/$GID" -r "$R" && echo "$U fuera de $G"
  else
    $K update "users/$UID_/groups/$GID" -r "$R" -s realm="$R" -s userId="$UID_" -s groupId="$GID" -n && echo "$U en $G"
  fi
done
echo "Grupos de $U ahora:"
$K get "users/$UID_/groups" -r "$R" --fields path --format csv --noquotes
