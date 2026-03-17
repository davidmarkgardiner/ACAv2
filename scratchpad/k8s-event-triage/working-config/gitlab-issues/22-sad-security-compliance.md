<!--
Labels: documentation, security, compliance, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
-->

# SAD documentation — Security, Authentication, and Compliance

## Context

Stakeholders require a Solution Architecture Document (SAD) covering security posture, authentication flows, and compliance considerations for the k8s-event-triage pipeline.

## Document Sections Required

### 1. System Overview & Data Flow
- [ ] Architecture diagram (Excalidraw) showing all components and data flows
- [ ] Data classification: what data flows through each component
- [ ] Network boundaries: which components communicate across clusters/services

### 2. Event Hub Security
- [ ] **Authentication**: SAS tokens (Shared Access Signatures)
  - Document: which SAS policy (Send, Listen, Manage) each component uses
  - Alloy (workload clusters): **Send** only — cannot read events
  - EventSource (management cluster): **Listen** only — cannot write events
  - No component has **Manage** — key rotation is a manual/CI process
- [ ] **Encryption in transit**: TLS 1.2+ enforced (Event Hub Kafka endpoint)
- [ ] **Encryption at rest**: Azure-managed encryption (Event Hub Standard/Premium)
- [ ] **Network access**: Private endpoint vs public endpoint decision
  - If public: IP allowlist? Service tags?
  - If private: Private Link + DNS configuration
- [ ] **Key rotation**: How SAS tokens are rotated, who has access, frequency
- [ ] **Retention**: Event Hub message retention period (24h default, configurable)

### 3. KAgent Security
- [ ] **RBAC**: Namespace-scoped Roles (not ClusterRoles) — agents can only access their target namespace
- [ ] **Service Account**: Dedicated SA per agent, principle of least privilege
- [ ] **Read-only vs write**: Triage agents are read-only; remediation agents need patch/update
- [ ] **Tool restrictions**: `call_kubectl` scoped to allowed verbs and resources
- [ ] **A2A protocol**: Internal cluster communication only (ClusterIP service, no external exposure)
- [ ] **Audit logging**: All agent actions logged (see ticket #19)

### 4. LiteLLM / LLM Security
- [ ] **API key management**: LiteLLM API key stored as K8s Secret, not in ConfigMap
- [ ] **Model access**: Which models are accessible, who controls the model list
- [ ] **Data privacy**: What data is sent to the LLM? (K8s event text, pod names, namespace names)
  - No secrets or sensitive config values should reach the LLM
  - The parse-event step should strip sensitive fields before LLM triage
- [ ] **Rate limiting**: LiteLLM per-key rate limits prevent abuse
- [ ] **Network**: LiteLLM is ClusterIP only — no external access
- [ ] **If using external LLM (OpenAI, Azure OpenAI)**: data residency, DPA, compliance

### 5. Secrets Management
- [ ] Inventory of all secrets (see ticket #8)
- [ ] Secret rotation procedures
- [ ] Who has access to create/modify secrets (RBAC on K8s secrets)
- [ ] Consider: Azure Key Vault integration via External Secrets Operator for production
- [ ] Secret scanning in CI pipeline (detect-secrets baseline)

### 6. Network Security
- [ ] NetworkPolicies: isolate argo-events, kagent, ollama namespaces
- [ ] Egress rules: which pods need external access (Alloy → Event Hub, Ollama model pulls)
- [ ] Ingress rules: no external ingress to pipeline components (internal only)
- [ ] Service mesh (Istio) considerations if applicable

### 7. Compliance & Audit
- [ ] **Audit trail**: Every workflow execution is logged with inputs/outputs (Argo Workflows)
- [ ] **Agent actions**: All KAgent actions logged to Loki (#19)
- [ ] **LLM usage**: Token usage tracked via LiteLLM (#20)
- [ ] **Access control**: Who can deploy/modify pipeline components (GitOps + RBAC)
- [ ] **Change management**: All changes via Git PR (GitOps), reviewed before merge
- [ ] **Data retention**: How long are workflow logs, agent logs, and LLM logs retained

### 8. Threat Model (STRIDE)
- [ ] **Spoofing**: Can an attacker inject fake events into Event Hub?
  - Mitigation: SAS tokens with Send-only policy, IP restrictions
- [ ] **Tampering**: Can events be modified in transit?
  - Mitigation: TLS encryption, Event Hub integrity guarantees
- [ ] **Repudiation**: Can actions be taken without audit trail?
  - Mitigation: Argo Workflows history, KAgent logging, LiteLLM logging
- [ ] **Information Disclosure**: Can sensitive data leak via LLM?
  - Mitigation: Strip sensitive fields in parse-event step, ClusterIP-only LLM
- [ ] **Denial of Service**: Can the pipeline be overwhelmed?
  - Mitigation: Sensor rate limiting, Event Hub throttling, Ollama queue limits
- [ ] **Elevation of Privilege**: Can an agent escalate beyond its namespace?
  - Mitigation: Namespace-scoped RBAC, no ClusterRoles for agents

## Deliverables

- [ ] SAD document (markdown, stored in repo)
- [ ] Architecture diagram (Excalidraw) — security-focused view showing auth flows
- [ ] Threat model summary table
- [ ] Secrets inventory table
- [ ] RBAC matrix (who/what can access what)

## Acceptance Criteria

- [ ] SAD reviewed by security/compliance stakeholder
- [ ] All sections completed with current-state documentation
- [ ] Architecture diagram shows all auth flows and trust boundaries
- [ ] No unmitigated high-severity threats in STRIDE analysis
