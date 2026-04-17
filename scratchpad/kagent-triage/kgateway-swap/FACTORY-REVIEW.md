# FACTORY REVIEW: kgateway v2.2.3 Integration Manifests
**Date:** 2025-07-18
**Reviewer:** Software Factory — quality-gate team
**Scope:** Production readiness review of AI gateway stack

## Overall Assessment
Not ready for production. Overall risk: **HIGH**.

The manifests show a useful verified homelab/test setup, but they are not yet production-grade for an AI gateway handling kagent → kgateway → KubeAI/Ollama traffic. The biggest issues are: plaintext in-cluster HTTP with no TLS, dummy/no-auth secrets, route/policy target mismatches between files, lack of network isolation, incomplete resilience controls, and observability components that depend on assumptions rather than proven selectors/ports.

The documentation itself signals a non-production test context. `VERIFIED-INSTALL.md` states `"Tested on: red cluster (KIND, 1 node, homelab-control-plane, K8s v1.32.2)"` and `token-tracking-otel.yaml` labels the environment `env     = "homelab"`. That is useful validation, but not sufficient evidence for production readiness.

## Security Review
### CRITICAL
1. **No TLS on the gateway listener or upstream model traffic.**
   - `verified-gateway-resources.yaml` defines the listener as:
     ```yaml
     listeners:
       - name: ai-proxy
         protocol: HTTP
         port: 8080
     ```
   - `verified-modelconfig.yaml` uses plaintext service URLs:
     ```yaml
     baseUrl: http://ai-gateway.kgateway-system.svc.cluster.local:8080/openai/v1
     ```
   - `ai-backend-multipool.yaml` sends traffic to KubeAI over plaintext:
     ```yaml
     customHost:
       host: kubeai.kubeai.svc.cluster.local
       port: 80
     ```
   This leaves all request/response payloads, prompts, tool instructions, and model outputs unencrypted in-cluster.

2. **Authentication is effectively disabled with dummy secrets.**
   - `verified-modelconfig.yaml` instructs creation of a fake credential:
     ```yaml
     kubectl create secret generic litellm-key -n kagent --from-literal=api-key="not-required"
     ```
   - `ai-backend-multipool.yaml` embeds a dummy secret value:
     ```yaml
     stringData:
       api-key: "not-required"
     ```
   - The same file justifies it with:
     ```yaml
     # KubeAI doesn't require auth for in-cluster requests
     ```
   In production, unauthenticated in-cluster access is a major exposure; any compromised pod with network reachability can hit the model endpoint.

### HIGH
3. **Cross-namespace routing is open to all route namespaces on the Gateway.**
   - `verified-gateway-resources.yaml`:
     ```yaml
     allowedRoutes:
       namespaces:
         from: All
     ```
   This is too permissive for production and increases the chance of accidental or malicious attachment from other namespaces.

4. **No NetworkPolicy manifests are present.**
   None of the 8 files define `kind: NetworkPolicy`. Production AI gateways should restrict who can reach kgateway, KubeAI, Loki, Tempo, and Alloy.

5. **Prompt guard is incomplete and easy to bypass.**
   - `ai-traffic-policy.yaml` only blocks a limited set of request patterns:
     ```yaml
     builtins:
       - CREDIT_CARD
       - SSN
       - EMAIL
       - PHONE_NUMBER
     patterns:
       - "(?i)(password|secret|api.?key|bearer.?token|kubeconfig)"
       - "(?i)(kubectl.*delete|kubectl.*drain|rm -rf)"
     matches:
       - "ignore previous instructions"
       - "jailbreak"
       - "DAN mode"
     ```
   This does not cover many common exfiltration, prompt injection, indirect prompt injection, code execution, or credential disclosure patterns.

6. **No RBAC manifests for observability agents or gateway-specific least privilege.**
   The review set contains ConfigMaps, Services, ServiceMonitors, PodMonitor, Gateway resources, and policies, but no `Role`, `ClusterRole`, `RoleBinding`, or `ClusterRoleBinding` manifests. For a production deployment, permissions should be explicitly reviewed and versioned.

