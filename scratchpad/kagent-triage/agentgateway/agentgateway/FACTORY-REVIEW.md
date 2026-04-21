# Factory Review v2 — agentgateway

**Reviewer:** Quality Gate Team  
**Date:** 2026-04-17  
**Verdict:** REWORK

---

## Verdict
REWORK — the headline P0 items were mostly addressed, but the authorization policy default-deny logic is flawed, the NetworkPolicy is still too narrow for common Istio sidecar/service-account traffic patterns, and several correctness/operational issues from v1 remain unresolved.

## P0 Fix Verification
| # | Finding | Verdict | Evidence |
|---|---------|---------|----------|
| C1 | Fallback backend dead code | FIXED | `backend-kubeai.yaml` now defines `spec.ai.groups` with two priority entries: group 0 provider `kubeai-primary` and group 1 provider `kubeai-fallback`, both under `kubeai-backend`. This replaces the prior dead standalone fallback concept with actual priority-group failover structure. |
| C4 | Azure API version | FIXED | `backend-azure-openai.yaml` sets `spec.ai.provider.azureopenai.apiVersion: "2024-10-21"`. |
| R1 | No retry logic | FIXED | `istio-virtualservice.yaml` includes `retries.attempts: 3`, `perTryTimeout: 40s`, and `retryOn: "5xx,reset,connect-failure,refused-stream"`. |
| R6 | Timeout cascade | FIXED | `ai-policy.yaml` sets KubeAI `traffic.requestTimeout: "90s"`; `istio-virtualservice.yaml` sets `timeout: 125s`. This satisfies `Istio timeout > gateway timeout`. Retry math is also coherent: `3 × 40s = 120s`, fitting inside the `125s` route timeout. |
| S1 | No NetworkPolicy | FIXED WITH GAPS | `networkpolicy.yaml` now exists and adds `agentgateway-ingress` and `agentgateway-egress`. However ingress only allows `istio-system`, `monitoring`, and `agentgateway-system`, which may be insufficient for some mesh-sidecar/source-namespace patterns. |
| S2 | No AuthorizationPolicy | NOT FIXED | `istio-authorization-policy.yaml` now exists, but the so-called default deny uses `action: DENY` with `notPrincipals: ["*"]`, which only denies requests with no principal. It does **not** deny authenticated but unauthorized principals, so it is not a real default deny. |
| — | Missing VirtualService | FIXED | `istio-virtualservice.yaml` now exists and defines `hosts: [ai-gateway.agentgateway-system.svc.cluster.local]`, `gateways: [mesh]`, route destination `ai-gateway.agentgateway-system.svc.cluster.local:80`, plus retries and timeout. |

## New Issues Found
| Severity | File | Issue | Detail |
|---|---|---|---|
| HIGH | istio-authorization-policy.yaml | Default-deny policy is ineffective for authenticated callers | `action: DENY` + `from.source.notPrincipals: ["*"]` only matches requests with no principal. Any mTLS-authenticated workload not listed in the ALLOW policy is not denied by this rule. The file comment claims it is a catch-all default deny, but it is not. |
| HIGH | networkpolicy.yaml | Ingress policy may break sidecar/mesh traffic depending on source namespace model | Ingress only permits namespace selectors `istio-system`, `monitoring`, and `agentgateway-system`. In many Istio deployments, source traffic may appear from the caller workload namespace (for example `kagent`) rather than from `istio-system`. If agentgateway pods are sidecar-injected, this policy is likely too restrictive. |
| MEDIUM | INSTALL.md | Documentation references `FACTORY-REVIEW.md`, but repo still carries `FACTORY-REVIEW-v1.md` and generated v2 review separately | The file list has been updated to `FACTORY-REVIEW.md`, but the directory still contains `FACTORY-REVIEW-v1.md`; not harmful, but operationally ambiguous. |
| MEDIUM | TEST-PLAN.md | Test plan expects resources that no longer exist in current manifests | Section `1f` expects `kubeai-fallback-backend`, but `backend-kubeai.yaml` now defines only `kubeai-backend` using priority groups internally. This test plan is stale and will fail as written. |
| MEDIUM | TEST-PLAN.md | Timeout expectations are stale | Section `8b` says gateway timeout is `120s`, but `ai-policy.yaml` now sets KubeAI request timeout to `90s`. Documentation/test drift remains. |
| MEDIUM | backend-azure-openai.yaml | ServiceAccount ownership/conflict risk remains unresolved | The manifest still creates `ServiceAccount` `agentgateway` directly. If the Helm chart already owns or names this SA, apply order/ownership conflicts remain possible. |
| MEDIUM | gateway-resources.yaml | ReferenceGrant still uses v1beta1 | `apiVersion: gateway.networking.k8s.io/v1beta1` for `ReferenceGrant` remains inconsistent with the rest of the Gateway API resources using `v1`. |
| MEDIUM | modelconfig-azure.yaml / modelconfig-kubeai.yaml | Client timeout not explicitly set despite timeout-chain note | Review instructions call for `client timeout >= Istio VS timeout >= gateway timeout`. The ModelConfigs specify only `baseUrl`; they do not show any explicit client timeout field, so timeout-chain compliance is undocumented/unverifiable from these manifests. |
| LOW | networkpolicy.yaml | Egress comment for Azure via Istio egress gateway does not match actual rule shape | The comment says Azure OpenAI via Istio egress gateway or direct HTTPS, but the actual rule allows any public IPv4 on TCP/443 except RFC1918. That is broader than an egress-gateway-specific policy. |

