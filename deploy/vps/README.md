# Outline en la VPS iridia.cloud — Docker Compose + Caddy del host

> ### ⚠️ Este stack NO tiene servicio `caddy`.
>
> `iridia.cloud` es una VPS **compartida** cuyo **Caddy del host** (nativo + systemd, ACME propia)
> ya es dueño de 80/443 para 7 sitios. Los dos upstreams de Outline publican **solo en loopback**
> (`127.0.0.1:3300` app, `127.0.0.1:9100` MinIO) y el Caddy del host les hace reverse-proxy.
>
> | Tarea | Cómo |
> |---|---|
> | Primera instalación del edge | `sudo ./apply-host-caddy.sh` (append-once) |
> | Cambiar algo del edge | **`sudo ./sync-host-caddy.sh`** |
> | Logs del edge | `journalctl -u caddy` · `/var/log/caddy/outline.access.log` · `/var/log/caddy/s3-outline.access.log` |
> | Rollback | `cp /etc/caddy/Caddyfile.bak-pre-outline-<stamp> /etc/caddy/Caddyfile && systemctl reload caddy` |
>
> **Editar solo `host-caddy-outline.conf` es un no-op silencioso en producción.** Eso es
> exactamente lo que le pasó al fix de CSP de Atlas el 2026-07-26. Todo cambio de edge pasa
> por `sync-host-caddy.sh`.

---

## Topología

```
                        Internet
                           │  :80 / :443   (Caddy del HOST — no de este stack)
                  ┌────────▼─────────┐
                  │  Caddy (systemd) │  TLS automático, security headers, reset de XFF
                  └───┬──────────┬───┘
   outline.iridia.cloud│          │s3.iridia.cloud
              127.0.0.1:3300   127.0.0.1:9100
                     │              │
              ┌──────▼──────┐  ┌────▼────────┐
              │ outline-app │  │outline-minio│  (consola :9101 — solo túnel SSH)
              └──┬───────┬──┘  └─────┬───────┘
   [outline-data]│       │ [outline-edge: egress]│
        ┌────────▼──┐ ┌──▼──────────┐           │
        │  postgres │ │    redis    │           │
        └───────────┘ └─────────────┘           │
        (sin puertos, sin salida a internet)  (publica :9100)
```

- **`outline-data`** (`internal: true`, sin egress) — postgres, redis, minio, app.
- **`outline-edge`** (bridge, con egress) — app (Google OAuth, Resend, embeds) y minio.
  MinIO está en las dos porque un contenedor en red `internal` no puede publicar puertos.

---

## Prerrequisitos

- Docker + plugin compose (ya instalados en la caja).
- **DNS**: dos registros A → `82.29.56.191`, `outline.iridia.cloud` y `s3.iridia.cloud`.
  Verificar con `dig +short @1.1.1.1 outline.iridia.cloud` — `/etc/hosts` de esta VPS
  miente sobre `iridia.cloud`. Sin DNS resuelto, el challenge HTTP-01 falla.
- **Google Cloud** → OAuth client (Web application):
  - redirect URI exacto `https://outline.iridia.cloud/auth/google.callback`
  - JS origin `https://outline.iridia.cloud`
- **Resend**: API key y dominio remitente verificado.
- `sudo` con TTY. En esta caja `sudo -v` desde otra terminal **no** habilita sudo para
  procesos sin TTY (`tty_tickets`) — para una sesión de ops hace falta un
  `/etc/sudoers.d/99-claude-temp` (NOPASSWD) que **se borra al cerrar**.

---

## Instalación

### 1. Clonar en `/opt/services`

```bash
cd /opt/services
git clone git@github.com:Iridia-IA/outline-service.git
cd outline-service/deploy/vps
```

### 2. Secretos

```bash
cp .env.example .env
./scripts/gen-secrets.sh      # idempotente: solo completa lo vacío, deja .env en 0600
$EDITOR .env                  # GOOGLE_CLIENT_ID/SECRET, SMTP_PASSWORD, SMTP_FROM_EMAIL
```

> ⚠️ **`SECRET_KEY` es irrecuperable.** Si se pierde, todo el contenido cifrado de la base queda
> inaccesible para siempre. Copiarlo a Vault (`127.0.0.1:8200`) y al gestor de contraseñas
> personal **antes** de seguir. Y backupear `.env` después de cada cambio.

### 3. Datos primero, app después