### MEDIUM
7. **Access logs may expose sensitive prompt metadata or identifiers.**
   - `ai-traffic-policy.yaml` logs request metadata broadly:
     ```yaml
     path: "%REQ(:PATH)%"
     request_id: "%REQ(X-REQUEST-ID)%"
     trace_id: "%REQ(X-B3-TRACEID)%"
     model: "%REQ(X-MODEL-NAME)%"
     user_agent: "%REQ(USER-AGENT)%"
     ```
   While the body is not logged here, production setups usually also need explicit log retention, redaction, and data classification controls.

8. **Tempo exporter explicitly disables TLS verification.**
   - `token-tracking-otel.yaml`:
     ```yaml
     tls {
       insecure = true
     }
     ```
   Acceptable in a lab; weak for production telemetry transport.

### LOW
9. **Listener appears intended for internal-only use, but external exposure strategy is undefined.**
   `VERIFIED-INSTALL.md` says:
   ```md
   | GatewayClass + Gateway | ✅ | ai-gateway, LoadBalancer, 172.18.255.201 |
   ```
   Yet the actual `Gateway` manifest does not include production ingress controls, TLS, or source restrictions.

## Reliability Review
### CRITICAL
1. **Resource requests/limits are absent from all manifests reviewed.**
   No file in scope defines pod/container `resources:` for kgateway, Alloy, or any related workload. Without this, production scheduling and OOM behavior are uncontrolled.

2. **No PodDisruptionBudget, HPA, anti-affinity, or topology spread controls are present.**
   There are no manifests for `PodDisruptionBudget`, `HorizontalPodAutoscaler`, `topologySpreadConstraints`, or affinity rules in the reviewed set. This means planned maintenance or node events could cause avoidable downtime.

### HIGH
3. **Timeout policy exists, but retry/failure behavior is underdefined for non-multipool path.**
   - `verified-gateway-resources.yaml` only sets:
     ```yaml
     timeouts:
       request: "120s"
       streamIdle: "120s"
     ```
   There is no explicit retry, circuit breaking, outlier detection, or concurrency protection shown for the single-backend route.

4. **Fallback logic depends on a separate route/backend stack that conflicts with the verified route names.**
   - `verified-gateway-resources.yaml` defines route:
     ```yaml
     kind: HTTPRoute
     metadata:
       name: kubeai-ai-route
     ```
   - `ai-backend-multipool.yaml` defines a different route:
     ```yaml
     metadata:
       name: kubeai-ai-route-multipool
     ```
   - `ai-traffic-policy.yaml` targets only the multipool route, and comments admit the mismatch:
     ```yaml
     name: kubeai-ai-route-multipool  # or kubeai-ai-route if not using multipool
     ```
   This is configuration-fragile and easy to deploy incorrectly.

5. **Gateway names and section references are inconsistent across files.**
   - `verified-gateway-resources.yaml` Gateway name:
     ```yaml
     name: ai-gateway
     ```
   - `ai-backend-multipool.yaml` parentRef points to:
     ```yaml
     name: ai-platform-gw
     sectionName: ai-proxy-internal
     ```
   - `ai-traffic-policy.yaml` ListenerPolicy targets:
     ```yaml
     name: ai-platform-gw
     ```
   These inconsistencies are likely to cause resources not to attach at all.

6. **Cold-start behavior is acknowledged but not operationally mitigated enough for production.**
   - `VERIFIED-INSTALL.md` says:
     ```md
     Models scale to 0 replicas when idle. First request after idle takes ~60-90s (Ollama model load).
     The `TrafficPolicy` sets 120s timeout to handle this.
     ```
   A 60–90s first-token latency may be unacceptable for production unless paired with warm pools, autoscaling policy, or queueing/SLO acceptance.

### MEDIUM
7. **No explicit readiness/liveness checks are defined in reviewed manifests.**
   This may exist in Helm defaults, but it is not codified here. Production overlays should explicitly pin health behavior.

