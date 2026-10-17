#!/usr/bin/env bash
# Gestor de Tareas de SPSIL por entornos (dev y pro) en el servidor común
# (larceing/servidor): va dentro de la app principal SPSIL, en
# <entorno>.<dominio>/spsil/tareas/. La ruta, la portada y los grupos los pone
# el servidor (servidor.json en la raíz del repositorio); esto solo arranca la
# app de cada entorno con su versión. Ver despliegue/DESPLIEGUE_SPSIL.md.
#
#   spsil-tareas.sh preparar IMAGEN DOMINIO [ENT]
#                                   primera vez (por defecto solo dev): carpeta,
#                                   secretos, usuario y base en la MariaDB
#                                   compartida y clave SSH para GitHub
#   spsil-tareas.sh desplegar ENT VERSION   pone esa versión (v1.2.0, sha-1a2b3c4...)
#   spsil-tareas.sh rollback ENT [VERSION]  vuelve a la versión buena anterior
#   spsil-tareas.sh keycloak-crear ENT      grupos /<ENT>/SPSIL/Tareas(/Admin), cliente
#                                   spsil-tareas-<ENT> y login con Keycloak
#   spsil-tareas.sh estado          qué versión tiene cada entorno
#   spsil-tareas.sh historial ENT   versiones desplegadas en ENT
#   spsil-tareas.sh logs ENT        log de la app de ENT
#   spsil-tareas.sh copia ENT       copia de la base de datos de ENT
#
# ENT = dev | pro. Todo vive junto a este script (p. ej. /opt/apps/spsil-tareas-entornos):
#   <ENT>/.env                secretos y versión actual (lo crea "preparar")
#   <ENT>/app.env             marca, ruta y login de ese entorno
#   <ENT>/docker-compose.yml  sacado de la imagen de la versión desplegada
#   <ENT>/historial.log       qué se desplegó y cuándo
#   copias/<ENT>/             copias de la BD (antes de cada despliegue en pro)
# La MariaDB es la compartida de los entornos (contenedor tareas-bd, red tareas_bd,
# su clave de root en BD_ENV). No se toca la instalación de SPSIL de antes.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTORNOS="dev pro"
PRINCIPAL=${PRINCIPAL:-spsil}          # ruta de la app principal en el servidor
GRUPO_PRINCIPAL=${GRUPO_PRINCIPAL:-SPSIL}
RUTA=tareas
BD_ENV=${BD_ENV:-/opt/apps/tareas/bd/.env}
BD_CONTENEDOR=${BD_CONTENEDOR:-tareas-bd}
ESPERA_SALUD=${ESPERA_SALUD:-300}
COPIAS_A_GUARDAR=${COPIAS_A_GUARDAR:-15}
VERSIONES_A_GUARDAR=${VERSIONES_A_GUARDAR:-4}
TOKEN="" TOKEN_USUARIO=""

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "· $*"; }
ahora() { date -u +%Y-%m-%dT%H:%M:%SZ; }

entorno_existe() {
  case " $ENTORNOS " in *" $1 "*) ;; *) die "entorno '$1' no válido (dev o pro)";; esac
}

entorno_valido() {
  entorno_existe "$1"
  [[ -f "$DIR/$1/.env" ]] || die "el entorno '$1' no está preparado (spsil-tareas.sh preparar IMAGEN DOMINIO $1)"
}

version_valida() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "versión no válida: '$1'"
}

