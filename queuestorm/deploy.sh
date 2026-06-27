#!/usr/bin/env bash
# ============================================================================
#  QueueStorm Investigator — One-Shot VM Deploy Script
#  Target: fresh Ubuntu 22.04 LTS VM (AWS EC2, DigitalOcean, Hetzner, Azure, etc.)
#  Usage:  sudo bash deploy.sh
#  Idempotent: safe to re-run.
# ============================================================================
set -euo pipefail

APP_NAME="queuestorm"
APP_USER="ubuntu"
APP_PARENT_DIR="/home/${APP_USER}/ticketing-system"
APP_DIR="${APP_PARENT_DIR}/queuestorm"
APP_PORT="8000"
DOMAIN="${DOMAIN:-ticket.brlikhon.engineer}"
PYTHON_VERSION="${PYTHON_VERSION:-}"   # auto-detected below
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
NGINX_FILE="/etc/nginx/sites-available/${APP_NAME}"

log() { printf "\033[1;36m[deploy]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[fatal]\033[0m %s\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root: sudo bash deploy.sh"

# ---------------------------------------------------------------------------
# 0. Detect Python (prefer 3.11, fall back to 3.12 / 3.13 / 3.10)
# ---------------------------------------------------------------------------
detect_python() {
    for v in 3.11 3.12 3.13 3.10; do
        if command -v "python${v}" >/dev/null 2>&1; then
            echo "$v"; return 0
        fi
    done
    return 1
}

if [[ -z "${PYTHON_VERSION}" ]]; then
    PYTHON_VERSION="$(detect_python || true)"
    if [[ -z "${PYTHON_VERSION}" ]]; then
        # Nothing installed yet — default to 3.11 and let apt-get pull it in
        PYTHON_VERSION="3.11"
    fi
fi
log "Using Python ${PYTHON_VERSION}"

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
log "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python3-pip \
    nginx certbot python3-certbot-nginx \
    git curl ufw software-properties-common ca-certificates

# If the chosen Python isn't available after apt-get, fall back to system python3
if ! command -v "python${PYTHON_VERSION}" >/dev/null 2>&1; then
    log "WARN: python${PYTHON_VERSION} not found after install; falling back to python3"
    PYTHON_VERSION="$(detect_python || echo "3")"
    apt-get install -y --no-install-recommends python3 python3-venv || true
fi
log "Python resolved to $(python${PYTHON_VERSION} --version 2>&1)"

# ---------------------------------------------------------------------------
# 2. Firewall (UFW) — open SSH, HTTP, HTTPS
# ---------------------------------------------------------------------------
log "Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
# 8000 only on loopback (nginx proxies to it)
ufw --force enable

# ---------------------------------------------------------------------------
# 3. Ensure app directory exists; clone or pull
# ---------------------------------------------------------------------------
log "Preparing app directory ${APP_DIR}..."
install -d -o "${APP_USER}" -g "${APP_USER}" "${APP_PARENT_DIR}"

# Make sure the repo is owned by APP_USER so the inner `sudo -u ${APP_USER} git`
# never trips over "dubious ownership" (this can happen if the directory was
# previously created by `sudo git clone` from this same script).
if [[ -d "${APP_PARENT_DIR}" ]] && [[ "$(stat -c '%U' "${APP_PARENT_DIR}" 2>/dev/null)" != "${APP_USER}" ]]; then
    log "Fixing ownership of ${APP_PARENT_DIR} -> ${APP_USER}:${APP_USER}"
    chown -R "${APP_USER}:${APP_USER}" "${APP_PARENT_DIR}"
fi

# Allow git to operate on a repo owned by a different user. Belt-and-braces in
# case the chown above is skipped (e.g. read-only fs). Writes to the invoking
# user's global gitconfig, which is what `sudo -u ubuntu git` will read.
git config --global --add safe.directory "${APP_PARENT_DIR}" 2>/dev/null || true

if [[ -d "${APP_PARENT_DIR}/.git" ]]; then
    log "Existing repo found at ${APP_PARENT_DIR}, pulling latest..."
    sudo -u "${APP_USER}" git -C "${APP_PARENT_DIR}" pull --ff-only
else
    log "Cloning repository into ${APP_PARENT_DIR}..."
    sudo -u "${APP_USER}" git clone https://github.com/brlikhon/ticketing-system.git "${APP_PARENT_DIR}"
fi

cd "${APP_DIR}"

# Sanity check: the clone should have produced .env.example
if [[ ! -f .env.example ]]; then
    die "Clone succeeded but .env.example is missing in ${APP_DIR} — repo looks incomplete. Aborting."
fi

# ---------------------------------------------------------------------------
# 4. .env — create only if missing; never overwrite a real key
# ---------------------------------------------------------------------------
if [[ ! -f .env ]]; then
    log "Creating .env from .env.example..."
    sudo -u "${APP_USER}" cp .env.example .env
    sudo -u "${APP_USER}" chmod 600 .env
    echo ""
    echo "================================================================"
    echo "  ACTION REQUIRED: edit ${APP_DIR}/.env"
    echo "  Set AISA_API_KEY=sk-your-key-here (or OPENAI_API_KEY=...)"
    echo "  Then re-run:  sudo bash $(realpath --relative-to=/ "$0" 2>/dev/null || echo deploy.sh)"
    echo "================================================================"
    echo ""
else
    log ".env exists, preserving current values."
fi

# Source .env to pick up PORT/keys for sanity checks (do not log the key)
set +u
# shellcheck disable=SC1091
source .env 2>/dev/null || true
set -u
if [[ -z "${AISA_API_KEY:-}${OPENAI_API_KEY:-}" ]]; then
    log "WARNING: no API key in .env yet — service will still install but LLM calls will fail until you set AISA_API_KEY."
fi

# ---------------------------------------------------------------------------
# 5. Python venv + dependencies
# ---------------------------------------------------------------------------
log "Creating Python venv and installing dependencies..."
sudo -u "${APP_USER}" python${PYTHON_VERSION} -m venv venv
sudo -u "${APP_USER}" ./venv/bin/pip install --upgrade pip
sudo -u "${APP_USER}" ./venv/bin/pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# 6. systemd unit (service survives reboots, auto-restarts on crash)
# ---------------------------------------------------------------------------
log "Writing systemd unit ${SERVICE_FILE}..."
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=QueueStorm Investigator (FastAPI)
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn main:app \\
    --host 127.0.0.1 \\
    --port ${APP_PORT} \\
    --workers 2 \\
    --proxy-headers \\
    --forwarded-allow-ips="127.0.0.1"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${APP_NAME}.service"

# ---------------------------------------------------------------------------
# 7. nginx reverse proxy on 80/443 -> 127.0.0.1:8000
# ---------------------------------------------------------------------------
log "Writing nginx config ${NGINX_FILE}..."

# Strong SSL parameters (Mozilla "Intermediate" profile + 2048-bit DH)
SSL_CONF="/etc/nginx/snippets/queuestorm-ssl.conf"
install -d /etc/nginx/snippets
cat > "${SSL_CONF}" <<'SSL_EOF'
# SSL settings — Mozilla Intermediate profile
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;

# OCSP stapling
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

# Security headers
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
SSL_EOF

# Diffie-Hellman params for perfect forward secrecy (2048-bit; takes ~30s)
if [[ ! -f /etc/nginx/dhparam.pem ]]; then
    log "Generating 2048-bit DH params (one-time, ~30s)..."
    openssl dhparam -out /etc/nginx/dhparam.pem 2048 2>/dev/null
fi
echo "ssl_dhparam /etc/nginx/dhparam.pem;" >> "${SSL_CONF}"

# HTTP server: redirect to HTTPS + serve ACME challenges
cat > "${NGINX_FILE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # ACME http-01 challenge (certbot)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Redirect everything else to HTTPS (only after cert exists)
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# HTTPS server block (only loaded when cert files exist; certbot will replace this)
cat > "/etc/nginx/sites-available/${APP_NAME}-ssl" <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    include ${SSL_CONF};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # LLM calls can take up to 25s — keep gateway timeouts generous
        proxy_connect_timeout 10s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;

        client_max_body_size 1m;
        add_header Cache-Control "no-store" always;
    }
}
EOF

