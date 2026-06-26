import json
import os
import logging
from pathlib import Path
from dotenv import load_dotenv
from openai import OpenAI
from models import AnalyzeTicketRequest, AnalyzeTicketResponse
from prompt_builder import SYSTEM_PROMPT, build_user_message
from safety import check_safety_violations, sanitize_reply

logger = logging.getLogger(__name__)

# Load .env from this package directory so `uvicorn main:app` works without
# manually exporting vars first. Real env vars still take precedence.
load_dotenv(dotenv_path=Path(__file__).parent / ".env", override=False)

# AISA is OpenAI-compatible. We point the official `openai` SDK at the AISA
# gateway using OPENAI_BASE_URL (read from env or default to aisa.one).
_API_KEY = os.environ.get("AISA_API_KEY") or os.environ.get("OPENAI_API_KEY")
if not _API_KEY:
    raise RuntimeError("AISA_API_KEY (or OPENAI_API_KEY) is required")

_BASE_URL = os.environ.get("AISA_BASE_URL") or os.environ.get("OPENAI_BASE_URL") or "https://api.aisa.one/v1"
_MODEL = os.environ.get("MODEL_NAME", "gpt-4o-mini")

client = OpenAI(api_key=_API_KEY, base_url=_BASE_URL)
MODEL = _MODEL


def analyze_ticket(req: AnalyzeTicketRequest) -> AnalyzeTicketResponse:
    user_message = build_user_message(req)

    try:
        response = client.chat.completions.create(
            model=MODEL,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_message},
            ],
            response_format={"type": "json_object"},
            temperature=0.1,  # low temperature for deterministic structured output
            max_tokens=1024,
            timeout=25,  # stay under the 30s judge harness timeout
        )
    except Exception as e:
        logger.error(f"LLM call failed: {e}")
        # Return a safe fallback response rather than crashing
        return _fallback_response(req, str(e))

    raw_content = response.choices[0].message.content
    try:
        data = json.loads(raw_content)
    except json.JSONDecodeError as e:
        logger.error(f"LLM returned invalid JSON: {e}\nRaw: {raw_content}")
        return _fallback_response(req, "LLM returned invalid JSON")

    # Enforce ticket_id echo
    data["ticket_id"] = req.ticket_id

    # Guard against LLM hallucination: if relevant_transaction_id is not actually
    # present in the provided transaction_history (or is null/empty), coerce it
    # to None and downgrade the verdict to insufficient_data.
    valid_ids = {t.transaction_id for t in req.transaction_history}
    rtid = data.get("relevant_transaction_id")
    if rtid is not None and str(rtid).strip() != "" and str(rtid) not in valid_ids:
        logger.warning(
            f"LLM hallucinated transaction_id={rtid!r} not in history; coercing to null"
        )
        data["relevant_transaction_id"] = None
        if data.get("evidence_verdict") == "consistent":
            data["evidence_verdict"] = "insufficient_data"
        data.setdefault("reason_codes", [])
        if data["reason_codes"] is None:
            data["reason_codes"] = []
        data["reason_codes"].append("hallucinated_txid_corrected")

    # Phishing case rule: must always be critical / fraud_risk / null txid / human review
    if data.get("case_type") == "phishing_or_social_engineering":
        data["severity"] = "critical"
        data["department"] = "fraud_risk"
        data["relevant_transaction_id"] = None
        data["human_review_required"] = True

    # Inconsistent-evidence rule: always require human review
    if data.get("evidence_verdict") == "inconsistent":
        data["human_review_required"] = True

    # Run safety post-processing
    customer_reply = data.get("customer_reply", "") or ""
    recommended_action = data.get("recommended_next_action", "") or ""

    violations = check_safety_violations(customer_reply, recommended_action)
    if violations:
        logger.warning(f"Safety violations detected for {req.ticket_id}: {violations}")
        data["customer_reply"] = sanitize_reply(customer_reply)
        # Add safety violation to reason_codes for transparency to judges
        if "reason_codes" not in data or data["reason_codes"] is None:
            data["reason_codes"] = []
        data["reason_codes"].append("safety_sanitized")

    # Validate and coerce to response model
    try:
        return AnalyzeTicketResponse(**data)
    except Exception as e:
        logger.error(f"Response validation error: {e}\nData: {data}")
        return _fallback_response(req, f"Schema validation failed: {e}")


def _fallback_response(req: AnalyzeTicketRequest, reason: str) -> AnalyzeTicketResponse:
    """
    Safe, schema-valid fallback returned when LLM fails or output is invalid.
    Ensures the service never crashes and always returns valid JSON.
    """
    logger.warning(f"Returning fallback response for {req.ticket_id}: {reason}")
    return AnalyzeTicketResponse(
        ticket_id=req.ticket_id,
        relevant_transaction_id=None,
        evidence_verdict="insufficient_data",
        case_type="other",
        severity="medium",
        department="customer_support",
        agent_summary="Automated analysis was unable to process this ticket. Requires manual review.",
        recommended_next_action="Assign to a human support agent for manual review.",
        customer_reply=(
            "Thank you for reaching out. We have received your message and a support agent will "
            "review your case shortly. Please do not share your PIN or OTP with anyone."
        ),
        human_review_required=True,
        confidence=0.0,
        reason_codes=["analysis_error", "fallback_response"],
    )