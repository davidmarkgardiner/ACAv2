#!/usr/bin/env bash
# Smoke test — exercises the full approval gate end-to-end:
#
#   Argo Workflow → mock-bot → callback → Argo Events → Sensor → resume
#
# Runs a test workflow that suspends at the approval gate, then approves
# (or rejects, via --reject) via the mock-bot API, and watches Argo resume
# or stop the workflow accordingly.
#
# Expected runtime: ~60 seconds for happy path.
#
# Prereqs:
#   - ai-platform/teams-hitl/eventsource.yaml applied
#   - ai-platform/teams-hitl/sensor.yaml applied
#   - mock-bot deployed: kubectl apply -f deployment.yaml
#   - kubectl context pointed at the cluster with Argo + Argo Events + mock-bot
#   - argo CLI installed (https://github.com/argoproj/argo-workflows/releases)
#
# Usage:
#   ./smoke-test.sh                 # approve path
#   ./smoke-test.sh --reject        # reject path
#   ./smoke-test.sh --expire        # let it time out
# ---

set -euo pipefail

DECISION="approved"
case "${1:-}" in
  --reject)  DECISION="rejected" ;;
  --expire)  DECISION="expire" ;;
  --approve) DECISION="approved" ;;
  "")        DECISION="approved" ;;
  *)         echo "Unknown flag: $1 (use --approve | --reject | --expire)"; exit 1 ;;
esac

