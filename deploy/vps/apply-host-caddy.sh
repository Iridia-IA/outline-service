#!/usr/bin/env bash
# ============================================================================
# apply-host-caddy.sh — fusiona los sites de Outline al Caddyfile del HOST,
# de forma segura y reversible. Correr con sudo.
#
#   sudo /opt/services/outline-service/deploy/vps/apply-host-caddy.sh
#
# Backup → append → validate. SOLO recarga si validate pasa. Si algo falla,
# restaura el backup y NO recarga (los 7 sites existentes nunca se cortan).
#
# APPEND-ONCE: si los sites ya están, sale sin hacer nada. Para ACTUALIZAR
# bloques ya aplicados usar sync-host-caddy.sh.
# ============================================================================
set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
SITES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host-caddy-outline.conf"
STAMP=$(date +%F-%H%M%S)
BACKUP="/etc/caddy/Caddyfile.bak-pre-outline-$STAMP"
LOGS=(/var/log/caddy/outline.access.log /var/log/caddy/s3-outline.access.log)

[[ -f "$SITES" ]]     || { echo "ERROR: no existe $SITES" >&2; exit 1; }
[[ -f "$CADDYFILE" ]] || { echo "ERROR: no existe $CADDYFILE" >&2; exit 1; }

if grep -q 'OUTLINE-SITES-BEGIN' "$CADDYFILE"; then
	echo "Los sites de Outline ya están en $CADDYFILE — nada que hacer."
	echo "Para actualizarlos:  sudo $(dirname "$SITES")/sync-host-caddy.sh"
	exit 0
fi

echo "1) Backup → $BACKUP"
cp -a "$CADDYFILE" "$BACKUP"

echo "2) Append de los 2 sites de Outline (outline.iridia.cloud, s3.iridia.cloud)"
{ printf '\n'; cat "$SITES"; } >> "$CADDYFILE"

echo "3) Validar la config combinada"
if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
	echo "VALIDATE FALLÓ → restaurando backup, sin recargar." >&2
	cp -a "$BACKUP" "$CADDYFILE"
	exit 1
fi

echo "4) chown de los logs nuevos a caddy:caddy"
# El `caddy validate` de arriba corre como root y crea los access.log root-owned;
# el proceso caddy corre como user `caddy` y no podría abrirlos → el reload falla.
# Esto ya causó ~2 min de downtime en el switch a Caddy del 2026-07-22.
chown caddy:caddy "${LOGS[@]}" 2>/dev/null || true

echo "5) Reload graceful (si falla en runtime, Caddy conserva la config vieja)"
systemctl reload caddy
systemctl is-active caddy

echo
echo "OK — sites de Outline activos. Backup en $BACKUP"
echo "Rollback:  cp $BACKUP $CADDYFILE && systemctl reload caddy"
echo
echo "Verificar (los certs pueden tardar unos segundos en emitirse):"
echo "  journalctl -u caddy -f | grep -i 'outline\\|s3'"
echo "  curl -s https://outline.iridia.cloud/_health"
echo "  curl -sI https://s3.iridia.cloud/minio/     # debe dar 404"
