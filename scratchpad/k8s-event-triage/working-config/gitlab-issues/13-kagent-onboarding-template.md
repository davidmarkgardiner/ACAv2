<!--
Labels: template, kagent, k8s-event-triage
Milestone: KAgent — Agent Onboarding
Assignee:
-->

# TEMPLATE — KAgent Namespace Agent Onboarding & Fine-Tuning

> **This is a template issue.** Clone it for each namespace you want to onboard a KAgent agent for.
> Replace `{{NAMESPACE}}` and `{{COMPONENT}}` throughout.

---

## Overview

Create, test, and fine-tune a KAgent SRE agent specialised for the `{{NAMESPACE}}` namespace and `{{COMPONENT}}` workload. The agent should understand the component's architecture, common failure modes, and remediation procedures.

## Phase 1: Agent Creation

### 1.1 Research the Component
- [ ] Document what `{{COMPONENT}}` does and how it's deployed in the cluster
- [ ] Identify common failure modes (check past incidents, GitHub issues, runbooks)
- [ ] List the key Kubernetes resources: Deployments, Services, ConfigMaps, Secrets, CRDs
- [ ] Identify the component's dependencies (DNS, cert stores, cloud APIs, etc.)
- [ ] Document expected pod count, resource usage, and normal behaviour

### 1.2 Create the Agent YAML
- [ ] Create `kagent/sre-{{NAMESPACE}}-agent.yaml` with:
  - **System prompt** anchored to exact namespace: `CRITICAL: use exact namespace "{{NAMESPACE}}"`
  - Domain knowledge about `{{COMPONENT}}` baked into the system prompt
  - Known failure patterns and their remediation steps
  - Tools: `call_kubectl` (read-only initially), namespace-scoped RBAC
- [ ] Create corresponding RBAC (Role + RoleBinding) scoped to `{{NAMESPACE}}`
- [ ] Apply agent CRD to cluster

### 1.3 Initial Smoke Test
- [ ] Verify agent responds to basic queries: "What pods are running in `{{NAMESPACE}}`?"
- [ ] Verify agent understands the component: "What does `{{COMPONENT}}` do?"
- [ ] Verify namespace anchoring works (agent doesn't query wrong namespaces)

---

## Phase 2: Fault Injection & Testing

### 2.1 Create Test Scenarios
Design fault injection tests that simulate real failures for `{{COMPONENT}}`:

| # | Fault | How to Inject | Expected Agent Response |
|---|-------|--------------|------------------------|
| 1 | CrashLoopBackOff | Deploy broken config/image | Identify crash reason, suggest fix |
| 2 | ImagePullBackOff | Set image to nonexistent tag | Identify wrong image, suggest correct tag |
| 3 | OOMKilled | Set memory limit too low | Identify OOM, suggest resource increase |
| 4 | Misconfiguration | Apply bad ConfigMap | Identify config error, suggest fix |
| 5 | Dependency failure | Block network to upstream | Identify connectivity issue, suggest checks |
| 6 | CRD/resource-specific | (component-specific) | (component-specific) |

### 2.2 Run Fault Injection Tests
For each test scenario:
- [ ] Inject the fault
- [ ] Trigger the agent (via workflow or direct A2A call)
- [ ] Record agent's response (copy full output)
- [ ] Score: Did it correctly identify the issue? (Y/N)
- [ ] Score: Did it suggest the correct remediation? (Y/N)
- [ ] Score: Was the response actionable? (Y/N)
- [ ] Clean up the fault

### 2.3 Document Results
- [ ] Create `kagent/test-results/{{NAMESPACE}}-results.md` with pass/fail for each scenario
- [ ] Note any incorrect diagnoses or missed issues

---

## Phase 3: Human SRE Review & Fine-Tuning

### 3.1 SRE Review Session
A real SRE or engineer reviews the agent's test results and works with it interactively:

- [ ] SRE reviews Phase 2 test results
- [ ] SRE runs additional ad-hoc queries against the agent
- [ ] SRE identifies:
  - Things the agent got **wrong** (incorrect diagnosis)
  - Things the agent **missed** (should have checked but didn't)
  - Things the agent could do **better** (right direction but incomplete)
  - Things the agent did **well** (keep these patterns)

### 3.2 Prompt Engineering Fixes
Based on SRE feedback, update the agent YAML:

- [ ] Add missed failure patterns to the system prompt
- [ ] Add explicit remediation steps for cases the agent got wrong
- [ ] Add namespace/resource anchoring for any hallucination issues (see memory: KAgent Prompt Engineering)
- [ ] Add YAML examples in system prompt for actionable output
- [ ] Update tool permissions if needed (e.g., add `patch` for remediation mode)

### 3.3 Re-Test
- [ ] Re-run all Phase 2 test scenarios with updated agent
- [ ] Verify previously-failed scenarios now pass
- [ ] Verify previously-passing scenarios still pass (no regression)
- [ ] Record improved scores

---

## Phase 4: Integration & Sign-Off

### 4.1 Wire into Triage Pipeline
- [ ] Add namespace to Alloy's watch list (if not already monitored)
- [ ] Update WorkflowTemplate to route `{{NAMESPACE}}` events to this agent
- [ ] Test end-to-end: inject fault → Alloy picks up event → workflow triggers → agent triages

### 4.2 Documentation
- [ ] Update `AGENT-ROSTER.md` with the new agent
- [ ] Document the agent's specialisation and known limitations
- [ ] Add any new gotchas to `GOTCHAS.md`

### 4.3 Sign-Off
- [ ] SRE approves agent for production use
- [ ] Agent handles at least 3 different fault scenarios correctly
- [ ] No hallucination or wrong-namespace queries observed
- [ ] Response time < 60s for triage mode

---

## Checklist Summary

| Phase | Status |
|-------|--------|
| 1. Agent Creation | [ ] |
| 2. Fault Injection Testing | [ ] |
| 3. SRE Review & Fine-Tuning | [ ] |
| 4. Integration & Sign-Off | [ ] |

---

## Notes for Prompt Engineering

From prior experience (see memory):
- **Namespace anchoring**: Always include `CRITICAL: use exact namespace "{{NAMESPACE}}"` — smaller models like Qwen 14B will hallucinate namespace names without this
- **YAML examples**: Include concrete YAML examples in the system prompt for actionable output
- **Explicit copy instructions**: For any parameter the model might hallucinate, add an explicit "copy this exactly" instruction
- **A2A protocol**: Use `message/send` method (NOT `tasks/send`), trailing slash on URL is required