NS_ARGO=${NS_ARGO:-argo}
NS_ARGO_EVENTS=${NS_ARGO_EVENTS:-argo-events}
MOCK_BOT_PORT=${MOCK_BOT_PORT:-18080}     # host side of port-forward

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[1;34m'; N='\033[0m'

echo -e "${B}══════ Smoke test: approval gate ══════${N}"
echo "Decision under test: ${DECISION}"
echo

# ─── 1. Pre-flight ────────────────────────────────────────────────────────
echo -e "${B}[1/6] Pre-flight checks${N}"

kubectl get eventsource -n "$NS_ARGO_EVENTS" teams-hitl-callback >/dev/null 2>&1 \
  || { echo -e "${R}✗ EventSource teams-hitl-callback missing in $NS_ARGO_EVENTS${N}"; exit 1; }
kubectl get sensor -n "$NS_ARGO_EVENTS" teams-hitl-sensor >/dev/null 2>&1 \
  || { echo -e "${R}✗ Sensor teams-hitl-sensor missing in $NS_ARGO_EVENTS${N}"; exit 1; }
kubectl get deploy -n "$NS_ARGO" mock-bot >/dev/null 2>&1 \
  || { echo -e "${R}✗ mock-bot Deployment missing in $NS_ARGO${N}"; exit 1; }

kubectl wait --for=condition=available deploy/mock-bot -n "$NS_ARGO" --timeout=30s >/dev/null
echo -e "${G}✓ all components present${N}"
echo

# ─── 2. Port-forward mock-bot ─────────────────────────────────────────────
echo -e "${B}[2/6] Port-forwarding mock-bot :${MOCK_BOT_PORT} → svc/mock-bot:8080${N}"
kubectl port-forward -n "$NS_ARGO" svc/mock-bot "${MOCK_BOT_PORT}:8080" \
  > /tmp/mock-bot-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 2

curl -sS "http://localhost:${MOCK_BOT_PORT}/health" | jq . >/dev/null \
  || { echo -e "${R}✗ mock-bot not responding on :${MOCK_BOT_PORT}${N}"; exit 1; }
echo -e "${G}✓ mock-bot reachable${N}"
echo

# ─── 3. Submit test workflow ──────────────────────────────────────────────
echo -e "${B}[3/6] Submitting test workflow${N}"
WF_FILE="$(dirname "$0")/test-approval-workflow.yaml"
[[ -f "$WF_FILE" ]] || { echo -e "${R}✗ test-approval-workflow.yaml not found at $WF_FILE${N}"; exit 1; }

WF_NAME=$(argo submit -n "$NS_ARGO" "$WF_FILE" -o name | sed 's|^workflow/||' | tr -d '[:space:]')
echo -e "${G}✓ workflow ${WF_NAME} submitted${N}"
echo

# ─── 4. Wait for suspend ──────────────────────────────────────────────────
echo -e "${B}[4/6] Waiting for workflow to reach the suspend state${N}"
for i in {1..30}; do
  PHASE=$(kubectl get wf -n "$NS_ARGO" "$WF_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  NODE_SUSP=$(kubectl get wf -n "$NS_ARGO" "$WF_NAME" -o json 2>/dev/null \
              | jq -r '.status.nodes // {} | to_entries[] | select(.value.type=="Suspend") | .value.phase' | head -1)
  if [[ "$NODE_SUSP" == "Running" ]]; then
    echo -e "${G}✓ workflow suspended at wait-for-approval node (after ${i}s)${N}"
    break
  fi
  if [[ "$PHASE" == "Failed" || "$PHASE" == "Error" ]]; then
    echo -e "${R}✗ workflow failed before reaching suspend${N}"
    argo get -n "$NS_ARGO" "$WF_NAME"
    exit 1
  fi
  sleep 2
done

# ─── 5. Fetch approval_id and decide via mock-bot ─────────────────────────
echo -e "${B}[5/6] Fetching pending approval from mock-bot${N}"

sleep 2  # let the callback queue settle
PENDING=$(curl -sS "http://localhost:${MOCK_BOT_PORT}/pending")
APP_ID=$(echo "$PENDING" | jq -r --arg wf "$WF_NAME" '.[] | select(.workflow_name==$wf) | .approval_id' | head -1)

if [[ -z "$APP_ID" ]]; then
  echo -e "${R}✗ no pending approval found for workflow ${WF_NAME}${N}"
  echo "Mock-bot /pending returned:"
  echo "$PENDING" | jq .
  exit 1
fi
echo -e "${G}✓ found approval_id: ${APP_ID}${N}"

if [[ "$DECISION" == "expire" ]]; then
  echo -e "${Y}Simulating expiry — waiting for mock-bot's internal expiry timer (may take a while)${N}"
  echo "Skipping active decision; will watch workflow suspend timeout instead"
else
  echo "Sending decision=${DECISION} to mock-bot..."
  curl -sS -X POST "http://localhost:${MOCK_BOT_PORT}/decide/${APP_ID}?decision=${DECISION}" | jq .
  echo -e "${G}✓ decision dispatched${N}"
fi
echo

# ─── 6. Watch workflow complete ───────────────────────────────────────────
echo -e "${B}[6/6] Watching workflow for terminal state${N}"
# Expected outcomes:
#   approved → Succeeded
#   rejected → Failed (workflow stopped)
#   expire   → Failed (suspend timeout)

for i in {1..60}; do
  PHASE=$(kubectl get wf -n "$NS_ARGO" "$WF_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  case "$PHASE" in
    Succeeded)
      echo -e "${G}✓ workflow SUCCEEDED (approval path completed)${N}"
      argo get -n "$NS_ARGO" "$WF_NAME" | head -25
      case "$DECISION" in
        approved) echo -e "${G}✓ PASS: approve path resumed the workflow${N}"; exit 0 ;;
        *)        echo -e "${R}✗ unexpected success for decision=${DECISION}${N}"; exit 1 ;;
      esac
      ;;
    Failed|Error)
      echo -e "${Y}workflow ended: ${PHASE}${N}"
      argo get -n "$NS_ARGO" "$WF_NAME" | head -25
      case "$DECISION" in
        rejected) echo -e "${G}✓ PASS: reject path stopped the workflow${N}"; exit 0 ;;
        expire)   echo -e "${G}✓ PASS: expire path timed out the workflow${N}"; exit 0 ;;
        *)        echo -e "${R}✗ FAIL: workflow stopped but decision=${DECISION} expected success${N}"; exit 1 ;;
      esac
      ;;
  esac
  sleep 5
done

echo -e "${R}✗ FAIL: workflow did not reach a terminal state within 5 min${N}"
argo get -n "$NS_ARGO" "$WF_NAME"
exit 1
