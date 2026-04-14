# EASE Integration — Stakeholder Questions

**Date:** 2026-04-14  
**Author:** David Gardiner  
**Status:** Questions for stakeholders — awaiting clarification before any integration work begins

---

## Context

We have a working, tested kagent-based triage system deployed on Kubernetes. We have been asked to evaluate EASE (Enterprise Agentic Service Ecosystem) — described as a secure, scalable Kafka-based communication backbone for AI agents with schema enforcement and OASIS-powered governance.

Before committing to any integration or migration work, we need answers to the following questions.

---

## Our Current Architecture (kagent)

| Attribute | Detail |
|-----------|--------|
| **Runtime** | Kubernetes pods (management cluster per environment) |
| **Agent framework** | kagent v0.8.x — CNCF Sandbox project, Go-based controller |
| **Communication protocol** | A2A (Agent-to-Agent) over HTTP REST within the cluster |
| **Trigger mechanism** | Argo Events → Argo Workflows → kagent API |
| **Tool access** | Native k8s tools via MCP (kubectl-equivalent, no shell) |
| **Deployment model** | GitOps via Flux — Agent CRDs declared in Git |
| **Observability** | Argo Workflows UI, Telegram notifications, Prometheus metrics |
| **LLM routing** | LiteLLM proxy (in-cluster) to internal models |

---

## What We Now Know About EASE

Based on initial review of the EASE docs and team discussion:

- **DevPod ≠ laptop.** DevPods are containerised developer environments running in Kubernetes — they replaced dev VMs. EASE's "install in DevPod" workflow is a developer setup path, not the production deployment model.
- **EASE likely runs in a K8s cluster** and exposes an endpoint that other systems can route to. The DevPod is just how developers interact with and configure it.
- **EASE has built its own A2A-like protocol** implemented in Python. It is conceptually similar to the CNCF A2A spec but is a distinct implementation.
- **CRD pattern is similar to kagent.** EASE uses a `KIND: Agent` and `KIND: LLM` — the agent points to the LLM, the LLM points to the model. This mirrors kagent's `Agent → ModelConfig → LiteLLM` chain.
- **Python + UV** is the development runtime for writing EASE agents — it is not clear whether this is mandatory for all agents or just for the EASE SDK tooling.

---

## Remaining Questions for the EASE Team

### 1. Production Deployment — Shared Instance or Self-Hosted?

**Question:** Is there a shared, centrally-operated EASE instance we connect to, or do we deploy and operate EASE ourselves in our management cluster?

**Why this matters:** If it's shared, we need the endpoint URL, auth method, and SLA. If we self-host, we need the Helm chart/manifests and an understanding of the operational overhead — we'd be running Kafka, EASE control plane, and our existing stack.

**Specific ask:** Provide the production endpoint (or Helm chart), and confirm who is responsible for operating the EASE infrastructure.

---

### 2. Kafka — Is It Still Required?

**Question:** Early docs mention Kafka as the messaging backbone. Given EASE also appears to expose an HTTP endpoint, is Kafka a runtime requirement for all deployments, or only for specific high-throughput scenarios?

**Why this matters:** We currently use NATS (via Argo EventBus). Adding Kafka is a significant infrastructure dependency — provisioning, operations, security, and monitoring. If EASE's HTTP endpoint is sufficient for our use case (event-triggered triage workflows), Kafka may be unnecessary complexity.

**Specific ask:** Confirm whether Kafka is mandatory, optional, or only required for cross-org fanout scenarios.

---

### 3. Protocol Bridge — Can We Call EASE Agents from Argo Workflows?

**Question:** Our trigger chain is: `Argo Events → Argo Workflows → HTTP POST to kagent A2A endpoint`. Can we replace the last step with a call to a EASE agent endpoint using the same pattern?

**Why this matters:** If EASE exposes an HTTP endpoint that accepts a task/message and returns a result (similar to our current `POST /api/a2a/kagent/{agent-name}/`), integration is a configuration change. If EASE requires us to publish to a Kafka topic and consume results asynchronously, it's a workflow redesign.

