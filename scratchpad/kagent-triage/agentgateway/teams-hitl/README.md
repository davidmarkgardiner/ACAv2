# Teams Human-in-the-Loop — Approval Gate for Triage Workflows

Integrate the bank's Teams bot service as the approval gate between our
kagent triage decisions and the actual remediation execution. Argo Workflows
pauses, bot delivers an Adaptive Card to the right people, their decision
flows back through Argo Events and either resumes or stops the workflow.

**Picked design:** Option A — Argo suspend/resume with **Argo Events as the
callback receiver**. No custom callback service. Reuses infrastructure we
already run.

## Why This Design

Three integration paths were considered. Ranked by ease and fit:

| | Option A (this doc) | Option B (direct to kagent) | Option C (via agentgateway) |
|---|---|---|---|
| New infrastructure | None — reuse Argo Events | None | Needs HTTPRoute + transformer |
| Security surface | Argo Events webhook, IP-allowlist from bot | kagent A2A exposed externally | agentgateway extended with non-AI route |
| Payload transformation | None | None | Bot callback ≠ OpenAI chat — sidecar |
| Remediation location | Same workflow that triaged | Separate process | Separate process |
| Audit trail | One Argo workflow = whole story | Split across systems | Split |
| Retry / timeout / rejection | Native Argo constructs | Build yourself | Build yourself |

Option A wins because Argo Events IS the callback service we'd otherwise
build. Zero custom code on our side; the bot sends an HTTP POST, the Sensor
resumes or stops the workflow.

## Architecture

```
Prometheus alert ──► Argo Events ──► Workflow starts
                                         │
                                         ▼
                        ┌── 1. triage (kagent agent via agentgateway)
                        │     returns JSON with proposed action + tier
                        ▼
                        ┌── 2. tier classifier
                        │     (remediation-tier-mapping ConfigMap)
                        ▼
                        │ T0/T1 → 5 (auto-execute)
                        │ T2/T3 → 3 (request approval)
                        │ T4    → 7 (create ticket, fail)
                        ▼
                        ┌── 3. POST request to Teams bot
                        │     returns approval_id
                        ▼
                        ┌── 4. SUSPEND workflow node (24h timeout)
                        │     ▲   ▲
                        │     │   │
                        │     │   │   ┌─ Teams user sees Adaptive Card
                        │     │   └───┤   Approve / Reject / (expire)
                        │     │       └─ bot POST callback ──┐
                        │     │                               │
                        │     │                               ▼
                        │     │    Argo Events EventSource (webhook)
                        │     │                               │
                        │     │                               ▼
                        │     │                        Sensor — decision=?
                        │     │                               │
                        │     │       ┌───────────────────────┤
                        │     │       │ approved              │ rejected
                        │     │       ▼                       ▼
                        │     │   resume workflow       stop workflow
                        │     │                               │
                        │     └───(decision=expired: suspend timeout fires)
                        ▼
                        ┌── 5. remediation agent executes the approved action
                        ▼
                        ┌── 6. verify + post outcome card to Teams
                        ▼
                        ┌── 7. (T4 only) create GitLab ticket, fail fast
```

## Can I Test This Without a Teams Bot?

Yes. The bot is just an HTTP service that:
1. Accepts a POST with approval details
2. Delivers an interactive UI somewhere
3. POSTs the decision back to a callback URL

Any of these work as stand-ins:

### Option T1 — Mock bot (fastest, fully automated)

Tiny Python service that auto-approves after N seconds, or exposes its own
`/decide?id=X&decision=approved` endpoint for manual triggering. See
`mock-bot/` in this folder. Good for:
- CI pipeline tests
- Unit testing the Sensor
- End-to-end workflow tests without human in the loop

### Option T2 — Slack with Interactive Messages

Slack Apps support "Block Kit" messages with Approve/Reject buttons. The
button click POSTs a payload to a Request URL you configure in the Slack App
settings. That Request URL becomes our Argo Events EventSource endpoint.

Flow:
```
Argo workflow → POST to Slack Incoming Webhook with a Block Kit message
                including actions (buttons)
User clicks Approve → Slack POSTs payload to our Request URL
                     (= argo-events callback endpoint)
Sensor reads Slack payload, extracts workflow_name + decision
→ resumes or stops workflow
```

