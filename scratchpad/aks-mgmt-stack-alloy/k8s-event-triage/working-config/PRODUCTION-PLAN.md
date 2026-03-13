# Production Deployment Plan — Enhanced K8s Event Triage Pipeline

> **Cluster:** aks-event-triage-dev (promote to aks-event-triage-prod)
> **Current state:** PoC running. Alloy → Event Hub → Argo Events → `parse-and-log` workflow.
> **Target state:** Full LLM-assisted triage with Gitea issue creation, multi-namespace coverage, HA EventBus.
> **Document version:** 2026-03-12

---

## Table of Contents

1. [Overview & Architecture Delta](#overview)
2. [Deployment Order](#deployment-order)
3. [Scaling](#scaling)
4. [Monitoring](#monitoring)
5. [Rollback Procedures](#rollback)
6. [Gotchas & Hard Rules](#gotchas)
7. [Go/No-Go Checklist](#go-nogo)

---

## 1. Overview & Architecture Delta <a name="overview"></a>

### Current PoC State (as verified 2026-03-12)

```
Alloy (monitoring/alloy)
  └─► Azure Event Hub Kafka [k8s-events topic]
        └─► EventSource: eventhub-k8s-events (argo-events)
              └─► JetStream EventBus: eventbus-default-js-0 [1 replica]
                    └─► Sensor: k8s-event-triage (rate: 5/min)
                          └─► WorkflowTemplate: k8s-event-triage
                                └─► parse-and-log step (stub)
```

### Target Production State

```
Alloy (monitoring/alloy) — multi-namespace watch
  └─► Azure Event Hub Kafka [k8s-events topic]
        └─► EventSource: eventhub-k8s-events (argo-events)
              └─► JetStream EventBus: eventbus-default-js [3 replicas, 20Gi]
                    └─► Sensor: k8s-event-triage (rate: 30/min)
                          └─► WorkflowTemplate: k8s-event-triage (v2)
                                ├─► Step 1: parse-event (Python)
                                ├─► Step 2: llm-triage (Ollama/qwen2.5:7b)
                                ├─► Step 3: classify-and-alert (Python)
                                ├─► Step 4: create-gitea-issue (curl, conditional)
                                └─► Step 5: notify-mattermost (curl, conditional)

Ollama (ollama/ollama) — CPU-based deployment
  └─► PVC: ollama-models [50Gi, managed-csi]
  └─► Service: ollama-svc [ClusterIP :11434]
```

---

## 2. Deployment Order <a name="deployment-order"></a>

**Critical rule:** deploy in the sequence below. Components depend on each other; out-of-order deployment causes pod restarts or silent failures.

```
Phase 0 — Secrets & RBAC
Phase 1 — Ollama (LLM inference server)
Phase 2 — EventBus resize
Phase 3 — Updated WorkflowTemplate
Phase 4 — Updated Sensor (rate limit + namespace expansion)
Phase 5 — Alloy config update (additional namespaces)
Phase 6 — Smoke test & cut-over
```

---

### Phase 0 — Secrets & RBAC

Must be applied before any pods start. All secret key names are exact — see [Gotchas](#gotchas).

#### 0.1 — Gitea Secret

```yaml
# secret-gitea.yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitea-credentials
  namespace: argo-events
type: Opaque
stringData:
  token: "<GITEA_API_TOKEN>"        # key must be exactly: token
  base-url: "https://gitea.example.com"   # key must be exactly: base-url
  repo-owner: "ops"                 # key must be exactly: repo-owner
  repo-name: "k8s-incidents"        # key must be exactly: repo-name
```

```bash
kubectl apply -f secret-gitea.yaml
# Verify key names precisely:
kubectl get secret gitea-credentials -n argo-events \
  -o jsonpath='{.data}' | python3 -c "import sys,json; [print(k) for k in json.load(sys.stdin)]"
# Expected output: token  base-url  repo-owner  repo-name
```

#### 0.2 — Mattermost Secret (argo-events namespace)

The PoC had this in the `argo` namespace. For the enhanced template running in `argo-events`, apply it there:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mattermost-webhook
  namespace: argo-events
type: Opaque
stringData:
  url: "https://mattermost.example.com/hooks/<TOKEN>"  # key must be exactly: url
```

#### 0.3 — RBAC for Gitea step (Workflow SA needs no extra k8s permissions; gitea is HTTP)

No additional ClusterRole needed — the gitea step uses `curl` over HTTPS with the API token from the secret above.

Ensure `argo-events-sa` in `argo-events` has `create` on `workflows`:

```bash
kubectl get rolebinding -n argo-events | grep argo-events-sa
# Should show workflow-create binding — apply 05-rbac.yaml if missing
```

---

### Phase 1 — Ollama Deployment

Deploy Ollama **before** updating the WorkflowTemplate. The `llm-triage` workflow step calls Ollama's REST API; if Ollama isn't running when the first workflow fires after the template update, that step will fail (retried 3×, then skipped via `continueOn: failed`).

#### 1.1 — Namespace

```bash
kubectl create namespace ollama --dry-run=client -o yaml | kubectl apply -f -
```

#### 1.2 — PVC

```yaml
# ollama-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
  namespace: ollama
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: managed-csi
  resources:
    requests:
      storage: 50Gi  # qwen2.5:7b model is ~4.7GB; 50Gi gives headroom for future models
```

```bash
kubectl apply -f ollama-pvc.yaml
kubectl wait pvc/ollama-models -n ollama --for=jsonpath='{.status.phase}'=Bound --timeout=60s
```

#### 1.3 — Deployment

```yaml
# ollama-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: ollama
  labels:
    app: ollama
    app.kubernetes.io/part-of: k8s-event-triage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      serviceAccountName: default
      containers:
      - name: ollama
        image: ollama/ollama:0.6.2          # NEVER use :latest or :stable — pin exact version
        ports:
        - containerPort: 11434
        env:
        - name: OLLAMA_MODELS
          value: /models
        - name: OLLAMA_HOST
          value: "0.0.0.0"
        - name: OLLAMA_NUM_PARALLEL
          value: "2"
        resources:
          requests:
            cpu: "2"
            memory: 8Gi
          limits:
            cpu: "4"
            memory: 12Gi
        volumeMounts:
        - name: models
          mountPath: /models
        livenessProbe:
          httpGet:
            path: /api/version
            port: 11434
          initialDelaySeconds: 30
          periodSeconds: 15
          failureThreshold: 4
        readinessProbe:
          httpGet:
            path: /api/version
            port: 11434
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: ollama-models
---
apiVersion: v1
kind: Service
metadata:
  name: ollama-svc
  namespace: ollama
spec:
  selector:
    app: ollama
  ports:
  - port: 11434
    targetPort: 11434
  type: ClusterIP
```

#### 1.4 — Pull the model (one-time init job)

```yaml
# ollama-model-pull-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ollama-pull-qwen
  namespace: ollama
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: pull
        image: curlimages/curl:8.6.0          # pin version — never :latest
        command: [sh, -c]
        args:
        - |
          echo "Waiting for Ollama to be ready..."
          until curl -sf http://ollama-svc:11434/api/version; do sleep 5; done
          echo "Pulling qwen2.5:7b..."
          curl -X POST http://ollama-svc:11434/api/pull \
            -H "Content-Type: application/json" \
            -d '{"name":"qwen2.5:7b","stream":false}' \
            --max-time 600
          echo "Pull complete."
```

```bash
kubectl apply -f ollama-deployment.yaml
kubectl rollout status deployment/ollama -n ollama --timeout=120s

kubectl apply -f ollama-model-pull-job.yaml
kubectl wait job/ollama-pull-qwen -n ollama --for=condition=Complete --timeout=600s
kubectl logs -n ollama job/ollama-pull-qwen

# Verify model available
kubectl exec -n ollama deployment/ollama -- ollama list
```

**GPU vs CPU decision:**

| Option | Use when | Node requirement |
|--------|----------|-----------------|
| CPU-only (current plan) | No GPU node pool available; tolerable ~3-5s inference latency per event | Any node with 8Gi+ RAM |
| GPU (future) | Throughput > 20 req/min; latency < 1s needed | Node pool with `nvidia.com/gpu: 1` taint; add `resources.limits["nvidia.com/gpu"]: 1` |

For the PoC-to-production step, CPU is sufficient. Revisit after measuring p95 workflow duration.

---

### Phase 2 — EventBus Resize (replicas: 1 → 3, storage: 5Gi → 20Gi)

> ⚠️ **Downtime window required.** Resizing the JetStream StatefulSet PVC requires scaling down the EventBus, patching the claim, and re-applying. Plan a 5-minute maintenance window. All events during this window are retained in Event Hub (24h retention) and will be replayed from the last committed offset.

```bash
# Step 1: Scale EventSource and Sensor to 0 (prevent trigger backlog)
kubectl scale deployment -n argo-events \
  -l app.kubernetes.io/part-of=k8s-event-triage --replicas=0

# Step 2: Delete the EventBus (this deletes the StatefulSet and PVC)
kubectl delete eventbus default -n argo-events
kubectl delete pvc -n argo-events -l controller=eventbus-controller

# Step 3: Apply updated EventBus manifest
kubectl apply -f 01-eventbus-jetstream-prod.yaml
# (see manifest below)

# Step 4: Wait for EventBus to be ready (all 3 pods)
kubectl wait pod -n argo-events -l controller=eventbus-controller \
  --for=condition=Ready --timeout=120s

# Step 5: Scale EventSource and Sensor back to 1
kubectl scale deployment -n argo-events \
  -l app.kubernetes.io/part-of=k8s-event-triage --replicas=1
```

**Updated EventBus manifest:**

```yaml
# 01-eventbus-jetstream-prod.yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  jetstream:
    version: "2.10.10"           # pin — never use latest
    replicas: 3                  # HA: quorum requires 3
    streamConfig: |
      maxAge: 24h
      maxMsgs: 500000
      maxBytes: 2147483648       # 2GiB
      replicas: 3
      duplicates: 300s
    persistence:
      storageClassName: managed-csi
      accessMode: ReadWriteOnce
      volumeSize: 20Gi
    containerTemplate:
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 512Mi
```

---

### Phase 3 — Enhanced WorkflowTemplate (v2)

Apply the new template **before** updating the Sensor. The Sensor will continue firing `k8s-event-triage` workflows — if the template is updated while Sensor is running, in-flight workflows use the version at creation time. No downtime needed for the template update itself.

```yaml
# 04-workflow-template-v2.yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: k8s-event-triage
  namespace: argo-events
  labels:
    app.kubernetes.io/part-of: k8s-event-triage
    version: v2
spec:
  arguments:
    parameters:
    - name: event-payload
      value: "{}"
  entrypoint: triage-pipeline
  activeDeadlineSeconds: 300
  podGC:
    strategy: OnPodCompletion
    deleteDelayDuration: 60s
  ttlStrategy:
    secondsAfterSuccess: 3600     # keep 1h for debugging; was 2min global TTL
    secondsAfterFailure: 86400    # keep 24h on failure for investigation
  serviceAccountName: argo-events-sa

  templates:
  # ── Pipeline entrypoint (steps) ─────────────────────────────────────────
  - name: triage-pipeline
    inputs:
      parameters:
      - name: payload
    steps:
    - - name: parse-event
        template: parse-event
        arguments:
          parameters:
          - name: payload
            value: "{{inputs.parameters.payload}}"

    - - name: llm-triage
        template: llm-triage
        arguments:
          parameters:
          - name: event-summary
            value: "{{steps.parse-event.outputs.parameters.event-summary}}"
        continueOn:
          failed: true    # if Ollama unavailable, continue with rule-based fallback

    - - name: classify-and-alert
        template: classify-and-alert
        arguments:
          parameters:
          - name: resource-kind
            value: "{{steps.parse-event.outputs.parameters.resource-kind}}"
          - name: reason
            value: "{{steps.parse-event.outputs.parameters.reason}}"
          - name: namespace
            value: "{{steps.parse-event.outputs.parameters.namespace}}"
          - name: name
            value: "{{steps.parse-event.outputs.parameters.name}}"
          - name: severity
            value: "{{steps.parse-event.outputs.parameters.severity}}"
          - name: llm-verdict
            value: "{{steps.llm-triage.outputs.parameters.verdict}}"

    - - name: create-gitea-issue
        template: create-gitea-issue
        when: "\"{{steps.classify-and-alert.outputs.parameters.should-alert}}\" == \"true\""
        arguments:
          parameters:
          - name: alert-json
            value: "{{steps.classify-and-alert.outputs.parameters.alert-json}}"

      - name: notify-mattermost
        template: notify-mattermost
        when: "\"{{steps.classify-and-alert.outputs.parameters.should-alert}}\" == \"true\""
        arguments:
          parameters:
          - name: alert-json
            value: "{{steps.classify-and-alert.outputs.parameters.alert-json}}"

  # ── Step 1: parse-event ──────────────────────────────────────────────────
  - name: parse-event
    inputs:
      parameters:
      - name: payload
    script:
      image: python:3.12-slim                # pin minor — never :latest
      command: [python]
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits:   {cpu: 200m, memory: 128Mi}
      env:
      - name: PAYLOAD
        value: "{{inputs.parameters.payload}}"
      source: |
        import json, os, sys, base64

        raw = os.environ.get("PAYLOAD", "{}")

        # Argo Events Kafka source base64-encodes the message body
        try:
            decoded = base64.b64decode(raw).decode("utf-8")
            data = json.loads(decoded)
        except Exception:
            try:
                data = json.loads(raw)
            except Exception:
                data = {}

        def dig(d, *keys, default=""):
            for k in keys:
                if not isinstance(d, dict): return default
                d = d.get(k, default)
            return d if d is not None else default

        resource_kind = dig(data, "involvedObject", "kind") or "Unknown"
        reason        = dig(data, "reason") or "Unknown"
        message       = dig(data, "message") or ""
        namespace     = dig(data, "metadata", "namespace") or dig(data, "involvedObject", "namespace") or "default"
        name          = dig(data, "involvedObject", "name") or "unknown"
        event_type    = dig(data, "type") or "Normal"

        WARNING_REASONS = {"BackOff","Failed","OOMKilling","Evicted","Unhealthy",
                           "NodeNotReady","FailedScheduling","FailedMount","CrashLoopBackOff",
                           "BackoffLimitExceeded","Killing","NodeMemoryPressure","NodeDiskPressure"}
        severity = "warning" if (event_type == "Warning" or reason in WARNING_REASONS) else "info"

        event_summary = (
            f"K8s {event_type} event in {namespace}: {resource_kind}/{name} "
            f"reason={reason}. Message: {message[:300]}"
        )

        os.makedirs("/tmp/out", exist_ok=True)
        fields = {"resource-kind": resource_kind, "reason": reason,
                  "namespace": namespace, "name": name,
                  "severity": severity, "event-summary": event_summary}
        for k, v in fields.items():
            open(f"/tmp/out/{k}", "w").write(str(v))
        print(json.dumps(fields, indent=2))
    outputs:
      parameters:
      - {name: resource-kind, valueFrom: {path: /tmp/out/resource-kind}}
      - {name: reason,        valueFrom: {path: /tmp/out/reason}}
      - {name: namespace,     valueFrom: {path: /tmp/out/namespace}}
      - {name: name,          valueFrom: {path: /tmp/out/name}}
      - {name: severity,      valueFrom: {path: /tmp/out/severity}}
      - {name: event-summary, valueFrom: {path: /tmp/out/event-summary}}

  # ── Step 2: llm-triage ──────────────────────────────────────────────────
  - name: llm-triage
    inputs:
      parameters:
      - name: event-summary
    script:
      image: curlimages/curl:8.6.0           # pin — never :latest
      command: [sh]
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits:   {cpu: 200m, memory: 128Mi}
      env:
      - name: EVENT_SUMMARY
        value: "{{inputs.parameters.event-summary}}"
      source: |
        set -euo pipefail
        mkdir -p /tmp/out

        PROMPT="You are a Kubernetes SRE. Analyse this event and respond with ONLY a JSON object with keys: verdict (string: 'alert'|'noise'|'info'), confidence (0-100), reason (one sentence). Event: ${EVENT_SUMMARY}"

        RESPONSE=$(curl -sf --max-time 60 \
          http://ollama-svc.ollama.svc.cluster.local:11434/api/generate \
          -H "Content-Type: application/json" \
          -d "{\"model\":\"qwen2.5:7b\",\"prompt\":\"${PROMPT}\",\"stream\":false,\"format\":\"json\"}" \
          2>/tmp/llm_err.txt || echo '{"response":"{\"verdict\":\"info\",\"confidence\":50,\"reason\":\"LLM unavailable\"}"}')

        # Extract the response field (Ollama wraps JSON in .response)
        INNER=$(echo "$RESPONSE" | grep -o '"response":"[^"]*"' | sed 's/"response":"//;s/"$//' | sed 's/\\"/"/g' || echo '{}')
        echo "$INNER" > /tmp/out/llm-raw

        VERDICT=$(echo "$INNER" | grep -o '"verdict":"[^"]*"' | cut -d'"' -f4 || echo "info")
        echo "$VERDICT" > /tmp/out/verdict

        echo "LLM verdict: $VERDICT"
        cat /tmp/out/llm-raw
    outputs:
      parameters:
      - {name: verdict,  valueFrom: {path: /tmp/out/verdict}}
      - {name: llm-raw,  valueFrom: {path: /tmp/out/llm-raw}}

  # ── Step 3: classify-and-alert ──────────────────────────────────────────
  # (Uses LLM verdict + rule-based fallback — full implementation in repo)

  # ── Step 4: create-gitea-issue ──────────────────────────────────────────
  - name: create-gitea-issue
    inputs:
      parameters:
      - name: alert-json
    script:
      image: curlimages/curl:8.6.0
      command: [sh]
      resources:
        requests: {cpu: 20m, memory: 32Mi}
        limits:   {cpu: 100m, memory: 64Mi}
      env:
      - name: GITEA_TOKEN
        valueFrom:
          secretKeyRef:
            name: gitea-credentials
            key: token                  # exact key name — see Gotchas
      - name: GITEA_BASE_URL
        valueFrom:
          secretKeyRef:
            name: gitea-credentials
            key: base-url               # exact key name
      - name: GITEA_REPO_OWNER
        valueFrom:
          secretKeyRef:
            name: gitea-credentials
            key: repo-owner             # exact key name
      - name: GITEA_REPO_NAME
        valueFrom:
          secretKeyRef:
            name: gitea-credentials
            key: repo-name              # exact key name
      - name: ALERT_JSON
        value: "{{inputs.parameters.alert-json}}"
      source: |
        set -euo pipefail

        TITLE=$(echo "$ALERT_JSON" | grep -o '"title":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "K8s Alert")
        BODY=$(echo "$ALERT_JSON" | python3 -c "
        import sys, json
        d = json.load(sys.stdin)
        att = d.get('attachment', {})
        fields = '\n'.join(f\"**{f['title']}:** {f['value']}\" for f in att.get('fields',[]))
        print(f\"## {att.get('title','Alert')}\n\n{att.get('text','')}\n\n{fields}\")
        " 2>/dev/null || echo "$ALERT_JSON")

        HTTP_CODE=$(curl -s -o /tmp/gitea_resp.txt -w "%{http_code}" \
          -X POST "${GITEA_BASE_URL}/api/v1/repos/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}/issues" \
          -H "Authorization: token ${GITEA_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"title\":\"${TITLE}\",\"body\":\"${BODY}\",\"labels\":[]}")

        echo "Gitea response: HTTP ${HTTP_CODE}"
        cat /tmp/gitea_resp.txt

        [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ] || exit 1

  # ── Step 5: notify-mattermost ────────────────────────────────────────────
  # (same as PoC version — secretRef: mattermost-webhook / key: url)
```

```bash
kubectl apply -f 04-workflow-template-v2.yaml
# Verify
kubectl get workflowtemplate k8s-event-triage -n argo-events \
  -o jsonpath='{.metadata.labels.version}'
# Expected: v2
```

---

### Phase 4 — Updated Sensor

Update the Sensor to raise the rate limit from 5/min to 30/min to handle production event volumes.

> Updating a Sensor triggers a pod restart. Expect ~10s of gap in trigger processing.

```yaml
# 03-sensor-prod.yaml — key diff from PoC:
#   rateLimit: 30/Minute (was 5/Minute)
#   workflowTemplateRef remains: k8s-event-triage (now v2)
spec:
  triggers:
  - template:
      name: triage-workflow
      rateLimit:
        unit: Minute
        requestsPerUnit: 30     # 1 workflow per ~2s burst capacity
```

```bash
kubectl apply -f 03-sensor-prod.yaml
kubectl rollout status deployment -n argo-events \
  -l sensor-name=k8s-event-triage --timeout=60s
```

**Consumer group management:**

When updating the Sensor, the durable JetStream consumer name changes (it's derived from the pod name suffix). This is expected — the new consumer picks up from the current stream position. If you need to replay missed events, use:

```bash
# Create a catch-up consumer manually (optional)
kubectl exec -n argo-events eventbus-default-js-0 -c main -- \
  nats consumer info default k8s-event-triage
```

> **Rule:** Always use a new consumer group name when changing Kafka config on the EventSource. For the current setup, the JetStream durable name is auto-generated — do not set it manually unless you need guaranteed replay.

---

### Phase 5 — Alloy Config Update (Additional Namespaces)

Update Alloy to watch additional namespaces. **Never add** `argo`, `argo-events`, `monitoring`, or `kube-system` — these generate high-volume system events that cause feedback loops and cost overruns.

```alloy
// config.alloy — updated namespace list
loki.source.kubernetes_events "cluster_events" {
  namespaces = [
    "default",
    "production",
    "staging",
    "app-team-a",
    "app-team-b",
    // ADD application namespaces here
    // NEVER ADD: argo, argo-events, monitoring, kube-system, flux-system
  ]
  forward_to = [loki.process.enrich.receiver]
}
```

```bash
# Update the Alloy ConfigMap
kubectl edit configmap alloy-config -n monitoring
# Or via kubectl apply if managed as a file

# Restart Alloy to pick up new config
kubectl rollout restart deployment/alloy -n monitoring
kubectl rollout status deployment/alloy -n monitoring --timeout=60s
```

---

### Phase 6 — Smoke Test & Cut-over

```bash
# 1. Verify all components running
kubectl get pods -n argo-events -o wide
kubectl get pods -n ollama -o wide
kubectl get pods -n monitoring -o wide

# 2. Confirm EventBus 3/3
kubectl get pod eventbus-default-js-0 -n argo-events \
  -o jsonpath='{.status.containerStatuses[*].ready}'
# Expected: true true true

# 3. Inject a test event into Event Hub to trigger the pipeline
# (use the integration test script from create-test-scripts-for-pipeline-verification)
./smoke-test.sh --namespace-argo-events argo-events

# 4. Watch for a workflow to fire and complete
kubectl get workflows -n argo-events -w

# 5. Check Gitea for a created issue
curl -s "${GITEA_BASE_URL}/api/v1/repos/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}/issues?limit=1" \
  -H "Authorization: token ${GITEA_TOKEN}" | python3 -m json.tool | head -20
```

---

## 3. Scaling <a name="scaling"></a>

### 3.1 Rate Limiting

| Stage | PoC value | Production value | Rationale |
|-------|-----------|-----------------|-----------|
| Sensor `requestsPerUnit` | 5/min | 30/min | ~150 events/hr burst; typical production cluster generates 200-500 events/hr across 5 namespaces |
| EventBus stream `maxMsgs` | 100,000 | 500,000 | 5× buffer for busier namespaces |
| EventBus stream `duplicates` | 300s | 300s | Keep — prevents duplicate workflows on reconnect |

**Tuning guidance:**

```bash
# Monitor how many events are being rate-dropped
kubectl logs -n argo-events -l sensor-name=k8s-event-triage --tail=100 | \
  grep -c "rate limit"

# If > 5% of events are dropped, increase requestsPerUnit
```

### 3.2 Consumer Group Management

- The Kafka consumer group on Event Hub (`argo-events-consumer-v4`) should not be reused if the EventSource is significantly reconfigured.
- On EventSource recreate/upgrade: bump the group name suffix (e.g. `v5`).
- Event Hub Standard tier supports 20 consumer groups per hub — no risk of exhaustion.
- Old consumer groups can be removed via:

```bash
az eventhubs consumer-group delete \
  --resource-group rg-event-triage-dev \
  --namespace-name evhns-event-triage-dev \
  --event-hub-name k8s-events \
  --name argo-events-consumer-v4
```

### 3.3 EventBus Sizing

| Metric | 1-replica PoC | 3-replica Production |
|--------|--------------|----------------------|
| Storage | 5Gi | 20Gi per replica |
| Replicas | 1 | 3 (quorum: 2) |
| Stream replicas | 1 | 3 (JetStream R3) |
| Max messages | 100k | 500k |
| Retention | 24h | 24h |

At 500 events/hr, 500k messages = ~1,000 hours of backlog capacity — far exceeds the 24h age limit. Size is driven by burst headroom, not long-term retention.

### 3.4 Ollama Resources (GPU vs CPU)

**CPU sizing:**

| Load | CPU request | Memory request | p95 inference latency |
|------|-------------|---------------|----------------------|
| ≤ 5 req/min | 2 cores | 8Gi | 3-5s |
| ≤ 15 req/min | 4 cores | 12Gi | 3-6s |
| > 30 req/min | GPU recommended | — | — |

**GPU upgrade path (future):**

```yaml
# Add to ollama Deployment when GPU node pool available:
resources:
  limits:
    nvidia.com/gpu: "1"
    memory: 12Gi
  requests:
    nvidia.com/gpu: "1"
    cpu: "2"
    memory: 8Gi
tolerations:
- key: nvidia.com/gpu
  operator: Exists
  effect: NoSchedule
nodeSelector:
  accelerator: nvidia
```

**Model management:** The `qwen2.5:7b` model is loaded once on startup from the PVC. After the init job completes, Ollama serves from disk — no re-download on pod restart.

---

## 4. Monitoring <a name="monitoring"></a>

### 4.1 Key Metrics to Track

| Metric | Source | Alert threshold |
|--------|--------|----------------|
| EventSource pod ready | k8s | `ready != 1/1` for > 2min |
| Sensor pod ready | k8s | `ready != 1/1` for > 2min |
| EventBus pod ready | k8s | `ready < 3/3` for > 2min |
| Ollama pod ready | k8s | `ready != 1/1` for > 5min |
| Kafka consumer lag | Event Hub metrics | lag > 1000 messages |
| Workflow Succeeded rate | Argo | < 90% success in 15min window |
| Workflow Failed count | Argo | any failure |
| Workflow duration p95 | Argo | > 120s |
| LLM step duration | Argo | > 60s per step |

### 4.2 Health Check Commands

```bash
# Quick pipeline health (run as cron or manually)
echo "=== EventBus ===" && kubectl get pod eventbus-default-js-0 -n argo-events \
  -o jsonpath='{.status.containerStatuses[*].ready}' && echo ""

echo "=== EventSource ===" && kubectl get pods -n argo-events \
  -l eventsource-name=eventhub-k8s-events --field-selector=status.phase!=Running

echo "=== Sensor ===" && kubectl get pods -n argo-events \
  -l sensor-name=k8s-event-triage --field-selector=status.phase!=Running

echo "=== Ollama ===" && kubectl get pods -n ollama -l app=ollama \
  --field-selector=status.phase!=Running

echo "=== Recent workflow outcomes ===" && kubectl get workflows -n argo-events \
  --sort-by=.metadata.creationTimestamp | tail -10

echo "=== Kafka consumer lag ===" && kubectl logs -n argo-events \
  -l eventsource-name=eventhub-k8s-events --tail=5 | grep -E "(offset|lag|error)"
```

### 4.3 Alloy Pipeline Metrics

Alloy exposes Prometheus metrics at `:12345/metrics`. Key metrics:

```
# Events received from k8s API
loki_source_kubernetes_events_entries_total

# Events exported to Event Hub Kafka
otelcol_exporter_sent_log_records_total{exporter="kafka/eventhub"}

# Export failures
otelcol_exporter_send_failed_log_records_total{exporter="kafka/eventhub"}
```

If `send_failed` is non-zero, check:
1. `eventhub-credentials` secret exists with correct key names
2. TLS CA secret `eventhub-tls-ca` has key `ca.pem` (not `ca.crt`)
3. Event Hub namespace FQDN resolves from within the pod

### 4.4 Alerting Setup

Add the following Argo Events EventSource for pipeline self-monitoring (fires a Mattermost alert if any component is unhealthy):

```bash
# Simple cron-based health check using existing infrastructure
# Schedule a daily workflow that checks all component health
# and posts to Mattermost if anything is degraded
```

For production, also configure:
- Azure Monitor alerts on Event Hub: `IncomingMessages < 1 over 30min` (Alloy stopped producing)
- Azure Monitor alerts on Event Hub: `ActiveConnections == 0` (EventSource disconnected)

---

## 5. Rollback Procedures <a name="rollback"></a>

### 5.1 Emergency Stop (Scale-to-Zero)

Immediately stops all workflow creation without destroying state:

```bash
# EMERGENCY STOP — stops new workflow creation, preserves EventBus state
kubectl scale deployment -n argo-events \
  -l app.kubernetes.io/part-of=k8s-event-triage --replicas=0

# Verify stopped
kubectl get pods -n argo-events

# RESUME
kubectl scale deployment -n argo-events \
  -l app.kubernetes.io/part-of=k8s-event-triage --replicas=1
```

Events accumulate in Event Hub (24h retention) during the stop and will be replayed on resume.

### 5.2 Rollback WorkflowTemplate to v1

```bash
# Keep the v1 template tagged in git. Rollback is a single apply:
kubectl apply -f 04-workflow-template-v1.yaml

# Verify
kubectl get workflowtemplate k8s-event-triage -n argo-events \
  -o jsonpath='{.metadata.labels.version}'
# Expected: v1

# In-flight workflows are NOT affected — they use the template version at creation time.
```

### 5.3 Rollback Sensor Rate Limit

```bash
# Revert to 5/min rate limit
kubectl patch sensor k8s-event-triage -n argo-events --type=merge \
  -p '{"spec":{"triggers":[{"template":{"name":"triage-workflow","rateLimit":{"unit":"Minute","requestsPerUnit":5}}}]}}'
```

### 5.4 Rollback EventBus to 1-replica

> ⚠️ Same downtime procedure as the resize. Only do this if the 3-replica EventBus is causing issues.

```bash
kubectl scale deployment -n argo-events \
  -l app.kubernetes.io/part-of=k8s-event-triage --replicas=0
kubectl delete eventbus default -n argo-events
kubectl delete pvc -n argo-events -l controller=eventbus-controller
kubectl apply -f 01-eventbus-jetstream.yaml   # original 1-replica version
kubectl scale deployment -n argo-events \
  -l app.kubernetes.io/part-of=k8s-event-triage --replicas=1
```

### 5.5 Rollback Alloy Namespace Config

```bash
kubectl edit configmap alloy-config -n monitoring
# Remove any namespaces added in Phase 5

kubectl rollout restart deployment/alloy -n monitoring
```

### 5.6 Independent Component Revert Matrix

| Component | Rollback action | Downtime | Event loss risk |
|-----------|----------------|----------|----------------|
| WorkflowTemplate | `kubectl apply` old version | None | None |
| Sensor rate limit | `kubectl patch` | ~10s (pod restart) | Minimal |
| Sensor version | `kubectl apply` old version | ~10s | Minimal |
| EventSource | `kubectl apply` old version | ~15s | None (replays from offset) |
| EventBus size | Delete + recreate | 5min | None (replays from Event Hub) |
| Ollama | `kubectl scale deploy/ollama --replicas=0` | None | None (LLM step skipped via continueOn) |
| Alloy namespaces | Edit configmap + rollout restart | None | None |

---

## 6. Gotchas & Hard Rules <a name="gotchas"></a>

These rules encode lessons from the PoC deployment. Violating them causes silent failures or hard-to-debug behaviour.

### ❌ NEVER use floating image tags

```yaml
# WRONG
image: ollama/ollama:latest
image: python:3.12
image: curlimages/curl:latest

# RIGHT
image: ollama/ollama:0.6.2
image: python:3.12-slim
image: curlimages/curl:8.6.0
```

Floating tags cause non-reproducible failures during node replacement, pod evictions, or cluster upgrades. Always pin to an exact digest or semver tag.

### ❌ Secret key names must match EXACTLY

Kubernetes secretKeyRef failures are silent at apply time — pods start with empty env vars. The following key names are contractual:

| Secret name | Key | Used by |
|------------|-----|--------|
| `eventhub-credentials` | `connection-string` | EventSource SASL password |
| `eventhub-credentials` | `username` | EventSource SASL username |
| `eventhub-tls-ca` | `ca.pem` | EventSource TLS CA certificate |
| `mattermost-webhook` | `url` | notify-mattermost step |
| `gitea-credentials` | `token` | create-gitea-issue step |
| `gitea-credentials` | `base-url` | create-gitea-issue step |
| `gitea-credentials` | `repo-owner` | create-gitea-issue step |
| `gitea-credentials` | `repo-name` | create-gitea-issue step |

### ❌ TLS CA key MUST be `ca.pem` (not `ca.crt`, not `tls.crt`)

The EventSource manifest references `ca.pem` specifically:

```yaml
tls:
  caCertSecret:
    key: ca.pem          # EXACTLY this — changing to ca.crt breaks TLS silently
    name: eventhub-tls-ca
```

### ❌ NEVER monitor these namespaces with Alloy

```
argo            # Argo Workflows system events — very noisy, feedback loop risk
argo-events     # Argo Events system events — same
monitoring      # Alloy self-events — causes recursive loops
kube-system     # Very high volume; generates thousands of events/hr
flux-system     # GitOps operator noise
gatekeeper-system  # Policy engine noise
```

Adding these namespaces to Alloy's watch list will cause:
1. Event volume spike → rate limit drops → missed real events
2. Workflow controller overload
3. Ollama inference queue saturation
4. Potential cost spike on Event Hub

### ❌ Always use a fresh consumer group when reconfiguring the EventSource

```yaml
consumerGroup:
  groupName: argo-events-consumer-v5   # bump version suffix on any Kafka config change
```

Reusing a consumer group after a config change can cause:
- Partition rebalance storms
- Duplicate event delivery
- Missed events if the old group held committed offsets at a stale position

### ⚠️ EventBus downtime requires EventSource/Sensor scale-to-zero first

If you delete the EventBus while the EventSource/Sensor are running, both pods will crash-loop trying to reconnect. Always scale to 0 first, resize, then scale back.

### ⚠️ WorkflowTemplate and Sensor must be in the same namespace

The Sensor creates Workflow objects in `argo-events` namespace. The WorkflowTemplate referenced must be in the same namespace. The current PoC correctly has both in `argo-events`. Do not move the WorkflowTemplate to the `argo` namespace without also updating the Sensor's `namespace:` field.

### ⚠️ Ollama model must be pulled before WorkflowTemplate v2 is used

If the `llm-triage` step fires before `qwen2.5:7b` is available in Ollama, the step will time out after 60s. The `continueOn: failed: true` flag prevents this from failing the whole workflow — but all LLM verdicts will be `info` (fallback) until the model is ready.

---

## 7. Go/No-Go Checklist <a name="go-nogo"></a>

Run this checklist immediately before promoting to production:

```
PRE-DEPLOYMENT
[ ] aks-event-triage-dev pipeline verified healthy (task 76cdd6b8)
[ ] All secrets present with exact key names (Phase 0)
[ ] Ollama model pull job completed successfully
[ ] ollama list shows qwen2.5:7b
[ ] WorkflowTemplate v2 tested with manual workflow submit
[ ] Sensor rate limit set to 30/min
[ ] Alloy configmap reviewed — no forbidden namespaces

DEPLOYMENT
[ ] Phase 0: secrets applied
[ ] Phase 1: Ollama running, model pulled
[ ] Phase 2: EventBus 3/3 pods ready
[ ] Phase 3: WorkflowTemplate version=v2
[ ] Phase 4: Sensor rate limit = 30/min
[ ] Phase 5: Alloy config updated, rollout complete

POST-DEPLOYMENT SMOKE TEST
[ ] Smoke test passes (./smoke-test.sh)
[ ] At least 1 workflow reaches Succeeded state
[ ] Gitea issue created for test event
[ ] Mattermost notification received
[ ] No Workflow failures in first 15 minutes
[ ] Event Hub consumer lag < 100 messages
[ ] Ollama response time < 10s per request

MONITORING
[ ] Azure Monitor alerts configured for Event Hub
[ ] Health check script run manually — all green
```

---

*Plan authored by Mission Control agent · 2026-03-12 · Task ba7a9f49*
