# QueueStorm Investigator — VM Deployment Guide

Single-file deployment to a fresh Ubuntu 22.04 LTS VM.
Public URL: **http(s)://ticket.brlikhon.engineer**

---

## One-time VM setup (10 minutes)

### 1. Provision a VM

Minimum specs:
- 1 vCPU, 1 GB RAM, 20 GB disk
- Ubuntu 22.04 LTS (or 24.04)
- Public IPv4 address
- Inbound rules: **22** (SSH, your IP only), **80**, **443**

Cheapest options:
- AWS EC2 `t3.nano` (~$3/mo, free-tier eligible)
- Hetzner `CX22` (~$4/mo, very fast)
- DigitalOcean `s-1vcpu-1gb` (~$6/mo)
- Oracle Cloud `VM.Standard.A1.Flex` (always free ARM)

### 2. Point DNS

In your DNS provider (Cloudflare / Namecheap / Porkbun — wherever `brlikhon.engineer` is managed):

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `ticket` | `<VM-PUBLIC-IP>` | 300 |

Verify after ~2 min: `dig ticket.brlikhon.engineer +short` should return the VM IP.

### 3. SSH in and run the deploy script

```bash
ssh ubuntu@<VM-PUBLIC-IP>

# Clone the repo
git clone https://github.com/brlikhon/ticketing-system.git
cd ticketing-system/queuestorm

# Edit .env — set your API key
cp .env.example .env
nano .env
# Add: AISA_API_KEY=sk-your-real-key-here

# Run the one-shot deploy
sudo bash deploy.sh
```

That's it. The script will:
1. Install Python 3.11, nginx, certbot, ufw
2. Set up firewall (SSH + HTTP + HTTPS, deny everything else)
3. Create a Python venv and install dependencies
4. Write a hardened systemd unit and start the service
5. Configure nginx as reverse proxy on 80/443 → 127.0.0.1:8000
6. Generate 2048-bit DH params and write Mozilla-intermediate SSL config
7. Detect whether DNS A record points at this VM
8. If yes: request a Let's Encrypt cert, enable HTTPS, redirect HTTP→HTTPS, verify auto-renewal
9. If no: skip cert (still serves HTTP), print exact commands to enable HTTPS after DNS propagates
10. Wait for the health check to pass

---

## SSL / TLS

The deploy script provisions HTTPS end-to-end:

- **Certbot** with the `webroot` plugin (no nginx restart needed for renewals)
- **2048-bit RSA** certificate
- **TLS 1.2 / 1.3 only** (TLS 1.0 / 1.1 disabled)
- **Mozilla Intermediate** cipher profile (ECDHE for PFS, no RC4/3DES)
- **HSTS** with `max-age=31536000; includeSubDomains` (1 year)
- **OCSP stapling** enabled
- **2048-bit DH params** generated once and cached
- **Security headers**: X-Frame-Options, X-Content-Type-Options, Referrer-Policy
- **HTTP → HTTPS 301 redirect** (only for non-ACME traffic)
- **Auto-renewal** verified with `certbot renew --dry-run`, scheduled via `certbot.timer` (systemd)

To manually re-provision the cert (e.g. after DNS fix):
```bash
sudo certbot certonly --webroot -w /var/www/html \
    -d ticket.brlikhon.engineer \
    --non-interactive --agree-tos -m admin@ticket.brlikhon.engineer
sudo ln -sf /etc/nginx/sites-available/queuestorm-ssl \
           /etc/nginx/sites-enabled/queuestorm-ssl
sudo nginx -t && sudo systemctl reload nginx
```

Cert lifecycle:
```bash
sudo certbot certificates           # show all certs + expiry
sudo certbot renew --dry-run        # test renewal
sudo journalctl -u certbot.timer    # see next scheduled run
```

The cert auto-renews at ≤60 days remaining (default), and the nginx reload hook runs automatically — no manual action needed.

### 4. Verify

```bash
# Local
curl http://127.0.0.1:8000/health
# -> {"status":"ok"}

# Public
curl https://ticket.brlikhon.engineer/health
# -> {"status":"ok"}

# Dashboard
open https://ticket.brlikhon.engineer/ui/queuestorm-ui.html
```

---

## Day-to-day operations

