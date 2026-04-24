# Mock Bot — Local Test Harness for Approval Flow

Tiny FastAPI service that impersonates the Teams bot for testing the
approval gate end-to-end without needing the real bot service.

Run it locally or deploy to your dev cluster. It exposes:

- `POST /approvals` — matches the bot's Endpoint 1. Accepts approval
  requests, logs them, returns an approval_id.
- `GET /pending` — lists outstanding approvals.
- `POST /decide/<approval_id>?decision=<approved|rejected|expired>` —
  simulates a user clicking the button. POSTs the callback to the
  registered `callback_url`.
- `POST /auto-approve/<approval_id>` — shortcut for CI: same as
  `/decide?decision=approved`.

## Use cases

| Scenario | Command |
|---|---|
| Wire up the EventSource first (no bot needed) | `curl` directly to the Argo Events webhook — see `../README.md` Option T4 |
| Test the full workflow with a real-ish bot but no human | Run this mock, submit a workflow, auto-approve after N seconds |
| CI pipeline test | Run this mock + workflow + auto-decide endpoint |
| Manual human-in-loop testing | Run this mock, submit a workflow, call `/pending` to see what's waiting, call `/decide` when you're ready |

## Run locally

```bash
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8080
```

Then in another terminal:
```bash
# Submit an approval request (as the Argo workflow would)
curl -X POST http://localhost:8080/approvals \
  -H "Content-Type: application/json" \
  -d '{
    "workflow_name": "test-001",
    "callback_url": "http://host.docker.internal:12000/approval-callback",
    "action": "kubectl rollout restart deploy/example",
    "target": "default/deployment/example",
    "rationale": "Test run",
    "tier": "T2",
    "expiry_seconds": 300
  }'

# See what's pending
curl http://localhost:8080/pending

# Approve it (triggers callback POST to Argo Events)
curl -X POST "http://localhost:8080/decide/<approval_id>?decision=approved"
```

## Deploy to a dev cluster

See `deployment.yaml`. Runs as a Deployment + Service in the `argo` namespace.

```bash
kubectl apply -f deployment.yaml

# Port-forward for local testing
kubectl port-forward -n argo svc/mock-bot 8080:8080
```

Point your test workflow's `bot_endpoint` parameter at
`http://mock-bot.argo:8080/approvals` (in-cluster) and
`callback_url` at your Argo Events endpoint as normal.

## Five-minute smoke test

Once the mock-bot is deployed and the EventSource + Sensor from the parent
folder are applied, run this on a dev cluster:

```bash
cd ai-platform/teams-hitl/mock-bot

# Approve path — should succeed
./smoke-test.sh

# Reject path — should fail the workflow fast
./smoke-test.sh --reject

# Expiry path — let the mock's internal timer fire
./smoke-test.sh --expire
```

`smoke-test.sh` does:
1. Pre-flight: checks EventSource, Sensor, mock-bot are all in place
2. Port-forwards mock-bot to localhost:18080
3. Submits `test-approval-workflow.yaml`
4. Waits for the workflow to reach the suspend state
5. Fetches the approval_id from `/pending`
6. POSTs a decision to `/decide/<id>`
7. Watches Argo until the workflow reaches a terminal state
8. Asserts the outcome matches the decision

Expected output on success:
```
✓ all components present
✓ mock-bot reachable
✓ workflow test-approval-xxxxx submitted
✓ workflow suspended at wait-for-approval node (after 8s)
✓ found approval_id: 0194...
✓ decision dispatched
✓ workflow SUCCEEDED (approval path completed)
✓ PASS: approve path resumed the workflow
```

If any step fails, the script prints `argo get` for the workflow so you can
debug from there. Common failure modes:

| Symptom | Likely cause |
|---|---|
| "EventSource missing" | Apply `../eventsource.yaml` first |
| "mock-bot not responding" | `kubectl get pods -n argo -l app=mock-bot` — check logs |
| Workflow stuck at suspend after 5 min | Sensor isn't firing — check sensor logs: `kubectl logs -n argo-events -l sensor-name=teams-hitl-sensor` |
| Workflow fails at request-approval | `argo logs -n argo <wf-name>` — bot endpoint unreachable from pod network? |

## What this mocks vs what it doesn't

| Aspect | Mock | Real bot |
|---|---|---|
| Accepts approval request | ✅ | ✅ |
| Returns approval_id | ✅ | ✅ |
| Delivers to a chat UI | ❌ (CLI only) | ✅ (Adaptive Card in Teams) |
| Enforces approver identity | ❌ (anyone with curl can approve) | ✅ (Teams auth) |
| HMAC signs callbacks | ❌ (flag to enable) | ✅ |
| Expires unanswered requests | ✅ (background task) | ✅ |
| Multi-approver logic (T3) | ❌ | ✅ |

Good enough for wiring up the Argo side of things. Swap to the real bot once
both ends of the contract are validated.
