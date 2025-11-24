# Dual Namespace RBAC Restrictions

## Overview

This document outlines the approach for implementing additional access restrictions in a dual-namespace deployment model where teams onboard with a shared RBAC automation process but require differentiated access between their **app** and **deploy** namespaces.

## Background

### Current State

- Teams onboard to the shared cluster using the standard process (namespace prefix `atXXXXX`, e.g., `at12345`)
- Onboarding automation creates namespaces and configures RBAC
- Human accounts and SPNs receive **namespace admin** access via the automation
- This works well for single-namespace use cases

### New Requirement

An Ansible operator team requires **two namespaces** per onboarding:

| Namespace | Purpose | Desired Access Level |
|-----------|---------|---------------------|
| `atXXXXX-app` | Application workloads | Full namespace admin (current behaviour) |
| `atXXXXX-deploy` | Operator deployment namespace | Restricted - minimal operator tasks only |

### Constraints

- **Do not modify** the existing RBAC automation
- Restrictions should apply to the SPN, not necessarily human accounts
- Need to restrict both **CRD operations** and **log access**

---

## Proposed Solution

### 1. CRD Operation Restrictions → Kyverno Cluster Policy

**Status: ✅ Achievable**

Kyverno acts as an admission controller that evaluates requests *after* RBAC authorisation but *before* persistence. This allows us to layer additional restrictions on top of existing RBAC without modifying the automation.

#### How It Works

```
Request Flow:
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│  Client  │ ──▶ │   RBAC   │ ──▶ │ Kyverno  │ ──▶ │  etcd    │
│  (SPN)   │     │ (Allow)  │     │ (Deny)   │     │          │
└──────────┘     └──────────┘     └──────────┘     └──────────┘
                     ✓                ✗
                "You CAN do      "But we WON'T
                 this"            let you"
```

#### Example Policy Structure

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-deploy-namespace-operations
spec:
  validationFailureAction: Enforce
  rules:
    - name: deny-restricted-operations
      match:
        any:
          - resources:
              kinds:
                - "<API_GROUP>/<VERSION>/<KIND>"  # e.g., "ansible.example.com/v1/AnsibleJob"
              operations:
                - DELETE  # Operations to block
              namespaces:
                - "at*-deploy"
      exclude:
        any:
          - subjects:
              - kind: ServiceAccount
                name: <OPERATOR_SERVICE_ACCOUNT>
                namespace: <OPERATOR_NAMESPACE>
      validate:
        deny: {}
        message: "This operation is not permitted in deploy namespaces"
```

### 2. Log Access Restrictions → External Logging

**Status: ⚠️ Not achievable via Kubernetes admission control**

#### Why Kyverno Cannot Help

Admission controllers only intercept **mutating** operations and **CONNECT** (exec/port-forward). The `pods/log` endpoint is a pure **read** operation that bypasses admission webhooks entirely.

#### Recommended Approach

Ship logs to an external platform where access control can be managed independently of Kubernetes RBAC.

```
┌─────────────────────────────────────────────────────────────┐
│                    Deploy Namespace                         │
│  ┌─────────────┐      ┌─────────────┐                      │
│  │   App Pod   │      │  Fluent Bit │                      │
│  │             │ ───▶ │  (sidecar)  │ ──────────────────┐  │
│  │  stdout/err │      │             │                   │  │
│  └─────────────┘      └─────────────┘                   │  │
└─────────────────────────────────────────────────────────│──┘
                                                          │
                                                          ▼
                                          ┌───────────────────────┐
                                          │   External Logging    │
                                          │   (Log Analytics /    │
                                          │    Splunk / Loki)     │
                                          │                       │
                                          │  Access controlled    │
                                          │  at platform layer    │
                                          └───────────────────────┘
```

#### Benefits of External Logging

| Benefit | Description |
|---------|-------------|
| **Granular Access Control** | Logging platforms have sophisticated RBAC independent of Kubernetes |
| **Persistence** | Logs survive pod restarts and deletions |
| **Audit Trail** | Track who accessed which logs and when |
| **Scalability** | Designed for log management at scale |
| **Retention Policies** | Configure how long logs are kept |

---

## Information Required from App Team

Before we can implement the Kyverno policy, we need the following information:

### 1. CRD Details

| Question | Example | Your Answer |
|----------|---------|-------------|
| What is the CRD API Group? | `ansible.example.com` | |
| What is the CRD Version? | `v1alpha1` | |
| What is the CRD Kind? | `AnsibleJob` | |
| Full resource path? | `ansible.example.com/v1alpha1/AnsibleJob` | |

### 2. Operations to Restrict

Please confirm which operations should be **blocked** in the deploy namespace:

| Operation | Block? | Notes |
|-----------|--------|-------|
| CREATE | ☐ | |
| UPDATE | ☐ | |
| PATCH | ☐ | |
| DELETE | ☐ | |
| GET | N/A | Cannot be blocked via admission control |
| LIST | N/A | Cannot be blocked via admission control |
| WATCH | N/A | Cannot be blocked via admission control |

### 3. Exclusions

Which identities should be **excluded** from restrictions (i.e., still have full access)?

| Identity Type | Name/Pattern | Namespace | Reason |
|---------------|--------------|-----------|--------|
| ServiceAccount | | | Operator's own SA for reconciliation |
| ClusterRole | `cluster-admin` | N/A | Break-glass access |
| User | | N/A | Platform team? |

### 4. Example Scenario

Please provide a concrete example of a scenario you want to prevent:

```
As a: [identity type, e.g., "the app namespace SPN"]
I should NOT be able to: [action, e.g., "delete an AnsibleJob CR"]
In namespace: [e.g., "at12345-deploy"]
Because: [reason, e.g., "this could disrupt operator deployments"]
```

### 5. Logging Approach

| Question | Options | Your Answer |
|----------|---------|-------------|
| Can you ship logs externally? | Yes / No / Need investigation | |
| Preferred logging platform? | Azure Monitor / Splunk / Loki / Other | |
| Preferred shipper? | Fluent Bit / Fluentd / Vector / Other | |
| Is sidecar acceptable? | Yes / No (prefer DaemonSet) | |

---

## Next Steps

1. **App Team**: Complete the information requirements above
2. **Platform Team**: Draft Kyverno policy based on provided details
3. **Joint**: Test policy in audit mode (`validationFailureAction: Audit`)
4. **Joint**: Validate blocked scenario and confirm expected behaviour
5. **Platform Team**: Promote to enforce mode
6. **App Team**: Implement external logging solution for log access control

---

## Summary

| Requirement | Approach | Feasibility |
|-------------|----------|-------------|
| Restrict CRD operations (create/update/delete) | Kyverno ClusterPolicy | ✅ Fully achievable |
| Restrict log access | External logging platform | ✅ Achievable (requires app changes) |
| Restrict log access at K8s layer | N/A | ❌ Not possible with admission controllers |

---

## Contact

For questions or to provide the required information, please contact the Platform Engineering team.