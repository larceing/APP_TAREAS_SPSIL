#!/usr/bin/env bash
# Deja kcadm con sesión de administrador dentro del contenedor de Keycloak, para que los
# scripts de esta carpeta (y las órdenes kcadm del README) puedan trabajar.
# Entra con la cuenta de servicio del servidor (KEYCLOAK_ADMIN_CLIENTE y
# KEYCLOAK_ADMIN_SECRETO de /opt/apps/servidor/servidor.env), la misma que usa el agente:
# no le afecta el 2FA de los usuarios administradores. Si no está, prueba el admin de
# arranque del contenedor (KC_BOOTSTRAP_ADMIN_*), mientras exista.
# Uso, en el servidor, como root:  bash plataforma/keycloak/entrar.sh
# Variables opcionales: KC_CONTENEDOR (keycloak) y SERVIDOR_ENV (la ruta de servidor.env).
set -euo pipefail
KC=${KC_CONTENEDOR:-keycloak}
ENV_SERVIDOR=${SERVIDOR_ENV:-/opt/apps/servidor/servidor.env}
BASE='/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master'

valor() { grep -E "^$1=" "$ENV_SERVIDOR" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

C=$(valor KEYCLOAK_ADMIN_CLIENTE)
S=$(valor KEYCLOAK_ADMIN_SECRETO)
if [[ -n "$C" && -n "$S" ]]; then
  [[ "$C" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "KEYCLOAK_ADMIN_CLIENTE no válido: '$C'" >&2; exit 1; }
  # El secreto va por la entrada, no en la línea de órdenes.
  printf '%s\n' "$S" | docker exec -i "$KC" sh -c "read -r S; $BASE --client $C --secret \"\$S\"" >/dev/null 2>&1 \
    || { echo "no se pudo entrar en Keycloak con la cuenta de servicio $C" >&2; exit 1; }
  echo "Keycloak: kcadm entra con la cuenta de servicio $C"
else
  docker exec "$KC" sh -c "$BASE --user \"\$KC_BOOTSTRAP_ADMIN_USERNAME\" --password \"\$KC_BOOTSTRAP_ADMIN_PASSWORD\"" >/dev/null 2>&1 \
    || { echo "no se pudo entrar en Keycloak: no hay cuenta de servicio en $ENV_SERVIDOR y el admin de arranque no vale" >&2; exit 1; }
  echo "Keycloak: kcadm entra con el admin de arranque (no hay cuenta de servicio en $ENV_SERVIDOR)"
fi