**Specific ask:** Show us the request/response shape for sending a task to a EASE agent from an external system (e.g., a curl example or Postman collection).

---

### 4. Agent Portability — Do Our Existing kagent Agents Need to Be Rewritten?

**Question:** Our agents are kagent CRDs — they run inside the kagent Go controller with native Kubernetes tooling. EASE appears to define agents using Python and its own SDK. Can EASE route tasks to our existing kagent agents (treating them as external A2A endpoints), or does EASE require agents to be implemented using the EASE Python SDK?

**Why this matters:** This is the pivotal question. If EASE can call our kagent agents as external endpoints, the integration is a routing layer. If EASE requires agents to be in its own runtime, this is a months-long rebuild of a system that is already tested and in use.

**Options we'd like clarity on:**

| Option | Description | Our Assessment |
|--------|-------------|----------------|
| **A — EASE as gateway** | EASE exposes our kagent agents under its governance umbrella via an adapter | Preferred — low risk |
| **B — Hybrid** | EASE handles cross-org routing; kagent handles in-cluster triage natively | Acceptable — some integration work |
| **C — Full migration** | Rebuild all agents in the EASE Python SDK | High risk — months of work, proven system at risk |

---

### 5. LLM Routing — Does EASE Have Its Own, or Can It Use Ours?

**Question:** EASE uses a `KIND: LLM` CRD that points to a model. We already have LiteLLM running in-cluster, routing to approved internal models. Do we configure EASE to use our existing LiteLLM endpoint, or does EASE have its own LLM routing that must be used?

**Why this matters:** We have model approvals, rate limiting, and cost tracking already set up through LiteLLM. Bypassing it or duplicating it adds governance risk.

**Specific ask:** Confirm whether the EASE LLM CRD can point to a LiteLLM proxy endpoint, and whether there are any restrictions on model selection.

---

### 6. Security and Network Connectivity

**Question:** Our agent pods run inside AKS clusters with egress restrictions and network policies. What outbound connectivity does EASE require from our pods?

**Specific ask:** Provide:
- The EASE endpoint hostname and port
- Authentication method (bearer token, mTLS, OIDC, API key?)
- Whether secrets are injected via Kubernetes Secrets or another mechanism
- Whether EASE requires inbound connectivity to our cluster (webhooks, callbacks)

---

### 7. Scope of the Ask — What Is EASE Trying to Solve for Us?

**Question:** We need to understand the intended outcome. Is the ask:

| Intent | Description |
|--------|-------------|
| **Governance** | Our agents continue operating as-is, but their interactions are registered and observable via EASE for enterprise audit/compliance |
| **Interoperability** | Our agents can be discovered and called by other teams' agents via the EASE fabric |
| **Standardisation** | All new agents across the org must be built on EASE going forward |
| **Migration** | Existing agents should be moved onto EASE |

This shapes everything — scope, timeline, risk, and whether we're talking about weeks or months of work.

---

## Updated Gap Assessment

| Gap | What We Now Know | Remaining Risk | Blocker? |
|-----|-----------------|----------------|---------|
| K8s deployment | EASE likely runs in K8s, DevPod is dev tooling | Need endpoint/Helm chart | Yes |
| Kafka requirement | May be optional if HTTP endpoint exists | Need confirmation | Possibly |
| Protocol bridge (Argo → EASE) | EASE has HTTP endpoint — shape unknown | Need request/response example | Yes |
| Agent portability | EASE has similar CRD pattern to kagent | Unclear if it can wrap kagent agents | Yes |
| LLM routing | EASE has its own LLM CRD | Can it point to our LiteLLM? | Medium |
| Network/auth | Unknown | Need endpoint + auth details | Yes |
| Scope/intent | Undefined | Determines weeks vs months | Yes |

---

## Recommended Next Step

Request a **45-minute technical session** with the EASE team covering:

1. A live demo of sending a task to a EASE agent from an external HTTP caller
2. Confirmation of whether EASE can treat our kagent A2A endpoints as registered agents
3. The production endpoint or self-host deployment manifest

We should not begin any integration or migration work until question 4 (agent portability) is answered. That single question determines whether this is a routing integration or a platform rebuild.
