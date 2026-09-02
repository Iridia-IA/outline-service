#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# gen-secrets.sh — genera los secretos de Outline en deploy/vps/.env
#
# IDEMPOTENTE: solo completa claves AUSENTES o VACÍAS. Los valores no vacíos
# quedan intactos — re-correrlo nunca rota un secreto vivo por accidente.
# Crea .env desde .env.example en la primera corrida y lo deja en 0600.
#
# Genera:
#   SECRET_KEY                   openssl rand -hex 32  (64 hex, validado por Outline)
#   UTILS_SECRET                 openssl rand -hex 32
#   OUTLINE_POSTGRES_PASSWORD    openssl rand -hex 24  (hex → sin escaping en el DSN)
#   OUTLINE_REDIS_PASSWORD       openssl rand -hex 24
#   OUTLINE_MINIO_ROOT_PASSWORD  openssl rand -hex 24
#
# ⚠️  SECRET_KEY es irrecuperable. Si se pierde, todo el contenido cifrado de la
#     base queda inaccesible. Copiarlo a Vault y al gestor personal.
#
# Uso:  ./scripts/gen-secrets.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$VPS_DIR/.env"
EXAMPLE_FILE="$VPS_DIR/.env.example"

if [[ ! -f "$ENV_FILE" ]]; then
	[[ -f "$EXAMPLE_FILE" ]] || { echo "ERROR: no hay .env ni .env.example en $VPS_DIR" >&2; exit 1; }
	echo "[gen-secrets] .env no existe — creándolo desde .env.example"
	cp "$EXAMPLE_FILE" "$ENV_FILE"
fi

# Cerrarlo ANTES de escribir cualquier secreto adentro.
chmod 600 "$ENV_FILE"

gen_hex32() { openssl rand -hex 32; }
gen_pw()    { openssl rand -hex 24; }

# Valor actual de una clave en .env (vacío si falta o está en blanco).
current_value() {
	grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

# Setea una clave SOLO si está ausente o vacía.
ensure_secret() {
	local key="$1" value="$2"
	if [[ -n "$(current_value "$key")" ]]; then
		echo "[gen-secrets] $key ya seteada — no se toca"
		return 0
	fi
	if grep -qE "^${key}=" "$ENV_FILE"; then
		# Existe pero vacía → reemplazo en el lugar. El valor se pasa por
		# environment y no por argv, así nunca aparece en la tabla de procesos.
		local tmp; tmp="$(mktemp)"
		VALUE="$value" awk -v key="$key" '
			$0 ~ "^" key "=" && !done { print key "=" ENVIRON["VALUE"]; done=1; next }
			{ print }
		' "$ENV_FILE" >"$tmp"
		cat "$tmp" >"$ENV_FILE"
		rm -f "$tmp"
	else
		printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
	fi
	echo "[gen-secrets] $key generada"
}

echo "[gen-secrets] destino: $ENV_FILE"
ensure_secret SECRET_KEY                  "$(gen_hex32)"
ensure_secret UTILS_SECRET                "$(gen_hex32)"
ensure_secret OUTLINE_POSTGRES_PASSWORD   "$(gen_pw)"
ensure_secret OUTLINE_REDIS_PASSWORD      "$(gen_pw)"
ensure_secret OUTLINE_MINIO_ROOT_PASSWORD "$(gen_pw)"

chmod 600 "$ENV_FILE"

echo
echo "[gen-secrets] listo. .env en 0600."
echo "  Falta completar a mano:  GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET,"
echo "                           SMTP_PASSWORD (API key de Resend), SMTP_FROM_EMAIL"
echo "  Y guardar SECRET_KEY en Vault + gestor personal — su pérdida es irreversible."