```bash
docker compose up -d outline-postgres outline-redis outline-minio
docker compose ps                      # esperar los tres healthy
docker compose up -d outline-minio-init
docker compose logs outline-minio-init # "bucket outline listo y privado"

docker compose up -d outline-app
docker compose logs -f outline-app     # las migraciones de Sequelize corren solas al bootear
```

### 4. Verificar en loopback ANTES de tocar el edge

```bash
curl -s localhost:3300/_health          # OK
```

Si esto no responde, no seguir: el problema es del stack, no del edge, y tocar el Caddyfile
solo agrega una variable.

### 5. Fusionar los sites al Caddy del host

```bash
sudo ./apply-host-caddy.sh
journalctl -u caddy -f                  # seguir la emisión de certs
```

El script hace backup → append → `caddy validate` → reload, y **restaura el backup sin recargar
si validate falla**. Los 7 sites existentes no se cortan en ningún caso.

### 6. Primer login

Entrar a `https://outline.iridia.cloud` con una cuenta **@iridia-ai.com**. El claim `hd` de
Google es lo que crea el workspace; una cuenta gmail personal no puede crearlo
(`GmailAccountCreationError`).

### 7. Configuración in-app (Settings)

- Nombre del workspace, logo.
- **Security → dominios permitidos**: `iridia-ai.com`.
- Política de sharing público.
- Idioma por defecto.

### 8. Backups

Sumar dos stanzas a `/opt/services/scripts/backup-services.sh` (el cron central de las 03:30,
retención 7d). **No instalar un timer propio** — duplicaría horarios, que es justo la deuda que
`context/TASKS.yaml` marca sobre Atlas.

```bash
# Postgres de Outline
docker exec outline-postgres pg_dump -U outline -d outline -Fc > "$BK/db/outline-$TS.dump"
# Adjuntos (MinIO) — mismo disco que la DB, por eso el offsite es la deuda que queda abierta
tar czf "$BK/volumes/outline-minio-$TS.tar.gz" -C /opt/services/outline-service/deploy/vps data/minio
```

Los dumps llevan contenido interno de la empresa: `chmod 600`. Probar el restore al menos una
vez — un backup sin restore probado no es un backup.

---

## Checklist de seguridad

- [ ] Solo 22/80/443 alcanzables desde afuera (`nmap -Pn 82.29.56.191` **desde tu máquina**).
      El control real es que ningún servicio publica fuera de loopback — **no** UFW.
- [ ] `.env` en 0600, git-ignored, generado por `gen-secrets.sh`.
- [ ] `SECRET_KEY` y `UTILS_SECRET` guardados en Vault **y** en el gestor personal.
- [ ] `outline-app` recibe un allowlist explícito de env vars (no `env_file`).
- [ ] `outline-data` es `internal: true` — postgres y redis no tienen ruta a internet.
- [ ] Bucket de MinIO **privado** (`mc anonymous set none`); acceso solo por URL firmada.
- [ ] `s3.iridia.cloud` sirve **solo** `/outline` y `/outline/*`; todo lo demás → 404.
      La consola de MinIO vive en `127.0.0.1:9101` y se accede por túnel SSH.
- [ ] Caddy **reemplaza** `X-Forwarded-For` con la IP real del cliente (el rate-limiter de
      Outline lo lee sin validar).
- [ ] Reglas `DOCKER-USER` para las subnets nuevas de `outline-edge`/`outline-data`
      (las existentes cubren solo `172.18/19/20.0.0/16`), persistidas con `netfilter-persistent`.
- [ ] fail2ban verificado con tráfico real — ver abajo.

### ⚠️ fail2ban puede autobanear usuarios legítimos

Las jails existentes leen `/var/log/caddy/*.access.log`, así que los logs nuevos entran al glob
automáticamente:

- **`caddy-auth`** — 5× 401/403 en 5 min → ban 1 h. La API de Outline devuelve 401 en sesiones
  expiradas y 403 a anónimos que tocan un doc privado. Con sharing público activado, **un lector
  legítimo puede autobanearse**.
- **`caddy-scan`** — 40× 404 en 60 s → ban 30 min. Una SPA puede generar ráfagas.

Después del deploy, generar tráfico real (login, navegación, un doc compartido abierto en ventana
privada) y revisar:

```bash
sudo fail2ban-client status caddy-auth
sudo fail2ban-client status caddy-scan
```