The Slack payload shape is different from our "bot contract" shape, so the
Sensor needs a small `body.` path translation — e.g.
`body.actions[0].value` instead of `body.decision`.

### Option T3 — Discord with Message Components

Same pattern — Discord bot posts a message with button components. Button
clicks generate an "Interaction" POSTed to a configured webhook URL. That
webhook URL is our EventSource endpoint.

Discord requires the bot to respond within 3 seconds, so the initial
response is an ACK; the actual workflow operation happens async from the
Sensor.

### Option T4 — curl (unit test the Sensor)

Totally bypass the UI. Just POST directly to the EventSource webhook:

```bash
curl -sS -X POST http://argo-events-webhook.internal/approval-callback \
  -H "Content-Type: application/json" \
  -d '{
    "workflow_name": "net-triage-xyz123",
    "decision": "approved",
    "approver": "test@bank.com",
    "decided_at": "2026-04-24T10:00:00Z"
  }'
```

Argo Events passes this payload into the Sensor exactly as if a bot had
called it. Quick way to validate the Sensor logic, the resume/stop triggers,
and the workflow parameter mapping work correctly before you involve any
chat platform.

### Recommended progression

1. **Dev:** Option T4 (curl) to wire up Sensor logic
2. **Dev:** Option T1 (mock bot) for automated end-to-end tests
3. **Staging:** Option T2 (Slack) for a realistic human-in-loop test —
   cheap to spin up a Slack workspace, easier than Teams for dev cycles
4. **Production:** Real Teams bot via the bank's platform capability

All four share the same EventSource/Sensor on our side — only the payload
shape and callback URL change.

## Files In This Folder

| File | Purpose |
|---|---|
| `README.md` | You are here — design + integration options |
| `eventsource.yaml` | Argo Events webhook receiver for bot callbacks |
| `sensor.yaml` | Translates callbacks to Argo resume/stop operations |
| `istio-virtualservice.yaml` | Expose the callback webhook via the wildcard Istio Gateway |
| `istio-authorization-policy.yaml` | IP allow-list + default deny on the callback endpoint |
| `workflow-approval-template.yaml` | WorkflowTemplate snippets: request-approval + wait-for-approval + tier dispatch |
| `BOT-CONTRACT.md` | Spec to hand to the Teams bot team (POST shape, callback shape, auth, timeouts) |
| `mock-bot/` | Tiny FastAPI mock for dev/test without Teams/Slack/Discord |

## Deploy Sequence

### 1. Apply Argo Events components (one-off, long-lived)

```bash
kubectl apply -f eventsource.yaml
kubectl apply -f sensor.yaml

# Verify
kubectl get eventsource -n argo-events teams-hitl-callback
kubectl get sensor -n argo-events teams-hitl-sensor
kubectl get pods -n argo-events -l eventsource-name=teams-hitl-callback
```

### 2. Expose the EventSource via the wildcard Istio Gateway

Same pattern as agentgateway — reuse the existing shared wildcard Gateway in
`aks-istio-ingress` (or wherever your platform hosts it). The EventSource is
exposed at a specific hostname under the wildcard, e.g.
`hitl-callback.internal.bank.com`.

```bash
# Pick a hostname under your wildcard. Example: hitl-callback.<wildcard-domain>
# Find your existing wildcard Gateway:
kubectl get gateway.networking.istio.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.servers[*].hosts}{"\n"}{end}' \
  | grep '\*'

# Substitute REPLACE_* placeholders in istio-virtualservice.yaml
kubectl apply -f istio-virtualservice.yaml

# Restrict callbacks to the bot's egress IPs
# Substitute the bot CIDR in istio-authorization-policy.yaml first
kubectl apply -f istio-authorization-policy.yaml

# Verify Istio accepted the routing
istioctl proxy-config route -n aks-istio-ingress \
  deploy/aks-istio-ingressgateway-external --name https.443 \
  | grep hitl-callback
```

The callback URL you give the bot becomes:
`https://hitl-callback.<wildcard-domain>/approval-callback`

