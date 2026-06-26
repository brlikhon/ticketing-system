# QueueStorm Investigator — Runbook

## Prerequisites
- Python 3.11+
- Docker (optional)
- An API key for an OpenAI-compatible endpoint (AISA, OpenAI, or any compatible gateway)

## Local Setup

```bash
git clone <your-repo-url>
cd queuestorm
cp .env.example .env
# Edit .env and add your AISA_API_KEY (or OPENAI_API_KEY)
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

## Test Health
```bash
curl http://localhost:8000/health
# Expected: {"status":"ok"}
```

## Test Main Endpoint
```bash
curl -X POST http://localhost:8000/analyze-ticket \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "TKT-001",
    "complaint": "I sent 5000 taka to a wrong number around 2pm today.",
    "language": "en",
    "channel": "in_app_chat",
    "user_type": "customer",
    "transaction_history": [
      {
        "transaction_id": "TXN-9101",
        "timestamp": "2026-04-14T14:08:22Z",
        "type": "transfer",
        "amount": 5000,
        "counterparty": "+8801719876543",
        "status": "completed"
      }
    ]
  }'
```

## Docker Build & Run
```bash
docker build -t queuestorm-team .
docker run -p 8000:8000 --env-file .env queuestorm-team
```

## Environment Variables

| Variable | Required | Default | Notes |
|---|---|---|---|
| `AISA_API_KEY` | yes (or `OPENAI_API_KEY`) | — | API key for the OpenAI-compatible gateway |
| `OPENAI_API_KEY` | fallback | — | Used if `AISA_API_KEY` is unset |
| `AISA_BASE_URL` | no | `https://api.aisa.one/v1` | Override base URL for OpenAI-compatible gateways |
| `MODEL_NAME` | no | `gpt-4o-mini` | Model to call on the configured base URL |
| `PORT` | no | `8000` | Listening port |

## Deployment on Render.com
1. Push code to GitHub
2. Create a new Web Service on Render.com → connect GitHub repo
3. Set Build Command: `pip install -r requirements.txt`
4. Set Start Command: `uvicorn main:app --host 0.0.0.0 --port $PORT`
5. Add environment variables in the Render dashboard:
   - `AISA_API_KEY` (or `OPENAI_API_KEY`)
   - optionally `AISA_BASE_URL`, `MODEL_NAME`
6. Deploy — Render provides a public HTTPS URL automatically

## Safety Notes for Operators
- **Never** commit a real `.env` file. Use `.env.example` as the template only.
- **Never** paste an API key into a public channel — rotate immediately if exposed.
- The service is designed to never echo credentials or promise refunds; if logs show `safety_sanitized` in `reason_codes`, review the upstream LLM prompt and consider strengthening the system prompt.