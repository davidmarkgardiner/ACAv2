# Alloy → Argo Events Webhook (Direct) — PoC

Bypasses managed AlertManager / BigPanda / ConfigMap reload entirely.
Alloy POSTs JSON straight to an Argo Events `webhook` EventSource, a
Sensor fans the body into an Argo Workflow, and an echo template prints
the payload so you can verify the wire works end-to-end.

```
┌─────────┐      HTTPS bearer-auth     ┌─────────────────┐    ┌──────────┐    ┌─────────────┐
│  Alloy  │ ─────────────────────────► │ Argo Events     │ ─► │  Sensor  │ ─► │  Workflow   │
│         │   POST /alloy              │ EventSource     │    │ alloy-   │    │ alloy-poc-  │
│         │   {Loki-shaped JSON}       │ (webhook :12001)│    │ poc      │    │ echo        │
└─────────┘                            └─────────────────┘    └──────────┘    └─────────────┘
```

This is the **PoC scaffold**. Once payloads land in workflow logs, swap
`alloy-poc-echo` for the real triage template (e.g. `webhook-hub-ai-triage`
or `alertmanager-triage`).

---

## 1. What's in this folder

| File | Purpose |
|---|---|
| `00-secret.yaml` | Bearer token used by Alloy and verified by the EventSource. **Replace before applying.** |
| `01-eventsource.yaml` | Argo Events `webhook` EventSource on port `12001`, path `/alloy`, validates the bearer. |
| `02-sensor.yaml` | Fires `alloy-poc-echo` workflow on every POST. No filter at PoC stage — accept everything. |
| `03-workflow-template.yaml` | Echo workflow: pretty-prints the body, surfaces Loki / AlertManager fields if present. |
| `alloy-snippet.alloy` | Drop-in Alloy block — synthetic source + `loki.write` to the EventSource. |
| `deploy.sh` | Applies the four manifests in order. |
| `test-curl.sh` | Mimic-Alloy smoke test from your laptop or in-cluster. |
| `README.md` | This file. |

---

## 2. Prereqs at the work cluster

You need:

- **Argo Workflows + Argo Events** already installed in `argo-events` namespace
  with the `default` NATS EventBus (you have this — same install as the
  AlertManager pipeline and the webhook-hub).
- ServiceAccount `argo-events-sa` already exists with workflow create RBAC
  (created by the existing prometheus-alerting / webhook-hub deploys).
- **Alloy** running in the cluster with a writable values file you can edit
  (or a sidecar config you can ship a new snippet into).

If any of these are missing, copy the equivalent files from
`aks-mgmt-stack/k8s-event-triage/prometheus-alerting/08-workflow-rbac.yaml`
or `webhook-hub/02-rbac.yaml`.

---

## 3. Deploy (cluster side)

```bash
# 1. generate a token and stamp it in
TOKEN=$(openssl rand -hex 32)
sed -i "s/REPLACE_WITH_OPENSSL_RAND_HEX_32/${TOKEN}/" 00-secret.yaml

# 2. apply
./deploy.sh

# 3. confirm the EventSource pod is running
kubectl -n argo-events get pods -l eventsource-name=alloy-poc
kubectl -n argo-events get svc alloy-poc-eventsource-svc
```

You should see one Pod `Running` and a ClusterIP service exposing `:12001`.

Save `${TOKEN}` somewhere safe — you'll mount it into Alloy in the next step.

---

## 4. Wire Alloy

### 4a. Mount the same token into the Alloy Pod

```bash
# Reuse the same secret value Alloy will read at /etc/alloy-webhook/token.
# Easiest: another Secret in the Alloy namespace, projected as a volume.
kubectl -n <alloy-ns> create secret generic alloy-webhook-token \
  --from-literal=token="${TOKEN}"
```

Then in your Alloy Helm values (or DaemonSet manifest):

```yaml
extraVolumes:
  - name: alloy-webhook-token
    secret:
      secretName: alloy-webhook-token
extraVolumeMounts:
  - name: alloy-webhook-token
    mountPath: /etc/alloy-webhook
    readOnly: true
extraEnv:
  - name: CLUSTER_NAME
    value: "<your-cluster>"
```

### 4b. Drop in the Alloy snippet

