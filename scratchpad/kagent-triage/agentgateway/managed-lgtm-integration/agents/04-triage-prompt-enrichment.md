# Agent Anomaly Triage — Prompt Enrichment Pattern

When an agent anomaly alert from `03-agent-anomaly-rules.yaml` fires and
flows through the Event Hub bridge, the existing
`../alerts/workflow-template-alerts.yaml` workflow gets a small alert
payload. For agent-specific alerts (label `anomaly_type` set), we want to
**enrich the KAgent triage prompt** by querying managed Mimir/Loki for
context the alert payload alone can't carry.

This file documents the pattern. Implementation is a small change to
`workflow-template-alerts.yaml` — a `fetch-agent-context` step that runs
*before* the KAgent A2A call when `anomaly_type` is set.

---

## What context to fetch per anomaly_type

| `anomaly_type` label | Extra context to fetch | Mimir / Loki query |
|---------------------|------------------------|-------------------|
| `token_burst` | Token rate trend (last 1h, 5m windows) | `rate(agentgateway_gen_ai_client_token_usage_sum{model="X"}[5m])[1h:5m]` |
| `cost_spike` | Top 3 sessions by token count | `topk(3, sum by (session_id) (rate(...)))` |
| `silent_failure` | Last 50 error log lines | `{namespace="kagent",agent="X"} |~ "error" | tail 50` |
| `cohort_outlier` | Same metric for sibling agents (proves cohort-vs-one) | `kagent:error_rate:per_agent` |
| `latency_long_tail` | Slow request log entries (last 10) | `{agent="X"} |~ "duration.*[3-9][0-9]s"` |
| `backend_flap` | Backend pod restart count, recent events | `kube_pod_container_status_restarts_total` + Loki K8s events |
| `tool_call_loop` | Tool call sequence (last 100 entries) | `{namespace="kagent",agent="X"} |~ "tool_call"` |
| `refusal_burst` | Sample refusal messages + the prompt that triggered them | `{agent="X"} |~ "I cannot"` |
| `auth_failure` | Recent auth header / model config changes (audit log) | `{namespace="agentgateway-system"} |~ "config_reload"` |

---

## Pattern: a single Argo step that branches by anomaly_type

Add this template to `../alerts/workflow-template-alerts.yaml` and call it
from the DAG between `parse-alerts` and `triage-each-alert`:

```yaml
- name: fetch-agent-context
  inputs:
    parameters:
      - name: alert
  script:
    image: badouralix/curl-jq:alpine
    command: [sh]
    source: |
      set -eu
      ALERT='{{inputs.parameters.alert}}'
      ANOMALY=$(echo "$ALERT" | jq -r '.labels.anomaly_type // ""')
      AGENT=$(echo "$ALERT" | jq -r '.labels.agent // ""')
      MODEL=$(echo "$ALERT" | jq -r '.labels.gen_ai_request_model // ""')

      MIMIR_URL=$(cat /etc/lgtm-config/MIMIR_QUERY_URL)
      LOKI_URL=$(cat /etc/lgtm-config/LOKI_QUERY_URL)
      TOKEN=$(cat /etc/lgtm-config/READ_TOKEN)
      TENANT=$(cat /etc/lgtm-config/TENANT)

      query_mimir() {
        curl -sf -G "${MIMIR_URL}/api/v1/query" \
          -H "X-Scope-OrgID: ${TENANT}" \
          -H "Authorization: Bearer ${TOKEN}" \
          --data-urlencode "query=$1"
      }

      query_loki() {
        curl -sf -G "${LOKI_URL}/loki/api/v1/query_range" \
          -H "X-Scope-OrgID: ${TENANT}" \
          -H "Authorization: Bearer ${TOKEN}" \
          --data-urlencode "query=$1" \
          --data-urlencode "limit=20" \
          --data-urlencode "start=$(date -u -d '1 hour ago' +%s)000000000" \
          --data-urlencode "end=$(date -u +%s)000000000"
      }

      CONTEXT="{}"

      case "$ANOMALY" in
        token_burst|cost_spike)
          CONTEXT=$(query_mimir "agentgateway:tokens_per_minute:current{gen_ai_request_model=\"$MODEL\"}")
          ;;
        silent_failure|cohort_outlier|latency_long_tail)
          CONTEXT=$(query_loki "{namespace=\"kagent\",agent=\"$AGENT\"} |~ \"(?i)error|warn\"")
          ;;
        tool_call_loop)
          CONTEXT=$(query_loki "{namespace=\"kagent\",agent=\"$AGENT\"} |~ \"tool_call\"")
          ;;
        refusal_burst|auth_failure)
          CONTEXT=$(query_loki "{namespace=\"kagent\",agent=\"$AGENT\"} |~ \"(?i)cannot|forbidden|unauthorized\"")
          ;;
        backend_flap)
          CONTEXT=$(query_mimir "rate(envoy_cluster_upstream_cx_destroy_remote_with_active_rq[5m])")
          ;;
      esac

      # Compact context to keep KAgent prompt small (< 4kb)
      echo "$CONTEXT" | jq -c '. | tostring' > /tmp/context.json
  outputs:
    parameters:
      - name: context
        valueFrom:
          path: /tmp/context.json
  volumeMounts:
    - name: lgtm-config
      mountPath: /etc/lgtm-config
```

Then the existing `triage-one-alert` template becomes:

```yaml
- name: triage-one-alert
  inputs:
    parameters:
      - name: alert
      - name: context     # <-- new
  script:
    # Build the KAgent prompt with the extra context spliced in:
    PROMPT="...existing prompt template...
    Recent observability context (managed LGTM):
    {{inputs.parameters.context}}"
```

---

## Why this matters

A static alert says "agent X has 50% error rate". Without enrichment,
KAgent's only hint is the alert summary — same as a human seeing only the
PagerDuty title. With enrichment, KAgent sees the actual error log lines,
the cohort comparison, and the recent prompt history. That's the difference
between "I don't know, here's a kubectl command to run" and "Here's the
specific tool that's looping; here's the patch."

Same pattern works for non-agent alerts too (fetch pod logs / events for
`PodCrashLooping`, etc.) but agent alerts benefit most because their
behaviour is opaque without the LLM-call-level signals.

---

## ConfigMap for read tokens

The triage workflow needs read access to managed Mimir + Loki (separate
from the *write* tokens Alloy uses). Stored as a separate ConfigMap so
they can rotate independently:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: lgtm-query-config
  namespace: argo-events
data:
  MIMIR_QUERY_URL: "https://mimir.lgtm.example.com"
  LOKI_QUERY_URL:  "https://loki.lgtm.example.com"
  TENANT:          "ai-platform"
---
apiVersion: v1
kind: Secret
metadata:
  name: lgtm-query-token
  namespace: argo-events
type: Opaque
stringData:
  READ_TOKEN: "{{ from platform team — read-only token }}"
```

If the platform team uses different auth mechanisms for write vs read
(common — Alloy uses workload identity, queries use bearer tokens), the
two tokens can have very different rotation cadences without affecting
each other.