# Enable HTTP now; HTTPS block stays disabled until cert is issued
ln -sf "${NGINX_FILE}" "/etc/nginx/sites-enabled/${APP_NAME}"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 8. TLS via Let's Encrypt — full provisioning with DNS pre-flight
# ---------------------------------------------------------------------------
request_cert() {
    log "Requesting Let's Encrypt certificate for ${DOMAIN}..."
    certbot certonly --webroot -w /var/www/html \
        -d "${DOMAIN}" \
        --non-interactive --agree-tos -m "admin@${DOMAIN}" \
        --rsa-key-size 2048 \
        --no-eff-email \
        || return 1
    return 0
}

verify_cert() {
    local cert_path="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    [[ -f "${cert_path}" ]] || return 1
    openssl x509 -checkend 2592000 -noout -in "${cert_path}" >/dev/null 2>&1
}

if [[ "${SKIP_TLS:-0}" == "1" ]]; then
    log "TLS skipped (SKIP_TLS=1). HTTP-only on port 80."
else
    # Detect public IP
    PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
              || curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null \
              || echo "")"

    # Resolve the domain
    RESOLVED_IP="$(getent ahosts "${DOMAIN}" 2>/dev/null | awk 'NR==1{print $1}' || true)"

    DNS_OK=0
    if [[ -n "${PUBLIC_IP}" && -n "${RESOLVED_IP}" && "${PUBLIC_IP}" == "${RESOLVED_IP}" ]]; then
        DNS_OK=1
    fi

    if [[ ${DNS_OK} -eq 1 ]]; then
        log "DNS check OK: ${DOMAIN} -> ${RESOLVED_IP} (matches VM IP ${PUBLIC_IP})"
        if request_cert; then
            if verify_cert; then
                # Enable the HTTPS site block
                ln -sf "/etc/nginx/sites-available/${APP_NAME}-ssl" \
                       "/etc/nginx/sites-enabled/${APP_NAME}-ssl"
                nginx -t && systemctl reload nginx
                log "✓ TLS certificate issued and HTTPS enabled"

                # Verify auto-renewal works (dry-run)
                if certbot renew --dry-run --quiet 2>/dev/null; then
                    log "✓ Certbot auto-renewal verified (systemd timer will renew at expiry)"
                else
                    log "WARN: certbot renew --dry-run failed; check 'journalctl -u certbot.timer'"
                fi

                # Ensure certbot timer is enabled (it usually is, but be explicit)
                systemctl enable certbot.timer >/dev/null 2>&1 || true
                systemctl start  certbot.timer >/dev/null 2>&1 || true
            else
                log "WARN: certificate issued but failed validity check."
            fi
        else
            log "WARN: certbot failed. Common causes:"
            log "      - rate-limit (5 certs/week per domain)"
            log "      - port 80 unreachable from the internet"
            log "      - CAA record blocking letsencrypt"
            log "      Re-run later: sudo certbot certonly --webroot -w /var/www/html -d ${DOMAIN}"
        fi
    else
        echo ""
        echo "================================================================"
        echo "  TLS SKIPPED — DNS not pointing at this VM yet"
        echo "================================================================"
        echo "  Domain:    ${DOMAIN}"
        echo "  Resolved:  ${RESOLVED_IP:-<NXDOMAIN>}"
        echo "  VM IP:     ${PUBLIC_IP:-<unknown>}"
        echo ""
        echo "  Action: add an A record in your DNS provider:"
        echo "          ${DOMAIN}  ->  ${PUBLIC_IP:-<VM-PUBLIC-IP>}"
        echo ""
        echo "  After DNS propagates (1-5 min), run:"
        echo "    sudo certbot certonly --webroot -w /var/www/html \\"
        echo "      -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN}"
        echo "    sudo ln -sf /etc/nginx/sites-available/${APP_NAME}-ssl \\"
        echo "                /etc/nginx/sites-enabled/${APP_NAME}-ssl"
        echo "    sudo nginx -t && sudo systemctl reload nginx"
        echo "================================================================"
        echo ""
    fi