Si mordió: jail dedicada para los logs de Outline con `maxretry` alto, excluyendo esos archivos
del glob genérico.

---

## Por qué MinIO necesita un dominio público

Verificado en el código de Outline, no asumido:

- Los uploads van por **presigned POST/PUT directo del navegador al bucket**
  (`server/storage/files/S3Storage.ts`).
- Las descargas son un **redirect 302 a una URL firmada**
  (`server/routes/api/attachments/attachments.ts`).

Un MinIO solo en red interna —como el de Langfuse— rompe todos los adjuntos e imágenes. De ahí
`s3.iridia.cloud`.

Dos detalles que rompen las firmas si se tocan:

1. **Path-style obligatorio.** `AWS_S3_UPLOAD_BUCKET_URL` no debe empezar con el nombre del
   bucket: si el hostname arranca con él, Outline descarta el endpoint custom y firma contra AWS
   real. Por eso `https://s3.iridia.cloud` + `AWS_S3_FORCE_PATH_STYLE=true`, nunca
   `outline.s3.iridia.cloud`.
2. **No tocar el header `Host` en Caddy.** SigV4 lo firma. Caddy lo preserva por defecto —
   agregar `header_up Host` invalidaría todas las URLs firmadas.

---

## Por qué Caddy no manda CSP ni X-Frame-Options en `outline.iridia.cloud`

- Outline emite su propia CSP con nonce por request (`server/middlewares/csp.ts`). Dos headers
  CSP hacen que el navegador aplique la **intersección** de ambas políticas y la app se rompe.
  Mismo criterio que el strip de HSTS que se le hizo a Vault.
- `X-Frame-Options: DENY` rompe el embebido de documentos compartidos públicamente. El control
  de framing lo hace la app con `frame-ancestors` en su propia CSP.

---

## Operación

```bash
docker compose ps                          # estado + health
docker compose logs -f outline-app         # seguir un servicio
docker compose down                        # bajar (conserva data/)
docker compose up -d                       # levantar

# Actualizar Outline: SIEMPRE backup de la DB primero — cada release trae
# migraciones automáticas que no siempre son compatibles hacia atrás.
docker exec outline-postgres pg_dump -U outline -d outline -Fc > ~/outline-pre-upgrade.dump
$EDITOR .env                               # bump de OUTLINE_IMAGE
docker compose pull outline-app && docker compose up -d outline-app
docker compose logs -f outline-app         # las migraciones corren al bootear

# Consola de MinIO (no está publicada en Caddy)
ssh -L 9101:127.0.0.1:9101 lvallejos@82.29.56.191   # → http://localhost:9101

# Egress de la app: está en outline-data (internal) Y en outline-edge. La ruta
# por defecto tiene que salir por la segunda, o se caen Google OAuth y Resend.
docker compose exec outline-app wget -qO- -T5 https://accounts.google.com/.well-known/openid-configuration >/dev/null \
  && echo "egress OK" || echo "SIN EGRESS — revisar la ruta por defecto del container"
```

### Restore

```bash
DUMP=/opt/backups/db/outline-<stamp>.dump
docker compose stop outline-app
docker exec -i outline-postgres psql -U outline -d postgres -c 'DROP DATABASE outline;'
docker exec -i outline-postgres psql -U outline -d postgres -c 'CREATE DATABASE outline OWNER outline;'
docker exec -i outline-postgres pg_restore -U outline -d outline < "$DUMP"
docker compose start outline-app
```

---

## Qué imagen está corriendo

Fase 1 usa la imagen **oficial** pinneada: el fork `Iridia-IA/outline-service` está a diff cero
de upstream en `v1.10.0`, y `outlinewiki/outline:1.10.0` fue buildeada de ese mismo commit
(`7c34b79`). No hay build local, así que la imagen y el repo no pueden divergir.

Eso cambia en la **Fase 2** (branding propio): la imagen pasa a construirse en GitHub Actions y a
publicarse en `ghcr.io/iridia-ia/outline-service:<tag>`. A partir de ahí, `OUTLINE_IMAGE` en
`.env` es el único vínculo imagen↔commit — pinnear siempre un tag, nunca `latest`.

> **No buildear este repo en la VPS.** `Dockerfile.base` corre Vite con
> `--max-old-space-size=24000` sobre 4 vCPU y ~9.9 GB libres, con la caja compartida con Langfuse,
> Atlas y Postiz. Un OOM acá se los lleva puestos. El build es de CI.
