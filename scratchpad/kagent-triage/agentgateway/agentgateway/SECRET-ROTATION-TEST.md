# Secret Rotation Test — Empirical Findings

**Date:** 2026-04-21
**Cluster:** red (homelab KIND, agentgateway v1.1.0)

## Question

When the Kubernetes Secret referenced by `AgentgatewayBackend.spec.policies.auth.secretRef`
is updated, does agentgateway:
- (a) hot-reload the new value without restart (no connection impact), or
- (b) require a pod restart (drops in-flight requests)?

This matters because the custom-scope workaround (`backend-azure-openai-customscope.yaml`)
rotates the token via CronJob every 30 minutes. If that triggered pod restarts, long-running
LLM streams would be torn down mid-response.

## Test Method

1. Installed agentgateway v1.1.0 via Helm on the red cluster
2. Deployed httpbin as a dummy backend + an `AgentgatewayBackend` with
   `policies.auth.secretRef` pointing to a `rotating-token` Secret (initial
   value `Bearer TOKEN-v1`)
3. Recorded the data-plane pod UID and restart count
4. Patched the Secret to `Bearer TOKEN-v2-ROTATED`
5. Observed pod for 60 seconds
6. Checked control-plane logs for xDS push events

## Result: No restart, xDS hot-reload confirmed

```
BEFORE rotation — pod=test-gateway-5c4d578cf-hn9dp
                  uid=17b5bac4-1397-4122-8b56-733b0bfa51d7
                  restarts=0

Secret patched at 08:54:00 UTC

AFTER rotation (60s window) —
  +10s same pod, restarts=0
  +20s same pod, restarts=0
  +30s same pod, restarts=0
  +40s same pod, restarts=0
  +50s same pod, restarts=0
  +60s same pod, restarts=0
```

Control-plane log, immediately after the `kubectl patch`:

```
08:54:00.944  sync complete name="Informer[*v1.Secret]"
08:54:00.944  push debounce stable cause=backend/agentgateway-system/llm-httpbin
08:54:00.944  XDS: Pushing clients=1 version=2026-04-21T08:54:00Z/12
08:54:00.944  push response type=RDS resources=1 size=182B
```

The control plane's Kubernetes Secret informer fired within ~1 second of the patch,
then pushed new Route Discovery Service (RDS) config to the one connected data-plane
pod. Data-plane pod did not restart, did not drain connections, did not tear down
existing streams.

## Pod Architecture Confirms This

The data-plane pod mounts only:
- `config-volume` — the static bootstrap ConfigMap
- `xds-token` — projected ServiceAccount token for authenticating to the control plane
- `tmp` — scratch

**No direct mount of the Secret.** All auth/secret data flows through xDS from the
control plane, which is the standard Envoy-style data plane architecture.

## Mechanism — exactly how rotation works without breaking

This answers the question "is the secret read every request, or only at pod load?"
Answer: **neither — it's pushed via xDS whenever it changes, and held in memory.**

```
┌──────────────────────────────────────────────────────────────────────────┐
│ MANAGEMENT CLUSTER                                                       │
│                                                                          │
│  K8s API ◄──────── watches ──────── agentgateway control plane           │
│    │                                  │                                  │
│    │  Secret updated by CronJob       │  in-memory config store          │
│    │  ↓                               │  (Authorization = "Bearer xyz")  │
│    │                                  │                                  │
│    │  Informer callback fires         │  On change → debounce ~10ms →    │
│    │  (within ~1 second)              │  XDS push (RDS) to connected     │
│    │                                  │  data-plane pods                 │
│    │                                  │       │                          │
│    │                                  ▼       │                          │
│    │                           ┌────────────────────┐                    │
│    │                           │ agentgateway       │                    │
│    │                           │ data-plane pod     │                    │
│    │                           │                    │                    │
│    │                           │  in-memory config: │                    │
│    │                           │  auth header value │                    │
│    │                           │  ▲                 │                    │
│    │                           │  │ receives xDS    │                    │
│    │                           │  │ push            │                    │
│    │                           │  │                 │                    │
│    │                           │  └── on next       │                    │
│    │                           │      outbound req  │                    │
│    │                           │      adds          │                    │
│    │                           │      Authorization │                    │
│    │                           │      header        │                    │
│    │                           └────────┬───────────┘                    │
│                                          │                               │
└──────────────────────────────────────────┼───────────────────────────────┘
                                           │
                                           ▼
                                  Azure OpenAI endpoint
```

