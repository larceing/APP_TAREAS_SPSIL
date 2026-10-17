#!/usr/bin/env bash
# Mueve Keycloak a su propia dirección (users.luiscontacto03.com/auth),
# renombra el realm "spsil" a "general" y lo deja con el nombre "keycloak"
# en la red del proxy. Los usuarios, grupos y contraseñas no se tocan.
# Ejecutar como root en el servidor:  bash migrar-a-users.sh
set -euo pipefail
REPO=/opt/apps/spsil-tareas
RAMA=claude/project-thread-cjl9yt
NUEVA=https://users.luiscontacto03.com/auth
cd "$REPO/plataforma"
kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
paso() { printf '\n== %s\n' "$*"; }

paso "1. Comprobaciones"
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] \
  || { echo "Hay cambios sin guardar en $REPO, no sigo:"; git -C "$REPO" status --short --untracked-files=no; exit 1; }
NUESTRO=$(docker compose ps -q keycloak)
[ -n "$NUESTRO" ] || { echo "El Keycloak de la plataforma no está arrancado, no sigo"; exit 1; }
for c in $(docker ps -aq); do
  [[ "$NUESTRO" == "$c"* || "$c" == "$NUESTRO"* ]] && continue
  n=$(docker inspect -f '{{.Name}} {{with index .NetworkSettings.Networks "proxy_default"}}{{range .Aliases}}{{.}} {{end}}{{end}}' "$c")
  case " $n " in *" /keycloak "*|*" keycloak "*) echo "Ya hay otro contenedor que se llama keycloak: $n. No sigo."; exit 1;; esac
done
echo "ok"

paso "2. Contenedores que usan la dirección antigua (se reiniciarán al final)"
AFECTADOS=()
for c in $(docker ps -q); do
  [[ "$NUESTRO" == "$c"* || "$c" == "$NUESTRO"* ]] && continue
  if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" \
     | grep -E 'spsil\.luiscontacto03\.com/auth|/realms/spsil|spsil-keycloak|REALM[A-Z_]*=spsil$' >/dev/null; then
    AFECTADOS+=("$c"); docker inspect -f '  {{.Name}}' "$c"
  fi
done
[ ${#AFECTADOS[@]} -gt 0 ] || echo "  (ninguno)"

paso "3. Código nuevo de la plataforma"
ANTES=$(git -C "$REPO" rev-parse --short HEAD)
git -C "$REPO" fetch -q origin "$RAMA"
git -C "$REPO" merge --ff-only -q FETCH_HEAD
echo "de $ANTES a $(git -C "$REPO" rev-parse --short HEAD)"

paso "4. Realm spsil -> general, login SPSIL solo en los clientes de SPSIL"
docker compose exec -T keycloak sh -c '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"'
if kc get realms/general --fields realm >/dev/null 2>&1; then
  echo "el realm general ya existe"
else
  kc update realms/spsil -s realm=general
  echo "realm renombrado"
fi
kc update realms/general -s displayName=Acceso -s displayNameHtml=Acceso -s loginTheme=keycloak
for C in portal app-tareas app-stock app-linai; do
  ID=$(kc get clients -r general -q clientId=$C --fields id --format csv --noquotes | tr -d '\r')
  if [ -n "$ID" ]; then kc update clients/$ID -r general -s 'attributes."login_theme"=spsil'; echo "  $C: login SPSIL"
  else echo "  $C: no existe, se salta"; fi
done

paso "5. Keycloak y portal con la configuración nueva"
docker compose up -d
docker compose restart portal >/dev/null
printf "esperando a Keycloak"
for i in $(seq 1 60); do
  if docker compose exec -T portal wget -qO- http://keycloak:8080/auth/realms/general/.well-known/openid-configuration 2>/dev/null | grep -F "\"issuer\":\"$NUEVA/realms/general\"" >/dev/null; then
    echo " ok"; break
  fi
  printf "."; sleep 3
  [ "$i" = 60 ] && { echo; echo "Keycloak no responde. Mira: docker compose logs --tail 50 keycloak"; exit 1; }
done

paso "6. Ficheros .env de las apps"
CAMBIADOS=()
while IFS= read -r f; do
  if grep -Eq 'spsil\.luiscontacto03\.com/auth|/realms/spsil|spsil-keycloak|REALM[A-Z_]*=["'"'"']?spsil["'"'"']?$' "$f"; then
    [ -e "$f.antes-users" ] || cp -p "$f" "$f.antes-users"
    sed -i -E \
      -e 's#https://spsil\.luiscontacto03\.com/auth#'"$NUEVA"'#g' \
      -e 's#/realms/spsil([^A-Za-z0-9_-]|$)#/realms/general\1#g' \
      -e 's#spsil-keycloak:8080#keycloak:8080#g' \
      -e 's#^([A-Z_]*REALM[A-Z_]*=)(["'"'"']?)spsil(["'"'"']?)$#\1\2general\3#' "$f"
    CAMBIADOS+=("$f"); echo "  $f"
    diff "$f.antes-users" "$f" | sed -n 's/^[<>] /    /p' | sed -E 's/(SECRET|PASSWORD|CLAVE|KEY)([A-Z_]*)=.*/\1\2=***/' || true
  fi
done < <(find /opt/apps -maxdepth 5 \( -name .env -o -name '*.env' \) -type f -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
[ ${#CAMBIADOS[@]} -gt 0 ] || echo "  (ninguno)"

paso "7. Reiniciar las apps afectadas"
for c in "${AFECTADOS[@]}"; do
  P=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null || true)
  S=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$c" 2>/dev/null || true)
  W=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null || true)
  F=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$c" 2>/dev/null || true)
  if [ -z "$P" ] || [ -z "$S" ]; then echo "  $c no es de docker compose: reinícialo a mano"; continue; fi
  ARGS=(-p "$P" --project-directory "$W")
  IFS=, read -ra FS <<<"$F"; for x in "${FS[@]}"; do ARGS+=(-f "$x"); done
  echo "  $P / $S"
  docker compose "${ARGS[@]}" up -d --no-deps --force-recreate "$S"
done

paso "8. Comprobación final"
QUEDAN=0
for c in $(docker ps -q); do
  if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -E 'spsil\.luiscontacto03\.com/auth|/realms/spsil|spsil-keycloak' >/dev/null; then
    docker inspect -f '  todavía con la dirección antigua: {{.Name}}' "$c"; QUEDAN=1
  fi
done
grep -rlE 'spsil-keycloak|/realms/spsil' /opt/apps --include='*.conf' --include='*.yml' --include='*.yaml' 2>/dev/null \
  | grep -v '/.git/' | sed 's/^/  menciona la dirección antigua: /' || true
[ "$QUEDAN" = 0 ] && echo "  ninguna app usa ya la dirección antigua"
echo
echo "LISTO. Último paso en Nginx Proxy Manager: el proxy host users.luiscontacto03.com"
echo "debe apuntar a  http  keycloak  8080."
echo "Para volver atrás: cp cada FICHERO.antes-users a FICHERO, git -C $REPO reset --hard $ANTES,"
echo "y en Keycloak renombrar el realm general a spsil."
