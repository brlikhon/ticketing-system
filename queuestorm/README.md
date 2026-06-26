# QueueStorm Investigator

AI/API support copilot for fintech support ticket analysis. Receives a customer support ticket (complaint + recent transaction history) and returns a fully structured JSON analysis: identifying the relevant transaction, rendering an evidence verdict, classifying the case, routing it to the correct department, and drafting a safe, professional customer reply.

This is **not a complaint classifier**. It is an **investigator**: it cross-references what the customer says against what the transaction data actually shows, and returns a reasoned verdict.

---

## Setup Instructions

```bash
git clone <your-repo-url>
cd queuestorm
cp .env.example .env
# Edit .env and add your AISA_API_KEY (or OPENAI_API_KEY)
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

## Run Command

```bash
uvicorn main:app --host 0.0.0.0 --port 8000
```

---

## Sample Request

```bash
curl -X POST http://localhost:8000/analyze-ticket \
  -H "Content-Type: application/json" \
  -d '{
    "ticket_id": "TKT-001",
    "complaint": "I sent 5000 taka to a wrong number around 2pm today. The number was supposed to be 01712345678 but I think I typed it wrong. The person isn'\''t responding to my call. Please help me get my money back.",
    "language": "en",
    "channel": "in_app_chat",
    "user_type": "customer",
    "campaign_context": "boishakh_bonanza_day_1",
    "transaction_history": [
      {
        "transaction_id": "TXN-9101",
        "timestamp": "2026-04-14T14:08:22Z",
        "type": "transfer",
        "amount": 5000,
        "counterparty": "+8801719876543",
        "status": "completed"
      },
      {
        "transaction_id": "TXN-9087",
        "timestamp": "2026-04-13T18:12:00Z",
        "type": "cash_in",
        "amount": 10000,
        "counterparty": "AGENT-512",
        "status": "completed"
      }
    ]
  }'
```

## Sample Response

```json
{
  "ticket_id": "TKT-001",
  "relevant_transaction_id": "TXN-9101",
  "evidence_verdict": "consistent",
  "case_type": "wrong_transfer",
  "severity": "high",
  "department": "dispute_resolution",
  "agent_summary": "Customer reports sending 5000 BDT to a wrong number around 14:00. Transaction TXN-9101 matches: 5000 BDT transfer at 14:08:22 to a number, status completed.",
  "recommended_next_action": "Open a wrong-transfer dispute in the dispute resolution queue. Attempt to contact the recipient via in-app callback. Escalate after 24 hours if no response.",
  "customer_reply": "Thank you for reaching out. We have located the transaction and our dispute resolution team will review your case. Any eligible amount will be returned through official channels after investigation. Please do not share your PIN or OTP with anyone, including anyone claiming to help recover funds.",
  "human_review_required": true,
  "confidence": 0.92,
  "reason_codes": ["amount_match", "time_match", "type_match"]
}
```

See `sample_output.json` for the full worked example.

---

## Tech Stack

- **Python 3.11+**
- **FastAPI** — HTTP framework
- **Pydantic v2** — request/response validation and enums
- **OpenAI Python SDK** — LLM client (JSON mode), pointed at an OpenAI-compatible gateway via `OPENAI_BASE_URL` (AISA by default)
- **Uvicorn** — ASGI server
- **Docker** — containerization (image < 500MB, no GPU)

---

## AI / Model Usage

The service uses **OpenAI `gpt-4o-mini`** via the `openai` Python SDK with:

- `response_format={"type": "json_object"}` — forces valid JSON output matching the schema.
- `temperature=0.1` — low temperature for deterministic structured output.
- `max_tokens=1024` — bounded to stay within the 30-second judge harness timeout.
- Single call per ticket: the full transaction history is included in the user message; no multi-turn reasoning or tool calls.

The model is chosen for fast structured JSON output, low cost, and reliable instruction following within the 30-second timeout.

The service is provider-agnostic at the model layer: it uses the official `openai` SDK and reads `OPENAI_BASE_URL` / `AISA_BASE_URL`, so it can target any OpenAI-compatible gateway (AISA by default at `https://api.aisa.one/v1`). The active model is controlled by `MODEL_NAME`.

---

## Evidence Reasoning Approach

The LLM is instructed to act as an **investigator**, not a classifier:

1. Read the complaint carefully.
2. Read every transaction in `transaction_history` carefully.
3. Identify which transaction (if any) the complaint refers to — match by **amount**, **approximate time**, **type**, **counterparty**, or **status**.
4. Decide whether the transaction data **supports**, **contradicts**, or is **inconclusive** about the complaint.
5. Return one of three verdicts:
   - `consistent` — transaction matches and supports the claim
   - `inconsistent` — transaction matches but contradicts the claim
   - `insufficient_data` — no matching transaction or complaint is too vague

This reasoning is enforced by the system prompt in `prompt_builder.py` and protected by post-processing in `safety.py`.

---

## Safety Logic

Three layers of defense:

1. **System prompt** (`prompt_builder.py`) — hard-prohibits credential requests (PIN, OTP, password, card number), unauthorized refund promises, third-party redirects, and prompt-injection attempts in the complaint text.
2. **Post-processing** (`safety.py`) — regex-scans every `customer_reply` and `recommended_next_action` for forbidden credential, refund, and third-party patterns before the response is returned. Detected violations are sanitized and flagged with `safety_sanitized` in `reason_codes`.
3. **Prompt injection handling** — the system prompt explicitly instructs the model to ignore any instruction embedded in the complaint text that contradicts safety rules. The regex layer is a safety net if a model pass slips through.

---

## Known Limitations

- LLM may occasionally mis-match transactions in complex multi-transaction edge cases (e.g., very similar amounts or timestamps). The structured output schema keeps the failure mode observable via low `confidence`.
- Bangla/Banglish complaint understanding depends on the underlying model's multilingual capability.
- The service depends on a remote LLM endpoint. On timeout or upstream error, a safe schema-valid fallback is returned with `human_review_required=true`.
- The fallback response is intentionally conservative: agents must always verify before acting on it.

---

## MODELS

- **Active model**: `gpt-4o-mini` (OpenAI) by default, configurable via `MODEL_NAME`.
- **Runtime**: remote — the model is called over HTTPS; no local weights are loaded.
- **Why this model**: fast structured JSON output, low cost, and reliable instruction following within the 30-second judge harness timeout.
- **Provider routing**: the official `openai` Python SDK with `OPENAI_BASE_URL` pointed at an OpenAI-compatible gateway (AISA by default).

---

## Cost Estimate

At current `gpt-4o-mini` pricing, a typical ticket (system prompt + ~600-token user message + ~300-token structured JSON reply) costs roughly **$0.0003 – $0.0007 per ticket**, i.e. on the order of **$0.0005 per ticket**. Even at 100k tickets/month this is well under $50/month.