fi

# ---------------------------------------------------------------------------
# 9. Health check
# ---------------------------------------------------------------------------
log "Waiting for service to come up..."
for i in {1..15}; do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
        log "✓ Service is healthy"
        break
    fi
    sleep 2
done

# ---------------------------------------------------------------------------
# 9.5. Post-install verification
# ---------------------------------------------------------------------------
echo ""
log "Post-install summary:"
echo "  Python:     $(sudo -u ${APP_USER} ${APP_DIR}/venv/bin/python --version 2>&1)"
echo "  pip:        $(sudo -u ${APP_USER} ${APP_DIR}/venv/bin/pip --version 2>&1 | cut -d' ' -f1-2)"
echo "  fastapi:    $(sudo -u ${APP_USER} ${APP_DIR}/venv/bin/pip show fastapi 2>/dev/null | grep -E '^Version:' | awk '{print $2}')"
echo "  pydantic:   $(sudo -u ${APP_USER} ${APP_DIR}/venv/bin/pip show pydantic 2>/dev/null | grep -E '^Version:' | awk '{print $2}')"
echo "  openai:     $(sudo -u ${APP_USER} ${APP_DIR}/venv/bin/pip show openai 2>/dev/null | grep -E '^Version:' | awk '{print $2}')"
echo "  uvicorn:    $(sudo -u ${APP_USER} ${APP_DIR}/venv/bin/pip show uvicorn 2>/dev/null | grep -E '^Version:' | awk '{print $2}')"
echo "  systemd:    $(systemctl is-active ${APP_NAME})"
echo "  nginx:      $(systemctl is-active nginx)"
echo "  ufw:        $(ufw status | head -1)"
echo "  local:      $(curl -fsS http://127.0.0.1:${APP_PORT}/health 2>/dev/null || echo 'NOT RESPONDING')"