# Lee una variable de un fichero .env sin ejecutarlo
var() { grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

poner_var() {   # poner_var FICHERO CLAVE VALOR
  local valor=${3//\\/\\\\}; valor=${valor//|/\\|}; valor=${valor//&/\\&}
  if grep -qE "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$valor|" "$1"
  else
    printf '%s=%s\n' "$2" "$3" >> "$1"
  fi
}

secreto() { openssl rand -hex 24; }

dc() {   # docker compose de un entorno
  local ent=$1; shift
  docker compose --project-directory "$DIR/$ent" -p "spsil-tareas-$ent" -f "$DIR/$ent/docker-compose.yml" "$@"
}

bd_sql() {   # SQL por stdin como root en la MariaDB compartida
  local clave; clave=$(var "$BD_ENV" MARIADB_ROOT_PASSWORD)
  [[ -n "$clave" ]] || die "no encuentro la clave de root de la MariaDB en $BD_ENV (BD_ENV=<fichero> delante)"
  docker exec -i -e MYSQL_PWD="$clave" "$BD_CONTENEDOR" mariadb -uroot "$@"
}

url_publica() { echo "https://$1.$(var "$DIR/$1/.env" DOMINIO)/$PRINCIPAL/$RUTA"; }

# ── preparar ─────────────────────────────────────────────────────────────────
cmd_preparar() {
  local imagen=${1:-} dominio=${2:-} ents=${3:-dev}
  [[ -n "$imagen" && -n "$dominio" ]] || die "uso: spsil-tareas.sh preparar IMAGEN DOMINIO [ENT]   (p. ej. preparar ghcr.io/larceing/app_tareas_spsil midominio.com)"
  imagen=${imagen,,}
  [[ "$dominio" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "dominio no válido: '$dominio'"
  command -v docker >/dev/null || die "falta Docker"
  command -v openssl >/dev/null || die "falta openssl"
  local red_proxy=${RED_PROXY:-proxy_default}
  docker network inspect "$red_proxy" >/dev/null 2>&1 || die "no existe la red Docker '$red_proxy' del proxy (RED_PROXY=<red> delante)"
  docker inspect "$BD_CONTENEDOR" >/dev/null 2>&1 || die "no encuentro la MariaDB compartida ($BD_CONTENEDOR)"
  umask 077

  local ent E u p n t
  for ent in $ents; do
    entorno_existe "$ent"
    E=${ent^^}
    mkdir -p "$DIR/$ent" "$DIR/copias/$ent"
    if [[ ! -f "$DIR/$ent/.env" ]]; then
      cat > "$DIR/$ent/.env" <<EOF
# SPSIL Tareas en $ent -- lo crea spsil-tareas.sh preparar. No lo copies fuera del servidor.
ENTORNO=$ent
DOMINIO=$dominio
IMAGEN=$imagen
VERSION=
RED_PROXY=$red_proxy
APP_MEMORIA=512m
DB_USER=spsil_tareas_$ent
DB_PASSWORD=$(secreto)
DB_NAME=app_tareas_spsil_$ent
DB_NAME_TEST=app_tareas_spsil_${ent}_test
INSTALAR_ADMIN=admin
INSTALAR_ADMIN_PASSWORD=$(secreto)
INSTALAR_DEMO=$([[ $ent == dev ]] && echo 1 || echo 0)
SESSION_SECRET_KEY=$(secreto)
EOF
      log "$ent/.env creado"
    else
      poner_var "$DIR/$ent/.env" IMAGEN "$imagen"
      poner_var "$DIR/$ent/.env" DOMINIO "$dominio"
    fi
    if [[ ! -f "$DIR/$ent/app.env" ]]; then
      local url; url=$(url_publica "$ent")
      cat > "$DIR/$ent/app.env" <<EOF
# SPSIL Tareas en $ent (ver app_fastapi/.env.spsil.example).
# Tras cambiarla: spsil-tareas.sh desplegar $ent <su versión actual>
APP_NOMBRE=Gestor de Tareas SPSIL$([[ $ent == dev ]] && echo " (DEV)")
APP_EMPRESA=SPSIL
APP_LOGO=/static/img/spsil-logo.webp
APP_TEMA_CSS=/static/css/tema-spsil.css
APP_URL_PORTAL=https://$ent.$dominio/$PRINCIPAL/
APP_RUTA_BASE=/$PRINCIPAL/$RUTA
APP_URL_PUBLICA=$url
# Hasta conectar Keycloak (spsil-tareas.sh keycloak-crear $ent): usuario local
AUTH_MODO=local
KEYCLOAK_GRUPO_APP=$E/$GRUPO_PRINCIPAL/Tareas
KEYCLOAK_GRUPO_ADMIN_GLOBAL=IT
MODULO_MANTIS=0
MODULO_NEXUS=0
MODULO_ESCRITORIO=0
MODULO_CONECTORES=0
EOF
    fi
    touch "$DIR/$ent/historial.log"

    # usuario de la BD de este entorno, solo con permisos sobre sus bases
    u=$(var "$DIR/$ent/.env" DB_USER); p=$(var "$DIR/$ent/.env" DB_PASSWORD)
    n=$(var "$DIR/$ent/.env" DB_NAME); t=$(var "$DIR/$ent/.env" DB_NAME_TEST)
    {
      echo "CREATE USER IF NOT EXISTS '$u'@'%' IDENTIFIED BY '$p';"
      echo "ALTER USER '$u'@'%' IDENTIFIED BY '$p';"
      echo "GRANT ALL PRIVILEGES ON \`$n\`.* TO '$u'@'%';"
      [[ -n "$t" ]] && echo "GRANT ALL PRIVILEGES ON \`$t\`.* TO '$u'@'%';"
      echo "FLUSH PRIVILEGES;"
    } | bd_sql
    log "$ent: usuario $u en la MariaDB compartida"
    chmod 600 "$DIR/$ent/.env" "$DIR/$ent/app.env"
  done

  preparar_clave_github
  chmod 700 "$DIR/spsil-tareas.sh" 2>/dev/null || true
  cat <<EOF

Listo. Para GitHub (repositorio > Settings > Secrets and variables > Actions):
  DEPLOY_HOST          la IP o el nombre de este servidor
  DEPLOY_KNOWN_HOSTS   lo que da: ssh-keyscan -t ed25519 <ese mismo host>
  DEPLOY_SSH_KEY       el contenido de $DIR/.ssh/github_despliegue
Después: spsil-tareas.sh keycloak-crear dev
EOF
}

preparar_clave_github() {
  local clave="$DIR/.ssh/github_despliegue" auth="$HOME/.ssh/authorized_keys"
  mkdir -p "$DIR/.ssh" "$HOME/.ssh"
  chmod 700 "$DIR/.ssh" "$HOME/.ssh"
  [[ -f "$clave" ]] || ssh-keygen -q -t ed25519 -N "" -C "github-despliegue-spsil-tareas" -f "$clave"
  # la clave de GitHub solo puede lanzar "spsil-tareas.sh ci" (nada de shell)
  local linea="command=\"$DIR/spsil-tareas.sh ci\",restrict $(cat "$clave.pub")"
  touch "$auth"; chmod 600 "$auth"
  grep -qF "$(cut -d' ' -f2 "$clave.pub")" "$auth" || echo "$linea" >> "$auth"
}

# ── desplegar ────────────────────────────────────────────────────────────────
traer_imagen() {   # traer_imagen IMAGEN:VERSION
  local ok=0
  if [[ -n "$TOKEN" ]]; then
    local cfg; cfg=$(mktemp -d)
    if printf '%s' "$TOKEN" | DOCKER_CONFIG=$cfg docker login ghcr.io -u "$TOKEN_USUARIO" --password-stdin >/dev/null 2>&1 \
       && DOCKER_CONFIG=$cfg timeout 300 docker pull -q "$1" >/dev/null 2>&1; then ok=1; fi
    rm -rf "$cfg"
  elif timeout 300 docker pull -q "$1" >/dev/null 2>&1; then
    ok=1
  fi
  if (( ! ok )); then
    docker image inspect "$1" >/dev/null 2>&1 \
      || die "no se puede descargar $1 (¿existe esa versión? si el paquete es privado: docker login ghcr.io)"
    log "uso la copia local de $1"
  fi
}

salud() {
  local id; id=$(dc "$1" ps -q app 2>/dev/null || true)
  [[ -n "$id" ]] || { echo parado; return; }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo parado
}

esperar_salud() {
  local ent=$1 t=0 s
  while (( t < ESPERA_SALUD )); do
    s=$(salud "$ent")
    case $s in
      healthy) return 0;;
      unhealthy|exited|dead|parado) (( t > 20 )) && return 1;;
    esac
    sleep 5; t=$((t + 5))
  done
  return 1
}

cmd_desplegar() {
  local ent=${1:-} version=${2:-} origen=${3:-manual}
  [[ -n "$ent" && -n "$version" ]] || die "uso: spsil-tareas.sh desplegar ENT VERSION"
  entorno_valido "$ent"
  [[ "$version" == anterior ]] && { cmd_rollback "$ent"; return; }
  version_valida "$version"

  exec 9>"$DIR/$ent/.lock"
  flock -w 600 9 || die "otro despliegue en $ent no termina"

  local env="$DIR/$ent/.env" imagen anterior
  imagen=$(var "$env" IMAGEN)
  anterior=$(var "$env" VERSION)
  log "$ent: $imagen:$version (ahora: ${anterior:-nada})"
  traer_imagen "$imagen:$version"

  # el compose va dentro de la imagen: cada versión trae el suyo
  local cid nuevo="$DIR/$ent/docker-compose.yml.nuevo"
  cid=$(docker create "$imagen:$version")
  if ! docker cp "$cid:/app/despliegue/servidor/docker-compose.yml" "$nuevo" 2>/dev/null; then
    [[ -f "$DIR/$ent/docker-compose.yml" ]] || { docker rm "$cid" >/dev/null; die "la imagen no trae despliegue/servidor/docker-compose.yml"; }
    cp "$DIR/$ent/docker-compose.yml" "$nuevo"
  fi
  docker rm "$cid" >/dev/null

  [[ "$ent" != dev && -n "$anterior" ]] && cmd_copia "$ent" "antes-de-$version"

  [[ -f "$DIR/$ent/docker-compose.yml" ]] && cp "$DIR/$ent/docker-compose.yml" "$DIR/$ent/docker-compose.yml.anterior"
  mv "$nuevo" "$DIR/$ent/docker-compose.yml"
  poner_var "$env" VERSION "$version"

  dc "$ent" up -d --remove-orphans
  log "esperando a que $ent responda..."
  if esperar_salud "$ent"; then
    printf '%s\t%s\tok\t%s\n' "$(ahora)" "$version" "$origen" >> "$DIR/$ent/historial.log"
    log "$ent ya está en $version"
    limpiar_imagenes "$imagen"
    return 0
  fi

  printf '%s\t%s\tfallo\t%s\n' "$(ahora)" "$version" "$origen" >> "$DIR/$ent/historial.log"
  echo "---- últimas líneas del log de $ent ----" >&2
  dc "$ent" logs --tail 40 app >&2 || true
  if [[ -n "$anterior" && "$anterior" != "$version" ]]; then
    echo "La versión $version no arranca: vuelvo a $anterior." >&2
    poner_var "$env" VERSION "$anterior"
    [[ -f "$DIR/$ent/docker-compose.yml.anterior" ]] && cp "$DIR/$ent/docker-compose.yml.anterior" "$DIR/$ent/docker-compose.yml"
    dc "$ent" up -d --remove-orphans
    if esperar_salud "$ent"; then
      printf '%s\t%s\tok\trollback-automatico\n' "$(ahora)" "$anterior" >> "$DIR/$ent/historial.log"
      echo "$ent sigue en $anterior." >&2
    else
      echo "Tampoco arranca $anterior: revisa spsil-tareas.sh logs $ent" >&2
    fi
  fi
  exit 1
}

version_anterior() {
  local ent=$1 actual; actual=$(var "$DIR/$ent/.env" VERSION)
  awk -F'\t' -v actual="$actual" '
    $3=="ok" { orden[++n]=$2; estado[$2]="ok" }
    $3=="revertida" || $3=="fallo" { estado[$2]="mala" }
    END { for (i=n; i>0; i--) { v=orden[i]; if (v!=actual && estado[v]=="ok") { print v; exit } } }
  ' "$DIR/$ent/historial.log"
}

cmd_rollback() {
  local ent=${1:-} version=${2:-}
  [[ -n "$ent" ]] || die "uso: spsil-tareas.sh rollback ENT [VERSION]"
  entorno_valido "$ent"
  local actual; actual=$(var "$DIR/$ent/.env" VERSION)
  [[ "$version" == anterior ]] && version=""
  [[ -n "$version" ]] || version=$(version_anterior "$ent")
  [[ -n "$version" ]] || die "no hay una versión anterior buena en el historial de $ent"
  log "rollback de $ent: $actual -> $version"
  cmd_desplegar "$ent" "$version" rollback
  if [[ -n "$actual" && "$actual" != "$version" ]]; then
    printf '%s\t%s\trevertida\t-> %s\n' "$(ahora)" "$actual" "$version" >> "$DIR/$ent/historial.log"
  fi
}

limpiar_imagenes() {
  local imagen=$1 guardar="" usadas="" ent tag
  for ent in $ENTORNOS; do
    [[ -f "$DIR/$ent/.env" ]] || continue
    guardar+=" $(var "$DIR/$ent/.env" VERSION)"
    usadas+=" $(cut -f2 "$DIR/$ent/historial.log" 2>/dev/null | tr '\n' ' ' || true)"
    guardar+=" $(awk -F'\t' '$3=="ok"{print $2}' "$DIR/$ent/historial.log" 2>/dev/null | tac | awk '!v[$0]++' | head -n "$VERSIONES_A_GUARDAR" | tr '\n' ' ' || true)"
  done
  for tag in $(docker images "$imagen" --format '{{.Tag}}'); do
    [[ "$tag" == "<none>" ]] && continue
    case " $usadas " in *" $tag "*) ;; *) continue;; esac
    case " $guardar " in *" $tag "*) ;; *) docker rmi "$imagen:$tag" >/dev/null 2>&1 || true;; esac
  done
}

