# Bot Contract — What The Teams Bot Service Must Implement

This is the contract between the Argo-Workflow triage system and the bot
platform capability. Hand this to the bot team so both sides agree on the
POST shape, callback shape, auth, and timeouts.

## Endpoint 1 — Bot Receives Approval Request

**URL:** provided by bot platform (e.g. `https://teams-bot.internal.bank.com/approvals`)

**Method:** `POST`

**Auth:** Bearer token provisioned for the triage-workflow service identity
(stored as secret `teams-bot-token` in `argo` namespace).

**Request body:**
```json
{
  "workflow_name":       "net-triage-abc123",
  "workflow_namespace":  "argo",
  "callback_url":        "https://hitl-callback.internal.bank.com/approval-callback",
  "tier":                "T2",
  "action":              "kubectl apply -f networkpolicy-dns-fix.yaml -n payments-app",
  "target":              "payments-app/networkpolicy/dns-egress",
  "rationale":           "CoreDNS traffic blocked by restrictive egress policy; diagnosed by networking-triage-agent (evidence in workflow artifacts).",
  "expiry_seconds":      86400
}
```

**Optional fields** the bot may want:
- `approver_group` — which distribution list / Teams channel to target
- `severity` — `P1` / `P2` / etc. for card styling
- `trace_id` — OTEL trace link back to observability
- `workflow_url` — deep link to the Argo UI for this workflow

**Response:** `200 OK` within 5 seconds:
```json
{
  "approval_id":   "0194f8c2-7a3b-7e2d-b1a0-abc123def456",
  "status":        "queued",
  "delivered_to":  "team-platform-sre-channel"
}
```

The `approval_id` is a nonce the bot generates. It must be unique per
request (workflow retries generate new requests). Used for audit and for
deduping callbacks.

**On error (4xx/5xx):** workflow step fails immediately; alert fires. Bot
should not block on delivery — queue internally and return 200 once the
request is accepted for processing.

## Endpoint 2 — Bot POSTs Callback When Decision Is Made

**URL:** `callback_url` field from the original request (our Argo Events
endpoint). Always per-request; do not hardcode.

**Method:** `POST`

**Auth:** HMAC signature in `X-Bot-Signature` header (SHA-256 of body using
shared secret). Argo Events filters / Sensor condition rejects mismatched
signatures. Alternative: mTLS from a known client certificate.

**Callback body (all decisions):**
```json
{
  "approval_id":       "0194f8c2-7a3b-7e2d-b1a0-abc123def456",
  "workflow_name":     "net-triage-abc123",
  "workflow_namespace":"argo",
  "decision":          "approved",
  "approver":          "jane.smith@bank.com",
  "decided_at":        "2026-04-24T14:32:18Z",
  "comment":           "Looks fine, approved on 1st glance"
}
```

**`decision` values** (enum — Sensor has explicit handlers for each):
- `approved` — Sensor resumes the workflow
- `rejected` — Sensor stops the workflow (fails it)
- `expired` — Sensor stops the workflow (no-op if the workflow's own suspend
  timeout already fired)

**`approver`** must be the resolved user identity, not the Teams user ID.
Use email or UPN — this lands in Argo annotations for audit.

**`comment`** is optional. If present, attach as workflow annotation.

**Response:** `200 OK` within 2 seconds. Argo Events acks; any further
delivery attempts from the bot are deduplicated by `approval_id`.

## Timeouts + Retry

| Event | Timeout | Handling |
|---|---|---|
| Bot accepts the POST | 5s | Workflow step fails otherwise |
| Bot delivers card to Teams | Best-effort | Bot queues internally |
| User makes decision | `expiry_seconds` from request | Bot sends `decision: expired` |
| Bot posts callback | Retry up to 3× with backoff | EventSource de-dupes by `approval_id` |
| Argo suspend duration | `expiry_seconds + 60s` | Safety net; fails the step if no callback |

## Deduplication

Callbacks are deduplicated by `approval_id`. If the bot retries a callback
POST due to transient network issues, Argo Events will accept the first one
and ignore the rest (Sensor filter on `approval_id`).

**Workflow retries generate a new request + new approval_id.** Bot must not
reuse an old approval_id across workflow retries.

## Card Content — Guidance for Bot Implementer

The bot renders an Adaptive Card from the request fields. Recommended layout:

```
╔════════════════════════════════════════╗
║ 🟠 SRE APPROVAL NEEDED · Tier T2       ║
║                                        ║
║ Action:   kubectl apply -f ...         ║
║ Target:   payments-app/networkpolicy   ║
║                                        ║
║ Rationale:                             ║
║ CoreDNS traffic blocked by restrictive ║
║ egress policy; diagnosed by...         ║
║                                        ║
║ Workflow: net-triage-abc123 [view]     ║
║ Expires:  in 23h 57m                   ║
║                                        ║
║  [ Approve ]  [ Reject ]  [ Comment ]  ║
╚════════════════════════════════════════╝
```

**Do not** include:
- Secret values or tokens (even redacted)
- Full pod logs (summary only)
- PII from incident data
- Internal IP addresses or credentials

**Do** include:
- Link back to the Argo UI for the user to dig deeper
- Link to the triage agent's full JSON report (artifact URL)
- Human-readable action description, not just the raw kubectl command

## Test Fixtures

To test the bot's implementation before integrating with Argo:

**Test request (Bot Endpoint 1):**
```bash
curl -X POST https://teams-bot.internal.bank.com/approvals \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "workflow_name": "test-approval-001",
    "workflow_namespace": "argo",
    "callback_url": "https://httpbin.org/post",
    "tier": "T2",
    "action": "kubectl rollout restart deploy/example",
    "target": "default/deployment/example",
    "rationale": "Test approval request — no real remediation",
    "expiry_seconds": 300
  }'
```

**Test callback (what the bot will send us):**
```bash
# Should be equivalent to what Argo Events receives
curl -X POST https://hitl-callback.internal.bank.com/approval-callback \
  -H "Content-Type: application/json" \
  -H "X-Bot-Signature: <hmac>" \
  -d '{
    "approval_id": "test-001",
    "workflow_name": "test-approval-001",
    "workflow_namespace": "argo",
    "decision": "approved",
    "approver": "test-user@bank.com",
    "decided_at": "2026-04-24T14:00:00Z"
  }'
```

## Security Requirements

| Control | Implementation |
|---|---|
| Authentication — bot → triage | Bearer token in `Authorization: Bearer ...` header; token from Azure Key Vault; rotated quarterly |
| Authentication — triage → bot | Same mechanism from the reverse direction (callback POST) |
| Integrity | HMAC signature on callback body (`X-Bot-Signature`) |
| Replay protection | `approval_id` nonce, Argo Events deduplication |
| TLS | Both endpoints behind corp-CA TLS; no HTTP fallback |
| Network | Ingress IP-allowlisted to known bot / Argo Events source networks where possible |
| Audit | Every callback logs to workflow annotations + Loki with approver, decision, reason |

## Open Items for the Bot Team

1. **Token issuance + rotation** — how we obtain the Bearer token (Azure
   Key Vault integration? Static secret?). Align with bank standard.
2. **Approver group selection** — single group per tier, or routing based
   on affected namespace owner?
3. **Bot queue durability** — if bot service restarts between receiving
   the request and delivering the card, does the request survive?
4. **Card template localisation** — English only, or multi-language?
5. **Audit retention** — how long do approval records live? Align with
   the workflow retention policy.