echo ""
echo "================================================================"
echo "  DEPLOY COMPLETE"
echo "================================================================"
echo "  App:        ${APP_DIR}"
echo "  Service:    systemctl status ${APP_NAME}"
echo "  Logs:       journalctl -u ${APP_NAME} -f"
echo "  Local URL:  http://127.0.0.1:${APP_PORT}/health"
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    echo "  Public URL: https://${DOMAIN}/health"
    echo "  Dashboard:  https://${DOMAIN}/ui/queuestorm-ui.html"
    EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" 2>/dev/null | cut -d= -f2)
    echo "  Cert:       expires ${EXPIRY} (auto-renews via certbot.timer)"
else
    echo "  Public URL: http://${DOMAIN}/health  (HTTPS not yet provisioned)"
    echo "  Dashboard:  http://${DOMAIN}/ui/queuestorm-ui.html"
fi
echo ""
echo "  Useful commands:"
echo "    sudo certbot certificates          # list installed certs"
echo "    sudo certbot renew --dry-run       # test auto-renewal"
echo "    sudo nginx -t && sudo systemctl reload nginx"
echo "    sudo journalctl -u certbot.timer   # renewal schedule"
echo ""
echo "  If AISA_API_KEY not yet set:"
echo "    sudo nano ${APP_DIR}/.env"
echo "    sudo systemctl restart ${APP_NAME}"
echo "================================================================"