8. **Monitoring rules assume fallback should work but do not prove failover safety.**
   - `ai-backend-multipool.yaml` comments say:
     ```yaml
     # Triggered automatically if pool 0 returns 5xx or times out
     ```
   There is no quoted schema field here showing retry counts, failover thresholds, or idempotency handling. That should be validated against the CRD schema.

## Observability Review
### HIGH
1. **Observability selectors/ports are inconsistent and may not scrape the intended targets.**
   - `verified-gateway-resources.yaml` PodMonitor scrapes:
     ```yaml
     targetPort: 19000
     path: /stats/prometheus
     ```
   - `prometheus-monitoring.yaml` ServiceMonitor says Envoy metrics are at:
     ```yaml
     # Envoy exposes Prometheus metrics at :9091/stats/prometheus (or :15090 on some builds).
     ```
     and configures:
     ```yaml
     - port: metrics
       path: /stats/prometheus
     ```
   The manifests present multiple incompatible assumptions (19000 vs 9091 vs 15090). Production monitoring should use one verified and version-pinned endpoint.

2. **Log pipeline depends on labels/selectors that may be too broad or incorrect.**
   - `alloy-log-pipeline.yaml` discovers *all* pods in `kgateway-system`:
     ```alloy
     discovery.kubernetes "kgateway_pods" {
       role = "pod"
       namespaces {
         names = ["kgateway-system"]
       }
     }
     ```
   This may ingest non-proxy pods and dilute/overload logs.

3. **No dashboards or SLOs are defined.**
   The files include `ServiceMonitor`, `PodMonitor`, and `PrometheusRule`, but no Grafana dashboards, recording rules for SLOs, or operational service objectives.

### MEDIUM
4. **Alert rules may not match actual metric labels/jobs.**
   - `prometheus-monitoring.yaml` relies on expressions like:
     ```yaml
     absent(up{job="kagent-controller-metrics", namespace="kagent"} == 1)
     ```
   and:
     ```yaml
     absent(envoy_server_live{namespace="kgateway-system"})
     ```
   Whether these labels exist depends on Prometheus Operator-generated job labels and relabeling. They may fail silently if label names differ.

5. **Remote write is used where scrape/export may be more standard for local Prometheus.**
   - `token-tracking-otel.yaml`:
     ```yaml
     prometheus.remote_write "kube_prom" {
       endpoint {
         url = "http://kube-prom-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
       }
     }
     ```
   This can work, but it adds operational complexity and backpressure considerations. For production, justify this architecture explicitly.

6. **Trace/log correlation is partially designed but not end-to-end verified.**
   - `ai-traffic-policy.yaml` logs:
     ```yaml
     trace_id: "%REQ(X-B3-TRACEID)%"
     ```
   - `token-tracking-otel.yaml` receives OTLP traces from the AI extension.
   That is promising, but the manifests do not show full correlation guarantees across Envoy, kgateway AI extension, kagent, Alloy, Loki, and Tempo.

### LOW
7. **Useful alerting coverage exists for error rate, latency, fallback, rate limiting, and crash loops.**
   Example from `prometheus-monitoring.yaml`:
   ```yaml
   - alert: KgatewayHighErrorRate
   - alert: KgatewayHighLatency
   - alert: KgatewayModelFallbackActive
   - alert: KgatewayRateLimitHit
   - alert: KubeAIModelCrashLoop
   ```
   This is a good start, but needs validation against real metric names.

## Correctness Issues
### CRITICAL
1. **Gateway/route/policy naming mismatch likely breaks attachment.**
   - `verified-gateway-resources.yaml`:
     ```yaml
     kind: Gateway
     metadata:
       name: ai-gateway
     ```
   - `ai-backend-multipool.yaml` HTTPRoute parentRef:
     ```yaml
     parentRefs:
       - name: ai-platform-gw
         namespace: kgateway-system
         sectionName: ai-proxy-internal
     ```
   - `ai-traffic-policy.yaml` ListenerPolicy targetRef:
     ```yaml
     targetRefs:
       - group: gateway.networking.k8s.io
         kind: Gateway
         name: ai-platform-gw
     ```
   There is no `ai-platform-gw` Gateway in the reviewed files.

