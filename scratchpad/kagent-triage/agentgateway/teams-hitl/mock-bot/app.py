"""Mock Teams bot for testing the approval flow end-to-end without Teams.

Implements both halves of the contract from BOT-CONTRACT.md:
- POST /approvals: receives approval requests from the Argo workflow
- /decide/<id>?decision=...: simulates a user clicking a button; POSTs
  the callback to the workflow's registered callback_url

No auth, no HMAC, no persistence. Dev/test only.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import datetime, timezone
from typing import Literal

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mock-bot")

app = FastAPI(title="Mock Teams Bot", version="0.1.0")

# In-memory store of pending approvals. Not persistent; lost on restart.
pending: dict[str, dict] = {}


class ApprovalRequest(BaseModel):
    workflow_name: str
    workflow_namespace: str = "argo"
    callback_url: str
    action: str
    target: str
    rationale: str
    tier: str = "T2"
    expiry_seconds: int = 86400


class ApprovalResponse(BaseModel):
    approval_id: str
    status: str
    delivered_to: str = "mock-cli"


@app.post("/approvals", response_model=ApprovalResponse)
async def receive_approval_request(req: ApprovalRequest) -> ApprovalResponse:
    approval_id = str(uuid.uuid4())
    pending[approval_id] = {
        **req.model_dump(),
        "approval_id": approval_id,
        "received_at": datetime.now(timezone.utc).isoformat(),
    }
    log.info(
        "approval queued id=%s wf=%s tier=%s action=%r",
        approval_id,
        req.workflow_name,
        req.tier,
        req.action[:80],
    )

    # Schedule expiry
    asyncio.create_task(_expire_later(approval_id, req.expiry_seconds))

    return ApprovalResponse(approval_id=approval_id, status="queued")


@app.get("/pending")
def list_pending() -> list[dict]:
    """List every outstanding approval request (for dev inspection)."""
    return list(pending.values())


@app.post("/decide/{approval_id}")
async def decide(
    approval_id: str,
    decision: Literal["approved", "rejected", "expired"] = "approved",
    approver: str = "mock-user@test.local",
    comment: str | None = None,
) -> dict:
    """Simulate a user clicking a button in Teams."""
    if approval_id not in pending:
        raise HTTPException(status_code=404, detail="unknown approval_id")

    req = pending.pop(approval_id)
    await _post_callback(req, decision, approver, comment)
    return {"approval_id": approval_id, "decision": decision, "approver": approver}


@app.post("/auto-approve/{approval_id}")
async def auto_approve(approval_id: str) -> dict:
    """CI shortcut — same as /decide?decision=approved."""
    return await decide(approval_id, "approved", "ci-auto-approver")


async def _expire_later(approval_id: str, seconds: int) -> None:
    await asyncio.sleep(seconds)
    if approval_id in pending:
        req = pending.pop(approval_id)
        log.info("approval expired id=%s wf=%s", approval_id, req["workflow_name"])
        await _post_callback(req, "expired", "expiry-daemon", None)


async def _post_callback(
    req: dict,
    decision: str,
    approver: str,
    comment: str | None,
) -> None:
    body = {
        "approval_id": req["approval_id"],
        "workflow_name": req["workflow_name"],
        "workflow_namespace": req.get("workflow_namespace", "argo"),
        "decision": decision,
        "approver": approver,
        "decided_at": datetime.now(timezone.utc).isoformat(),
    }
    if comment:
        body["comment"] = comment

    url = req["callback_url"]
    log.info("callback POST → %s body=%s", url, body)

    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            r = await client.post(url, json=body)
            r.raise_for_status()
            log.info("callback ok id=%s status=%d", req["approval_id"], r.status_code)
        except Exception as exc:
            log.error("callback FAILED id=%s err=%s", req["approval_id"], exc)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "pending": len(pending)}
