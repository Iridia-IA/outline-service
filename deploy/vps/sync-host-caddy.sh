#!/usr/bin/env bash
# ============================================================================
# sync-host-caddy.sh — sincroniza los sites de Outline desde
# `host-caddy-outline.conf` (fuente de verdad, versionada) hacia el Caddyfile
# del HOST, que es el edge real de esta caja.
#
#   sudo /opt/services/outline-service/deploy/vps/sync-host-caddy.sh
#
# Por qué existe: `apply-host-caddy.sh` es APPEND-ONCE — sale sin hacer nada si
# los sites ya están. No hay forma de ACTUALIZAR un bloque ya aplicado, y
# `docker compose restart caddy` no aplica: este stack NO tiene servicio caddy.
#
# EDITAR SOLO EL .conf DEL REPO ES UN NO-OP SILENCIOSO EN PRODUCCIÓN. Eso es
# exactamente lo que le pasó al fix de CSP de Atlas el 2026-07-26. Todo cambio
# de edge tiene que pasar por este script.
#
# Reemplaza la región completa entre los marcadores OUTLINE-SITES-BEGIN/END.
# Backup → swap → validate → reload. Si validate falla, restaura y NO recarga.
# Idempotente: si la región ya coincide, no toca nada.
# ============================================================================
set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
SITES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host-caddy-outline.conf"
STAMP=$(date +%F-%H%M%S)
BACKUP="/etc/caddy/Caddyfile.bak-pre-outline-sync-$STAMP"
LOGS=(/var/log/caddy/outline.access.log /var/log/caddy/s3-outline.access.log)

[[ -f "$SITES" ]]     || { echo "ERROR: no existe $SITES" >&2; exit 1; }
[[ -f "$CADDYFILE" ]] || { echo "ERROR: no existe $CADDYFILE" >&2; exit 1; }

if ! grep -q 'OUTLINE-SITES-BEGIN' "$CADDYFILE"; then
	echo "ERROR: los sites de Outline no están aplicados todavía." >&2
	echo "       Correr primero:  sudo $(dirname "$SITES")/apply-host-caddy.sh" >&2
	exit 1
fi

echo "1) Backup → $BACKUP"
cp -a "$CADDYFILE" "$BACKUP"

echo "2) Swap de la región gestionada"
set +e
python3 - "$CADDYFILE" "$SITES" <<'PY'
import sys

caddyfile, sites = sys.argv[1], sys.argv[2]
BEGIN, END = "# >>> OUTLINE-SITES-BEGIN", "# <<< OUTLINE-SITES-END"

src = open(sites).read()
dst = open(caddyfile).read()

i = dst.find(BEGIN)
j = dst.find(END)
if i == -1 or j == -1 or j < i:
    sys.exit("ERROR: marcadores OUTLINE-SITES-BEGIN/END ausentes o desordenados")
j += len(END)

# El .conf del repo ya trae los marcadores; se inserta tal cual.
if not src.lstrip().startswith(BEGIN):
    sys.exit(f"ERROR: {sites} no empieza con {BEGIN}")

new_region = src.strip("\n")
if dst[i:j].strip("\n") == new_region:
    print("   Ya estaba sincronizado.")
    sys.exit(3)          # 3 = no-op, lo interpreta el wrapper

open(caddyfile, "w").write(dst[:i] + new_region + dst[j:])
print("   Región de Outline actualizada.")
PY
rc=$?
set -e

if [[ $rc -eq 3 ]]; then
	echo "→ Sin cambios. Borro el backup y salgo sin recargar."
	rm -f "$BACKUP"
	exit 0
fi
[[ $rc -eq 0 ]] || { echo "El swap falló → restaurando backup." >&2; cp -a "$BACKUP" "$CADDYFILE"; exit 1; }

echo "3) Validar la config combinada"
if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
	echo "VALIDATE FALLÓ → restaurando backup, sin recargar." >&2
	cp -a "$BACKUP" "$CADDYFILE"
	exit 1
fi

echo "4) chown de los access.log a caddy:caddy"
chown caddy:caddy "${LOGS[@]}" 2>/dev/null || true

echo "5) Reload graceful"
systemctl reload caddy
systemctl is-active caddy

echo
echo "OK. Backup en $BACKUP"
echo "Rollback:  cp $BACKUP $CADDYFILE && systemctl reload caddy"