2. **Listener section name mismatch likely breaks route attachment.**
   - `verified-gateway-resources.yaml` listener name:
     ```yaml
     - name: ai-proxy
     ```
   - `ai-backend-multipool.yaml` references:
     ```yaml
     sectionName: ai-proxy-internal
     ```
   There is no listener named `ai-proxy-internal` in the reviewed Gateway manifest.

### HIGH
3. **TrafficPolicy target route mismatch.**
   - `verified-gateway-resources.yaml` route name:
     ```yaml
     name: kubeai-ai-route
     ```
   - `ai-traffic-policy.yaml` target ref:
     ```yaml
     name: kubeai-ai-route-multipool  # or kubeai-ai-route if not using multipool
     ```
   If the multipool route is not deployed, the security/rate-limit policy will not attach.

4. **ListenerPolicy targets a different Gateway than the verified install.**
   - `ai-traffic-policy.yaml`:
     ```yaml
     kind: ListenerPolicy
     metadata:
       name: ai-gateway-access-logs
     spec:
       targetRefs:
         - group: gateway.networking.k8s.io
           kind: Gateway
           name: ai-platform-gw
     ```
   - `VERIFIED-INSTALL.md` and `verified-gateway-resources.yaml` consistently use `ai-gateway`.

5. **File naming/documentation mismatch suggests operator error risk.**
   - `ai-traffic-policy.yaml` says:
     ```yaml
     # not via TrafficPolicy. See alloy-otel-pipeline.yaml for trace → Tempo/Prometheus.
     ```
   But the actual file provided is named `token-tracking-otel.yaml`, not `alloy-otel-pipeline.yaml`.
   - `ai-backend-multipool.yaml` says:
     ```yaml
     # This replaces the kubeai-ai-route from ai-proxy-route.yaml
     ```
   No `ai-proxy-route.yaml` is in the reviewed file set.

### MEDIUM
6. **API version mix should be revalidated against cluster-supported CRDs.**
   - `verified-gateway-resources.yaml` uses:
     ```yaml
     apiVersion: gateway.networking.k8s.io/v1beta1
     kind: ReferenceGrant
     ```
   while other Gateway API resources use `gateway.networking.k8s.io/v1`.
   This may be valid depending on installed CRD versions, but should be pinned and validated for the production cluster version.

7. **Prometheus selector assumptions are explicitly unverified.**
   - `prometheus-monitoring.yaml` includes comments such as:
     ```yaml
     # Verify: kubectl get svc -n kgateway-system --show-labels
     # Common labels: app.kubernetes.io/name=kgateway or app=kgateway
     ```
   and:
     ```yaml
     - port: metrics             # verify port name
     ```
   Production manifests should not rely on comments that require manual post-hoc verification.

8. **PodMonitor label selector may fail if gateway pods do not carry the expected label.**
   - `verified-gateway-resources.yaml`:
     ```yaml
     selector:
       matchLabels:
         gateway.networking.k8s.io/gateway-name: ai-gateway
     ```
   This is plausible but not guaranteed across versions or deployment modes.

## Missing Pieces
1. **TLS/cert management** — no `certificateRefs`, no HTTPS listener, no cert-manager resources.
2. **NetworkPolicy** — none present for kgateway, kagent, kubeai, Loki, Tempo, or Alloy.
3. **Explicit authn/authz for model access** — current design uses `"not-required"` dummy secrets.
4. **Ingress exposure policy** — no source restrictions, WAF, or internal/external separation beyond comments.
5. **Autoscaling/warm capacity** — no HPA/KEDA, no min replicas, no warm pool strategy for cold-start mitigation.
6. **PDB/high availability controls** — no PDBs, affinity, anti-affinity, or topology spread.
7. **Resource management** — no CPU/memory requests/limits in the reviewed manifests.
8. **Runbooks and dashboards** — alert annotations contain shell snippets, but there are no versioned runbooks or Grafana dashboards.
9. **Secret management integration** — no ExternalSecret/SealedSecret/SOPS/Teller pattern for production credentials.
10. **Namespace/RBAC hardening manifests** — absent from this review set.
11. **Load/performance validation artifacts** — no soak test, concurrency test, or capacity/SLO evidence.
12. **Schema validation evidence** — comments often say “verify” rather than encoding known-good selectors and ports.