Append the contents of `alloy-snippet.alloy` to your Alloy config (e.g.
`config.alloy` ConfigMap or wherever you keep the existing OTLP / Loki /
Mimir blocks). Reload Alloy:

```bash
kubectl -n <alloy-ns> rollout restart ds/alloy   # or deployment, depending
```

The snippet does three things:

1. Spawns a synthetic `loki.source.api` on `:9998` (in-pod only) so you don't
   have to wire real telemetry yet.
2. Adds static labels (`cluster`, `pipeline`, `severity`).
3. `loki.write` POSTs to `http://alloy-poc-eventsource-svc.argo-events.svc.cluster.local:12001/alloy`
   with `Authorization: Bearer <token>`.

Once the synthetic source is firing, comment it out and forward whatever you
actually want — Kubernetes pod logs, Mimir alerts, etc.

---

## 5. Smoke-test from your laptop

You don't need Alloy wired up to verify the cluster side works. Run:

```bash
# port-forward the EventSource service
kubectl -n argo-events port-forward svc/alloy-poc-eventsource-svc 12001:12001 &

# fire a synthetic Loki-shaped POST
./test-curl.sh
```

Expected output:
- `HTTP 200` from the curl
- `kubectl -n argo-events get wf -l app.kubernetes.io/part-of=alloy-direct-poc`
  shows a new `alloy-poc-xxxxx` workflow within ~1 s
- `kubectl -n argo-events logs <wf-pod>` shows the pretty-printed body

If you see the body in the workflow logs, **the wire is good**. Stop here and
move on to wiring real Alloy data.

---

## 6. What to look for / common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `HTTP 401` from `test-curl.sh` | Token mismatch between Secret and curl | Re-derive: `kubectl -n argo-events get secret alloy-poc-webhook-token -o jsonpath='{.data.token}' \| base64 -d` |
| `HTTP 200` but no workflow appears | Sensor not running / NATS EventBus unhealthy | `kubectl -n argo-events get sensor,eventbus`; restart sensor pod |
| Workflow created but stuck `Pending` | RBAC / image pull / scheduling | `kubectl -n argo-events describe wf <name>` |
| `connection refused` from Alloy pod | DNS / NetworkPolicy blocking the inbound | `kubectl -n argo-events get netpol`; from Alloy pod: `nslookup alloy-poc-eventsource-svc.argo-events` |
| Alloy logs show 405 / 404 | Wrong path or method | Path must be `/alloy`, method must be `POST` (Loki push API uses POST — should match) |
| Body appears as `null` in workflow | `dataKey: body` mismatch | Confirm Sensor uses `dataKey: body` and Argo Events version ≥ 1.7 |

---

## 7. Going from PoC to production

When the wire works:

1. **Add a filter on the Sensor** (`02-sensor.yaml`) — e.g.
   `body.streams[0].stream.severity == "critical"`. Stops every log line
   from spawning a workflow.
2. **Lower the rate limit** from 30/min to 5/min.
3. **Swap the echo template** for the real triage:
   ```yaml
   workflowTemplateRef:
     name: webhook-hub-ai-triage   # or alertmanager-triage
   ```
4. **Expose externally** (only if Alloy is off-cluster) — copy the
   pattern from `webhook-hub/04-istio-virtualservice.yaml` and
   `05-istio-authorization-policy.yaml`. ClusterIP is fine for in-cluster
   Alloy → in-cluster EventSource.
5. **Rotate the token** by re-applying `00-secret.yaml` with a new value
   and updating the Alloy-side Secret in lockstep.

---

## 8. Cleanup

```bash
kubectl -n argo-events delete -f 03-workflow-template.yaml
kubectl -n argo-events delete -f 02-sensor.yaml
kubectl -n argo-events delete -f 01-eventsource.yaml
kubectl -n argo-events delete -f 00-secret.yaml
kubectl -n argo-events delete wf -l app.kubernetes.io/part-of=alloy-direct-poc
```

---

## 9. Cross-references

- Existing AlertManager → EventSource pattern (this PoC mirrors it):
  `../prometheus-alerting/03-eventsource-alertmanager.yaml`
- Hub variant with Istio + auth + multiple subscribers:
  `../webhook-hub/`
- Why we want this in parallel with BigPanda:
  `../BIGPANDA-OPTION.md`
- Central hub design discussion:
  `../CENTRAL-WEBHOOK-HUB.md`