The workflow's `callback_url` parameter (in `workflow-approval-template.yaml`)
must match.

### 3. Update the triage WorkflowTemplate

Merge the snippets from `workflow-approval-template.yaml` into your existing
WorkflowTemplate (currently `aks-mgmt-stack/k8s-event-triage/...` or the
equivalent at work). Adds:
- `request-approval` step (POST to bot)
- `wait-for-approval` step (suspend with 24h timeout)
- Tier-based DAG dispatch

### 4. Register your callback URL with the Teams bot platform

Hand `BOT-CONTRACT.md` to the bot team. They give you a bot endpoint URL
(the target of step 3's POST) and you give them your callback URL. Test
with one end-to-end T2 flow before rolling out to more actions.

### 5. Smoke test

```bash
# Submit a fake workflow that exercises the approval path
argo submit test-approval-workflow.yaml -n argo

# Watch it pause at wait-for-approval
argo get <workflow-name> -n argo

# Click Approve in Teams → watch it resume
argo get <workflow-name> -n argo
# Expected: workflow moves past wait-for-approval to remediation step
```

## Security Considerations

| Concern | Mitigation |
|---|---|
| Unauthorised party POSTs to EventSource | Istio AuthorizationPolicy restricting source IP to bot service + shared secret in header (Sensor validates) |
| Replay of old callbacks | Include `approval_id` nonce; Sensor rejects duplicates (use Argo Events filter) |
| Bot compromise → fake approvals | Bot-signed callback (HMAC header); Sensor verifies signature before triggering |
| Approval survives workflow retry | Each approval has a unique `approval_id`; match to specific workflow run, not workflow name |
| Teams card leak reveals operational details | Keep card content high-level; redact secrets, PII, cluster internals; put detail behind a "view in Argo" link |

## Failure Modes + How Argo Handles Them

| Failure | What happens |
|---|---|
| Bot service unreachable at POST time | `request-approval` step fails; workflow fails fast with a clear error. No silent hang. |
| User never clicks | 24h suspend timeout fires → step fails → workflow fails. Alert on workflow failure. |
| Bot callback never arrives despite user click | Same as above — 24h timeout. Check bot service logs. |
| User clicks Reject | Sensor's `stop` trigger fires → workflow fails fast. Outcome: no remediation. |
| Duplicate callback (user clicks twice) | Argo Events dedupes by event; second call is no-op. Optional: Sensor filter on approval_id. |
| Argo controller restart during suspend | Suspend state persists to etcd; resume works normally after restart. |

## Open Questions (Work These Out Before Production)

1. **Approver group mapping** — how does the workflow know who to ask for
   T2 vs T3 approval? Options:
   - Fixed list in the WorkflowTemplate
   - ConfigMap keyed by `namespace_label → approver_group`
   - Derived from the affected namespace's owner metadata
   Bank will have an opinion.

2. **Break-glass for incident response** — if a P1 is active at 2am, does
   senior on-call need a T0 bypass path? Document the procedure; add a
   `x-break-glass: true` header on the approval request that the bot
   escalates to the on-call channel + logs extra audit.

3. **Approval expiry behaviour for T2 vs T3** — T2 might accept 4h
   expiry, T3 might require 1h (force escalation). Parameterise per-tier.

4. **Reject with reason** — should the Adaptive Card capture free-text
   comment on reject and surface it in the workflow failure? Useful for
   learning; adds a round-trip.

5. **Retry after reject** — if someone rejects, does the workflow die
   entirely or can it re-triage and propose a different action? Default:
   die. Re-triage requires a follow-up alert.

## Related Docs

| Topic | File |
|---|---|
| Tier mapping (what's T0/T1/T2/T3/T4) | `../kagent-agents/networking-triage-agent/tier-mapping-configmap.yaml` |
| Triage agent producing the structured JSON | `../kagent-agents/networking-triage-agent/agent.yaml` |
| Cross-bank orchestration pattern | `../cross-bank-integration/README.md` |
| Istio VirtualService pattern for exposing internal endpoints | `../agentgateway/istio-virtualservice.yaml` |
