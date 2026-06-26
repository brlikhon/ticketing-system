# ticketing-system

AI/API support copilot for fintech ticket triage.

**Live (after deploy):** https://ticket.brlikhon.engineer

---

## What's in this repo

```
ticketing-system/
├── README.md                  ← you are here
├── DEPLOY.md                  ← full VM deployment guide
├── deploy.sh                  ← one-shot installer (Ubuntu 22.04)
├── nginx.conf                 ← nginx reverse-proxy config
├── queuestorm.service         ← systemd unit
├── push-to-github.ps1         ← Windows helper to push to GitHub
└── queuestorm/                ← the FastAPI app
    ├── main.py
    ├── analyzer.py
    ├── models.py
    ├── prompt_builder.py
    ├── safety.py
    ├── requirements.txt
    ├── Dockerfile
    ├── .env.example
    ├── ui/queuestorm-ui.html  ← support dashboard
    └── README.md              ← API docs (spec, schema, prompt design)
```

---

## What it does

`POST /analyze-ticket` takes a customer complaint + transaction history, returns a structured JSON investigation: which transaction matches, whether evidence supports the claim, case type, severity, department routing, and a safe customer reply.

See [`queuestorm/README.md`](queuestorm/README.md) for the full API spec, response schema, safety design, and prompt engineering rationale.

---

## Deploy in 5 minutes (Ubuntu VM)

```bash
git clone https://github.com/brlikhon/ticketing-system.git
cd ticketing-system/queuestorm
cp .env.example .env
nano .env                # set AISA_API_KEY=sk-...
sudo bash ../deploy.sh
```

See [`DEPLOY.md`](DEPLOY.md) for the full guide (DNS, firewall, TLS, troubleshooting).

---

## Quick API test

```bash
curl https://ticket.brlikhon.engineer/health
# {"status":"ok"}

curl -X POST https://ticket.brlikhon.engineer/analyze-ticket \
  -H "Content-Type: application/json" \
  -d @queuestorm/sample_request.json
```

---

## Tech stack

- FastAPI + Pydantic v2
- OpenAI Python SDK (pointed at AISA gateway: `https://api.aisa.one/v1`)
- Model: `[redacted]o-mini`, JSON mode, temperature 0.1
- nginx (TLS termination + reverse proxy)
- systemd (process supervision)
- Let's Encrypt (TLS certs)
- Single-file HTML dashboard (vanilla JS, no framework)