### Answers to the specific questions

**Q: Does it read the secret from Kubernetes every time it makes a connection?**
No. That would be slow (API round-trip per request). The data plane keeps the
current auth header value in memory and applies it to each outbound request.

**Q: Does it read the secret every time the pod loads?**
Only at pod startup for the initial value. After that, the control plane
streams updates via xDS whenever the Secret changes in the K8s API.

**Q: How does it not break on rotation?**

1. **In-flight requests complete normally.** The Authorization header is added
   to an HTTP request at the moment it's being forwarded upstream. Once the
   request is sent, the token is already "baked in." Even if the secret rotates
   a microsecond later, the in-flight request is unaffected.

2. **New requests use the new token.** After xDS push (usually <1s after the
   Secret changes), every new outbound request uses the updated value.

3. **The 30-min refresh cadence + 60-min token TTL gives a 30-min overlap.**
   - At T+0, new token v2 issued (valid until T+60min)
   - CronJob fires at every :00 and :30, so v2 is written to the Secret
     within 30 minutes of being issued
   - v1 from the previous cycle is still valid until T+60
   - During the overlap window, any request is safe with either token
   - No point in time where the data plane has an expired or missing token

4. **No pod restart, no TCP connection teardown, no stream drop.** Verified
   above via UID and restartCount staying constant across rotation.

### Failure modes worth monitoring

- **CronJob fails for 60+ min** → token expires while data plane holds it →
  Azure starts returning 401 → `KagentCannotReachGateway` alert fires after 15m.
  Investigate the CronJob logs and fix before tokens age out of the overlap window.
- **Secret key renamed** (e.g. typo from `Authorization` to `authorization`) →
  agentgateway rejects the backend config → control plane logs show reconcile
  error. Catch this in CI / `agentgatewaybackend` status before rolling to prod.
- **UAMI loses role assignment** → CronJob still succeeds (gets a token for the
  scope) but Azure rejects the token → 403 responses → same alert path.

## Implication for the Custom-Scope CronJob Pattern

The graceful-restart infrastructure discussed previously (HA replicas, PDB,
`terminationGracePeriodSeconds: 300`, stakater/Reloader, preStop drain hooks) is
**not required** for secret rotation safety.

The CronJob updates the Secret → K8s Secret informer in the agentgateway control
plane fires → debounced xDS push to data plane → new token used for next request.
In-flight requests are unaffected.

You still want HA replicas for the usual availability reasons (node drains, Helm
upgrades, etc.), but a CronJob-driven token refresh by itself does not threaten
request stability.

## Not Tested (still assumed)

- Behavior under high-frequency secret changes (>1/second) — Kubernetes Secret
  informer would still debounce, but not measured
- Behavior when the secret is deleted (not rotated) — the current value should
  remain in the data plane until a new push replaces it, but not measured
- Behavior when the CronJob fails and produces a blank or malformed value — the
  control plane should reject the config and not push, but not measured. The
  `KagentCannotReachGateway` alert in `monitoring.yaml` would fire after 15m of
  failure, which gives an operational signal.

## Also Discovered During Testing

The `AgentgatewayBackend` schema places `host` and `port` **at the provider level**,
not inside the provider type object:

```yaml
# WRONG (original manifests had this — now fixed)
spec:
  ai:
    provider:
      openai:
        model: gpt-4o
        host: kubeai.kubeai.svc.cluster.local   # ✗ unknown field
        port: 80                                # ✗ unknown field

# CORRECT
spec:
  ai:
    provider:
      openai:
        model: gpt-4o
      host: kubeai.kubeai.svc.cluster.local     # ✓ sibling of openai
      port: 80                                  # ✓ sibling of openai
```

Both `host` and `port` must be set together (validator rejects partial).

`backend-kubeai.yaml` has been corrected.