redesplegar() {   # vuelve a arrancar ENT con su versión, para que lea la configuración
  local version; version=$(var "$DIR/$1/.env" VERSION)
  if [[ -n "$version" ]]; then
    cmd_desplegar "$1" "$version"
  else
    log "$1 aún no tiene versión: se aplicará en el primer despliegue"
  fi
}

# ── copias ───────────────────────────────────────────────────────────────────
cmd_copia() {
  local ent=${1:-} etiqueta=${2:-manual}
  [[ -n "$ent" ]] || die "uso: spsil-tareas.sh copia ENT"
  entorno_valido "$ent"
  mkdir -p "$DIR/copias/$ent"
  local n f; n=$(var "$DIR/$ent/.env" DB_NAME)
  f="$DIR/copias/$ent/$(date -u +%Y%m%d-%H%M%S)-$etiqueta.sql.gz"
  local clave; clave=$(var "$BD_ENV" MARIADB_ROOT_PASSWORD)
  [[ -n "$clave" ]] || die "no encuentro la clave de root de la MariaDB en $BD_ENV (BD_ENV=<fichero> delante)"
  if ! (umask 077; docker exec -e MYSQL_PWD="$clave" "$BD_CONTENEDOR" \
      mariadb-dump -uroot --single-transaction --routines --triggers "$n" | gzip > "$f"); then
    rm -f "$f"
    die "no pude copiar la base $n de $ent"
  fi
  log "copia de $ent: $f"
  ls -1t "$DIR/copias/$ent"/*.sql.gz 2>/dev/null | tail -n +$((COPIAS_A_GUARDAR + 1)) | xargs -r rm -f
}

# ── Keycloak ─────────────────────────────────────────────────────────────────
kc() { docker exec -i "${KC_CONTENEDOR:-keycloak}" /opt/keycloak/bin/kcadm.sh "$@"; }

kc_grupo() {   # kc_grupo REALM PADRE_ID|"" NOMBRE -> id (lo crea si no existe)
  local lista id
  if [[ -z "$2" ]]; then lista=groups; else lista=groups/$2/children; fi
  id=$(kc get "$lista" -r "$1" -q max=1000 --fields id,name --format csv --noquotes | awk -F, -v n="$3" '$2==n && !f {print $1; f=1}')
  [[ -n "$id" ]] || id=$(kc create "$lista" -r "$1" -s name="$3" -i)
  echo "$id"
}

cmd_keycloak_crear() {
  local ent=${1:-}
  [[ -n "$ent" ]] || die "uso: spsil-tareas.sh keycloak-crear ENT   (REALM=general y KC_URL=https://users.<dominio>/auth por defecto)"
  entorno_valido "$ent"
  local realm=${REALM:-general} kc_url=${KC_URL:-https://users.$(var "$DIR/$ent/.env" DOMINIO)/auth}
  [[ "$kc_url" =~ ^https?://[^[:space:]]+$ ]] || die "KC_URL no válida: '$kc_url'"
  docker inspect "${KC_CONTENEDOR:-keycloak}" >/dev/null 2>&1 || die "no encuentro el contenedor de Keycloak '${KC_CONTENEDOR:-keycloak}' (KC_CONTENEDOR=<nombre> delante)"
  docker exec "${KC_CONTENEDOR:-keycloak}" sh -c '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"' >/dev/null 2>&1 \
    || die "no puedo entrar en Keycloak con su admin"

  local E=${ent^^} g f="$DIR/$ent/app.env"
  g=$(kc_grupo "$realm" "" "$E"); g=$(kc_grupo "$realm" "$g" "$GRUPO_PRINCIPAL"); g=$(kc_grupo "$realm" "$g" Tareas)
  kc_grupo "$realm" "$g" Admin >/dev/null
  log "grupos /$E/$GRUPO_PRINCIPAL/Tareas y /$E/$GRUPO_PRINCIPAL/Tareas/Admin listos en el realm $realm"

  local cliente="spsil-tareas-$ent" url portal origen cid
  url=$(var "$f" APP_URL_PUBLICA); portal=$(var "$f" APP_URL_PORTAL)
  origen=$(echo "$url" | sed -E 's|^(https?://[^/]+).*|\1|')
  cid=$(kc get clients -r "$realm" -q clientId="$cliente" --fields id --format csv --noquotes)
  if [[ -z "$cid" ]]; then
    cid=$(kc create clients -r "$realm" -i -f - <<JSON
{"clientId":"$cliente","name":"Tareas SPSIL (${E})","enabled":true,"publicClient":false,
 "standardFlowEnabled":true,"directAccessGrantsEnabled":false,
 "redirectUris":["$url/login/sso/"],"webOrigins":["$origen"],
 "attributes":{"post.logout.redirect.uris":"${portal%/}/*##$url/*","login_theme":"spsil"},
 "protocolMappers":[{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper",
  "config":{"claim.name":"groups","full.path":"true","userinfo.token.claim":"true","id.token.claim":"true","access.token.claim":"true"}}]}
JSON
)
    log "cliente $cliente creado"
  else
    log "el cliente $cliente ya existía"
  fi
  local secreto_kc
  secreto_kc=$(kc get "clients/$cid/client-secret" -r "$realm" --fields value --format csv --noquotes)
  [[ "$secreto_kc" =~ ^[A-Za-z0-9._~-]+$ ]] || die "no pude leer el client secret de $cliente"
  poner_var "$f" AUTH_MODO sso
  poner_var "$f" KEYCLOAK_ISSUER "$kc_url/realms/$realm"
  poner_var "$f" KEYCLOAK_CLIENT_ID "$cliente"
  poner_var "$f" KEYCLOAK_CLIENT_SECRET "$secreto_kc"
  poner_var "$f" SSO_URL_SALIDA "$portal"
  chmod 600 "$f"
  log "$ent: login con Keycloak ($cliente), vuelta en $url/login/sso/"
  redesplegar "$ent"
}

# ── consultas ────────────────────────────────────────────────────────────────
cmd_estado() {
  local ent
  for ent in $ENTORNOS; do
    [[ -f "$DIR/$ent/.env" ]] || { printf '%-4s sin preparar\n' "$ent"; continue; }
    printf '%-4s %-16s %s\n' "$ent" "$(var "$DIR/$ent/.env" VERSION)" "$(salud "$ent")"
  done
}

cmd_historial() { entorno_valido "${1:-}"; tail -n "${2:-20}" "$DIR/$1/historial.log"; }
cmd_logs() { entorno_valido "${1:-}"; dc "$1" logs --tail 200 -f app; }

# GitHub entra por SSH con una clave que solo puede ejecutar esto; la orden
# llega en SSH_ORIGINAL_COMMAND y, por la entrada, "usuario token" para ghcr.io
cmd_ci() {
  local orden
  read -r -a orden <<< "${SSH_ORIGINAL_COMMAND:-}"
  if read -r -t 10 TOKEN_USUARIO TOKEN; then :; fi
  case "${orden[0]:-}" in
    desplegar) cmd_desplegar "${orden[1]:-}" "${orden[2]:-}" github ;;
    rollback)  cmd_rollback "${orden[1]:-}" "${orden[2]:-}" ;;
    estado)    cmd_estado ;;
    historial) cmd_historial "${orden[1]:-}" ;;
    *) die "orden no permitida: ${orden[0]:-(vacía)}" ;;
  esac
}

uso() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  preparar)    shift; cmd_preparar "$@" ;;
  desplegar)   shift; cmd_desplegar "$@" ;;
  rollback)    shift; cmd_rollback "$@" ;;
  keycloak-crear) shift; cmd_keycloak_crear "$@" ;;
  estado)      cmd_estado ;;
  historial)   shift; cmd_historial "$@" ;;
  logs)        shift; cmd_logs "$@" ;;
  copia)       shift; cmd_copia "$@" ;;
  ci)          cmd_ci ;;
  *)           uso; exit 1 ;;
esac