## Recommended Fixes (prioritised)
1. **P0 — Unify Gateway and route references across all manifests.**
   - Change every reference to a single Gateway name, e.g. `ai-gateway`.
   - Fix `ai-backend-multipool.yaml`:
     ```yaml
     parentRefs:
       - name: ai-platform-gw
         namespace: kgateway-system
         sectionName: ai-proxy-internal
     ```
     to match the actual Gateway/listener defined in `verified-gateway-resources.yaml`:
     ```yaml
     metadata:
       name: ai-gateway
     listeners:
       - name: ai-proxy
     ```
   - Fix `ai-traffic-policy.yaml` ListenerPolicy target from `ai-platform-gw` to `ai-gateway`.

2. **P0 — Enforce TLS on client→gateway and preferably gateway→backend traffic.**
   - Replace:
     ```yaml
     protocol: HTTP
     port: 8080
     ```
     with an HTTPS listener and `tls.certificateRefs`.
   - Replace `baseUrl: http://...` with `https://...` where supported.
   - Validate whether kgateway Backend supports TLS upstream settings for KubeAI.

3. **P0 — Replace dummy secrets/no-auth model access with real authentication and managed secrets.**
   - Remove:
     ```yaml
     api-key: "not-required"
     ```
   - Do not rely on:
     ```yaml
     # KubeAI doesn't require auth for in-cluster requests
     ```
   - Add real secret management and restrict callers to known service accounts/namespaces.

4. **P0 — Add NetworkPolicy for all involved namespaces.**
   - Restrict ingress to kgateway from only kagent and approved ingress sources.
   - Restrict egress from kgateway to only KubeAI, telemetry backends, and DNS.
   - Restrict Alloy/Loki/Tempo/Prometheus communication paths.

5. **P1 — Make security policy attachment deterministic.**
   - In `ai-traffic-policy.yaml`, replace the ambiguous target:
     ```yaml
     name: kubeai-ai-route-multipool  # or kubeai-ai-route if not using multipool
     ```
     with one route name that matches the deployed route.
   - Maintain separate overlays for single-backend and multipool modes instead of one ambiguous manifest.

6. **P1 — Harden prompt guard and add explicit abuse controls.**
   - Extend the current blocklist:
     ```yaml
     builtins:
       - CREDIT_CARD
       - SSN
       - EMAIL
       - PHONE_NUMBER
     ```
     with more enterprise-relevant detectors and prompt injection patterns.
   - Add policy for tool-use constraints, prompt length/body size, and request authentication.

7. **P1 — Add production resilience primitives.**
   - Define HPA/KEDA or min replica strategy for KubeAI workloads.
   - Add PodDisruptionBudgets.
   - Add anti-affinity/topology spread for gateway and telemetry components.
   - Add explicit retries/outlier detection/circuit breaking where the CRD supports it.

8. **P1 — Pin observability selectors and ports to verified reality.**
   - Reconcile the current inconsistency between:
     ```yaml
     targetPort: 19000
     ```
     and:
     ```yaml
     :9091/stats/prometheus (or :15090 on some builds)
     ```
   - Encode the correct scrape target once, then remove “verify manually” comments from production manifests.

9. **P2 — Add versioned dashboards, SLOs, and runbooks.**
   - The current alerts are a good start; add Grafana dashboards and recording rules for availability, p95 latency, fallback rate, cold-start rate, token usage, and model saturation.

10. **P2 — Validate CRD schema compatibility and split lab vs production overlays.**
   - The files currently mix “verified on homelab” assumptions with production-oriented patterns.
   - Create separate overlays or directories for `lab/` and `prod/`, and validate with server-side dry-run against the target cluster CRDs.
