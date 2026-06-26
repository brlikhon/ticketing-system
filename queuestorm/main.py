import logging
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import ValidationError

import json

from models import AnalyzeTicketRequest, AnalyzeTicketResponse
from analyzer import analyze_ticket

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="QueueStorm Investigator",
    description="AI/API support copilot for digital finance platforms",
    version="1.0.0",
)

# ── CORS ────────────────────────────────────────────────────────────────────
# The dashboard (`queuestorm-ui.html`) is typically opened from `file://` or a
# different origin than the API. Permissive CORS is fine for an internal demo
# tool; tighten before exposing publicly.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Static UI mount ────────────────────────────────────────────────────────
# Serves `queuestorm-ui.html` and any sibling assets from /ui.
_UI_DIR = Path(__file__).parent / "ui"
if _UI_DIR.exists():
    app.mount("/ui", StaticFiles(directory=str(_UI_DIR), html=True), name="ui")


# ── Health Check ────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok"}


# ── Main Endpoint ───────────────────────────────────────────────────────────

@app.post("/analyze-ticket", response_model=AnalyzeTicketResponse)
async def analyze_ticket_endpoint(req: AnalyzeTicketRequest):
    result = analyze_ticket(req)
    return result


@app.exception_handler(json.JSONDecodeError)
async def json_decode_handler(request: Request, exc: json.JSONDecodeError):
    return JSONResponse(
        status_code=400,
        content={"error": "Invalid JSON body", "detail": "Request body could not be parsed as JSON."},
    )


# ── Error Handlers ──────────────────────────────────────────────────────────

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=400,
        content={"error": "Invalid request", "detail": str(exc)[:500]},
    )

@app.exception_handler(ValueError)
async def value_error_handler(request: Request, exc: ValueError):
    return JSONResponse(
        status_code=422,
        content={"error": "Semantically invalid input", "detail": str(exc)[:500]},
    )

@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    logger.error(f"Unhandled exception: {exc}", exc_info=True)
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error. Please try again."},
    )