| Task | Command |
|---|---|
| View live logs | `sudo journalctl -u queuestorm -f` |
| Restart service | `sudo systemctl restart queuestorm` |
| Update code | `cd /home/ubuntu/queuestorm && sudo git pull && sudo systemctl restart queuestorm` |
| Rotate API key | Edit `/home/ubuntu/queuestorm/.env`, then `sudo systemctl restart queuestorm` |
| Check status | `sudo systemctl status queuestorm` |
| Check nginx | `sudo nginx -t && sudo systemctl status nginx` |
| Renew TLS cert | `sudo certbot renew` (auto-renews via systemd timer) |

---

## Architecture

```
                          Internet
                             │
                  A record: ticket.brlikhon.engineer
                             │
                             ▼
              ┌──────────────────────────────┐
              │   nginx  (ports 80, 443)     │
              │   - TLS termination          │
              │   - reverse proxy            │
              │   - static-cache headers     │
              └──────────────┬───────────────┘
                             │ 127.0.0.1:8000
                             ▼
              ┌──────────────────────────────┐
              │  uvicorn  (FastAPI, :8000)   │
              │   - /health                  │
              │   - /analyze-ticket          │
              │   - /ui/queuestorm-ui.html   │
              │   - safety + JSON guards     │
              └──────────────┬───────────────┘
                             │ HTTPS (api.aisa.one/v1)
                             ▼
              ┌──────────────────────────────┐
              │   AISA / OpenAI gateway      │
              │   model: [redacted]o-mini    │
              └──────────────────────────────┘
```

**Network exposure:**
- 22 (SSH) — your IP only
- 80, 443 — public (TLS via Let's Encrypt)
- 8000 — bound to **127.0.0.1 only** (never reachable from internet)

**Security hardening baked in:**
- systemd `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome=read-only`
- `.env` mode 600
- nginx `client_max_body_size 1m`
- ufw default-deny + minimal allow-list
- certbot auto-renewal via systemd timer

---

## Files in this repo that drive deployment

| File | Purpose |
|---|---|
| `deploy.sh` | One-shot installer (everything) |
| `nginx.conf` | Standalone nginx site config (used by deploy.sh) |
| `queuestorm.service` | Standalone systemd unit (used by deploy.sh) |
| `Dockerfile` | Alternative container path (not used by VM deploy) |
| `.env.example` | Template for `.env` — copy + add `AISA_API_KEY` |
| `RUNBOOK.md` | Generic runbook (Render, Docker, etc.) |
| `README.md` | Spec / API docs |

---

## Troubleshooting

**Deploy script says "Application not healthy"**
```bash
sudo journalctl -u queuestorm -n 50
# Most likely: missing AISA_API_KEY, or AISA_BASE_URL unreachable
```

**TLS cert failed but HTTP works**
DNS wasn't pointing at the VM when deploy ran. Fix DNS, then:
```bash
sudo certbot certonly --webroot -w /var/www/html \
    -d ticket.brlikhon.engineer \
    --non-interactive --agree-tos -m admin@ticket.brlikhon.engineer
sudo ln -sf /etc/nginx/sites-available/queuestorm-ssl \
           /etc/nginx/sites-enabled/queuestorm-ssl
sudo nginx -t && sudo systemctl reload nginx
```

**Certbot rate-limited (5 certs/week per domain)**
Wait 7 days, or use the staging endpoint while iterating:
```bash
sudo certbot certonly --webroot -w /var/www/html \
    -d ticket.brlikhon.engineer --staging \
    --non-interactive --agree-tos -m admin@ticket.brlikhon.engineer
```

**Cert expired and didn't auto-renew**
```bash
sudo certbot renew --force-renewal
sudo nginx -t && sudo systemctl reload nginx
sudo journalctl -u certbot.timer --no-pager | tail -20
```

**SSL Labs test fails on a specific cipher**
The current profile is Mozilla Intermediate. To go stricter (Modern, TLS 1.3 only):
```bash
sudo sed -i 's/TLSv1.2 TLSv1.3/TLSv1.3/' /etc/nginx/snippets/queuestorm-ssl.conf
sudo nginx -t && sudo systemctl reload nginx
```

**Service won't start after editing .env**
```bash
sudo systemctl restart queuestorm
sudo journalctl -u queuestorm -n 30 --no-pager
```

**"502 Bad Gateway" from nginx**
uvicorn isn't running on 8000:
```bash
sudo systemctl status queuestorm
sudo journalctl -u queuestorm -n 30
```

**Want to scale up**
Edit `queuestorm.service`, change `--workers 2` to `--workers 4`, then:
```bash
sudo systemctl daemon-reload && sudo systemctl restart queuestorm
```