# GitLab Issues — K8s Event Triage Production Readiness

Copy each `.md` file as a new GitLab issue. Suggested labels and milestones are in the frontmatter of each file.

## Issue Index

### Pipeline — Fix & Stabilise PoC
| # | File | Title |
|---|------|-------|
| 1 | `01-debug-workflow-pod-creation.md` | Workflows created but pods not running — debug and fix |
| 2 | `02-cleanup-old-configs.md` | Clean out old/unused configurations from repo |

### Pipeline — Production Hardening
| # | File | Title |
|---|------|-------|
| 3 | `03-workflow-controller-namespace.md` | Configure workflow controller for argo-events namespace |
| 4 | `04-eventbus-ha-resize.md` | Resize EventBus from 1 to 3 replicas (HA) |
| 5 | `05-deploy-ollama-llm.md` | Deploy Ollama with qwen2.5:7b for LLM triage step |
| 6 | `06-workflow-template-v2.md` | Upgrade WorkflowTemplate to v2 (LLM + Gitea + notifications) |
| 7 | `07-sensor-rate-limit.md` | Increase sensor rate limit from 5/min to 30/min |
| 8 | `08-secrets-and-credentials.md` | Create production secrets (Gitea, Mattermost, Event Hub) |
| 9 | `09-alloy-namespace-expansion.md` | Expand Alloy to watch additional application namespaces |
| 10 | `10-monitoring-and-alerting.md` | Set up monitoring, health checks, and Azure Monitor alerts |
| 11 | `11-smoke-test-suite.md` | Create end-to-end smoke test script |
| 12 | `12-private-registry-images.md` | Mirror all container images to private registry |

### KAgent — Agent Onboarding & Fine-Tuning
| # | File | Title |
|---|------|-------|
| 13 | `13-kagent-onboarding-template.md` | **TEMPLATE** — KAgent namespace agent onboarding & fine-tuning |
| 14 | `14-kagent-cert-manager.md` | KAgent: cert-manager namespace agent |
| 15 | `15-kagent-external-dns.md` | KAgent: external-dns namespace agent |
| 16 | `16-kagent-ingress-nginx.md` | KAgent: ingress-nginx namespace agent |

### Observability & Monitoring
| # | File | Title |
|---|------|-------|
| 19 | `19-kagent-observability-lgtm.md` | KAgent logging and observability via LGTM stack |
| 20 | `20-litellm-monitoring-tokens.md` | LiteLLM monitoring — token usage, latency, and cost tracking |

### Architecture & Design Decisions
| # | File | Title |
|---|------|-------|
| 18 | `18-human-in-the-loop-approval.md` | Discussion: Human-in-the-loop approval for remediation |
| 21 | `21-hybrid-architecture-exploration.md` | Architecture: Hybrid management/worker cluster model |
| 22 | `22-sad-security-compliance.md` | SAD documentation — Security, Authentication, and Compliance |

### Production Security & Migration
| # | File | Title |
|---|------|-------|
| 23 | `23-kagent-worker-cluster-migration.md` | Migrate kagent to worker clusters — hybrid management/worker model |
| 24 | `24-rbac-lockdown-management-cluster.md` | RBAC lockdown — secure kagent on management cluster |
| 25 | `25-kagent-unsolicited-workload-protection.md` | Protect kagent namespace from unsolicited workloads |
| 26 | `26-sad-architecture-document.md` | Solution Architecture Document (SAD) — K8s Event Triage Platform |

### Go-Live
| # | File | Title |
|---|------|-------|
| 17 | `17-go-nogo-checklist.md` | Production go/no-go checklist and cutover |

---

## Work Split (2026-03-16)

### David — KAgent Agent Quality (Kind cluster → lift to AKS)

**Phase 1 — Kind cluster (battle-test locally):**
| Namespace | Status | Notes |
|-----------|--------|-------|
| cert-manager | Tested (3/5 faults) | 7/7 pass — agent has admin tools, auto-patched cainjector |
| kyverno | Tested (1 scenario) | 7/7 pass — found require-labels policy flood |
| external-secrets | Tested (1 scenario) | 7/7 pass — SecretStore not found diagnosis |
| kro | Tested (1 scenario) | 7/7 pass — controller crash history found |
| reloader | Tested (1 scenario) | 7/7 pass — missing resource limits + broken env vars |

**Phase 2 — AKS cluster (production environment):**
| Namespace | Notes |
|-----------|-------|
| flux-system | GitOps controller |
| aks-istio-ingress | AKS Istio addon (NOT ingress-nginx — dropped #16) |
| gateway | Gateway API resources |

Process: onboard → test → tune → battle-test → lift-and-shift to AKS

### Colleagues — Can Be Picked Up Independently
| # | Title | Notes |
|---|-------|-------|
| 5/6 | LLM fallback option | What happens when primary LLM is down |
| 6 | Teams notifications | Swap Mattermost webhooks for Teams |
| 10 | Prometheus monitoring & alerting | PrometheusRules, Grafana dashboards, Azure Monitor |
| 19 | KAgent logging via Alloy/LGTM | Logs/traces/metrics into Loki/Tempo/Mimir |
| 20 | LiteLLM token/cost monitoring | Dashboard + budget alerts |
| 21 | Hybrid cluster architecture | Explore AI stack on worker clusters |
| 22 | SAD security & compliance docs | Solution Architecture Document |