## Remaining Open Items (P1/P2)
| Severity | File | Issue | Recommendation |
|---|---|---|---|
| HIGH | gateway-resources.yaml | Azure URL rewrite still needs end-to-end validation | Current syntax is likely valid Gateway API v1 (`type: URLRewrite` with `urlRewrite.path.type: ReplacePrefixMatch`), but it still needs runtime verification against agentgateway + Azure OpenAI path expectations. Keep this as open until tested. |
| HIGH | gateway-resources.yaml | Gateway listener is still plain HTTP | `Gateway.spec.listeners[0].protocol: HTTP`, `port: 80`. If agentgateway is not sidecar-injected, in-cluster hop may be plaintext. Either document trust boundary clearly or add a TLS termination/encryption strategy. |
| HIGH | ai-policy.yaml | Prompt guard is still English-only and limited | Request injection patterns remain only `ignore previous instructions|jailbreak|DAN mode`. Add multilingual and obfuscation-resistant patterns, and Kubernetes-secret-specific detections. |
| MEDIUM | backend-kubeai.yaml | `spec.ai.groups.providers[].openai` structure still unvalidated against live CRD | The shape looks plausible, but no schema validation evidence is included. Validate against installed `agentgatewaybackends.agentgateway.dev` CRD or vendor docs. |
| MEDIUM | modelconfig-azure.yaml / modelconfig-kubeai.yaml | `kagent.dev/v1alpha2` still unvalidated | Confirm the worker-cluster CRD version supports `v1alpha2`; otherwise manifests may be rejected. |
| MEDIUM | backend-azure-openai.yaml | Placeholder substitution risk remains | `REPLACE_WITH_UAMI_CLIENT_ID`, `REPLACE_RESOURCE`, and `REPLACE_DEPLOYMENT_NAME` remain in checked-in manifests. Add a validation script or kustomize gate to prevent accidental deployment with placeholders. |
| MEDIUM | networkpolicy.yaml | No explicit allowance for kube-apiserver/DNS variants beyond current assumptions | DNS only allows `kube-system` TCP/UDP 53; API/identity path only allows IMDS `169.254.169.254:80`. Verify these assumptions against actual CNI, DNS, and workload-identity plumbing. |
| MEDIUM | TEST-PLAN.md | Test plan is out of sync with manifests | Update expected backend names, timeout values, and any authorization/network assertions to reflect the new design. |
| MEDIUM | INSTALL.md | No resource requests/limits or availability guidance | Add Helm values guidance for CPU/memory requests and limits, plus a PodDisruptionBudget recommendation. |
| MEDIUM | (missing) | No health checks / PDB / observability manifests | Add health/readiness policy or deployment guidance, PodDisruptionBudget, metrics scraping, and alerting. |
| LOW | ai-policy.yaml | Rate limiting remains local-only | `traffic.rateLimit.local` is per-instance. If multiple agentgateway replicas are deployed, effective aggregate rate limit scales linearly. Consider global/distributed rate limiting if required. |
| LOW | backend-kubeai.yaml | Dummy secret naming may still mislead operators | Keep dummy key if required by schema, but consider renaming/commenting more explicitly, e.g. `schema-required-not-used`. |

## Final Recommendation
The patch set materially improves the manifest package: the missing VirtualService is present, retries are now defined, the Azure API version has been corrected, timeout ordering is improved, and the KubeAI fallback design has been converted into priority groups. However, this is not yet ready to pass a second quality gate because the new AuthorizationPolicy does not implement a true default deny, and the new NetworkPolicy may still block legitimate mesh traffic depending on how Istio is deployed. In addition, several previously identified correctness and operational concerns remain open, including ServiceAccount ownership ambiguity, stale test documentation, unvalidated CRD field shapes, and limited prompt-guard coverage. Recommend one more rework pass focused on authz correctness, mesh/network validation, and documentation/test-plan alignment before promotion.