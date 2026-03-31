# Design: Agent Memory + A2A Remediation Pipeline

How triage agents use memory to learn from past incidents and collaborate with specialist agents via A2A to execute remediations.

---

## 1. The Problem

Today, every triage event starts from scratch. If the cert-manager agent diagnosed a failing ACME challenge last Tuesday and identified that the ClusterIssuer was pointing at the wrong endpoint, it has no memory of that. When the same issue fires again on Thursday, it re-investigates from zero.

Similarly, when an agent identifies a fix that requires a code change (update a Helm value, fix a misconfigured resource), it can only report the finding. It can't reach out to a GitOps agent to actually implement the fix.

---

## 2. Memory-Assisted Triage

### How it works

```
K8s Warning Event: CrashLoopBackOff in cert-manager namespace
        │
        ▼
Argo Events → Sensor → Workflow
        │
        ▼
cert-manager-agent receives triage request
        │
        ├── Step 1: load_memory("CrashLoopBackOff cert-manager")
        │           ↓
        │   Memory returns:
        │   "2026-03-15: CrashLoopBackOff on cert-manager-controller was caused by
        │    expired ClusterIssuer secret. Fixed by rotating the ACME account key.
        │    See GitLab issue #142."
        │
        ├── Step 2: Investigate current state (kubectl get pods, describe, logs)
        │           Agent now has BOTH past context AND current state
        │
        ├── Step 3: Diagnose with memory context
        │           "This looks like the same ClusterIssuer issue from 2026-03-15.
        │            Last time the fix was rotating the ACME account key.
        │            Checking if that's the case again..."
        │
        ├── Step 4: save_memory("CrashLoopBackOff cert-manager: confirmed same
        │           root cause as #142. ACME account key rotation resolved it.")
        │
        └── Step 5: Output diagnosis with historical context + recommended fix
```

### What the agent CRD looks like (when memory is re-enabled)

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: cert-manager-agent
  namespace: kagent
  labels:
    managed-namespace: cert-manager
spec:
  description: Cert-manager namespace triage specialist with incident memory
  declarative:
    modelConfig: default-model-config
    memory:
      modelConfig: embedding-model      # separate ModelConfig for embeddings
      ttlDays: 90                        # retain memories for 90 days
    systemMessage: |
      CRITICAL: always use exact namespace "cert-manager" when investigating.

      You are a cert-manager specialist. You triage certificate lifecycle issues.

      ## Memory
      Before investigating, ALWAYS call load_memory with the event reason and namespace.
      If you find relevant past incidents, use them to guide your diagnosis.
      After completing your diagnosis, call save_memory with:
      - What the issue was
      - What caused it
      - How it was fixed (or what was recommended)
      - The GitLab issue number if one was created

      ## Your Domain
      - cert-manager controller, webhook, cainjector
      - ClusterIssuers, Issuers, Certificates, CertificateRequests
      - ACME challenges (HTTP-01, DNS-01)
      ...
    tools:
      - type: McpServer
        mcpServer:
          name: kagent-tools
          namespace: kagent
          kind: Service
          toolNames:
            - k8s_get_resources
            - k8s_get_pod_logs
            - k8s_describe_resource
```

### Memory backend

```
┌─────────────────────────────────────────────┐
│  PostgreSQL + pgvector (or pgvectorscale)    │
│                                              │
│  Table: memories                             │
│  ├── content (text)       "CrashLoopBackOff  │
│  │                         cert-manager..."   │
│  ├── embedding (vector)   [0.12, -0.34, ...] │
│  ├── metadata (json)      {agent, session,    │
│  │                         timestamp}         │
│  ├── access_count (int)   7                   │
│  └── expires_at (ts)      2026-06-15          │
│                                              │
│  Index: StreamingDiskANN (pgvectorscale)     │
│  or HNSW (standard pgvector)                 │
└─────────────────────────────────────────────┘
```

### What memory gives us

| Without Memory | With Memory |
|---------------|-------------|
| Agent investigates from scratch every time | Agent checks if it's seen this before |
| Same root cause diagnosed repeatedly | "This matches incident #142 — same fix worked" |
| No institutional knowledge | Knowledge persists across sessions (90-day TTL) |
| Generic recommendations | Specific: "Last time we rotated the ACME key and it fixed it" |
| No learning from false positives | "Last time this was a false alarm — pod was restarting due to config reload, not a bug" |

---

## 3. A2A Remediation Pipeline

### The idea

When a triage agent identifies a fix that requires a code change, it doesn't just report it — it delegates to a **GitOps agent** via A2A to implement the fix.

### How it works

```
cert-manager-agent diagnoses: "ClusterIssuer ACME endpoint is wrong.
  Should be https://acme-v02.api.letsencrypt.org/directory
  but is set to https://acme-staging-v02.api.letsencrypt.org/directory"
        │
        │ Agent-as-tool call (A2A)
        ▼
gitops-remediation-agent
        │
        ├── Step 1: Clone the GitOps repo (git MCP tools)
        │
        ├── Step 2: Find the ClusterIssuer manifest
        │           grep -r "acme-staging" clusters/prod/cert-manager/
        │
        ├── Step 3: Create a fix branch
        │           git checkout -b fix/cert-manager-clusterissuer-endpoint
        │
        ├── Step 4: Apply the fix
        │           sed -i 's|acme-staging-v02|acme-v02|' clusterissuer.yaml
        │
        ├── Step 5: Commit and push
        │           git commit -m "fix: correct ClusterIssuer ACME endpoint
        │                          Automated fix from triage agent.
        │                          Related: GitLab #142"
        │
        ├── Step 6: Create merge request
        │           gitlab api → POST /projects/{id}/merge_requests
        │           Title: "[Auto-Fix] ClusterIssuer ACME endpoint"
        │           Description: includes agent diagnosis + memory context
        │
        └── Step 7: Return MR URL to triage agent
                    "MR !87 created: https://gitlab.com/.../merge_requests/87"
        │
        ▼
cert-manager-agent compiles final output:
  "Diagnosis: Wrong ACME endpoint on ClusterIssuer.
   Memory: Same issue occurred 2026-03-15, GitLab #142.
   Action: MR !87 created to fix the endpoint.
   Awaiting human merge."
        │
        ▼
Workflow continues → GitLab issue + Teams notification
  "Fix available: MR !87 — merge to apply"
```

### Agent setup

```yaml
# Triage agent — has gitops agent as a tool
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: cert-manager-agent
  namespace: kagent
spec:
  description: Cert-manager triage with memory and remediation capability
  declarative:
    modelConfig: default-model-config
    memory:
      modelConfig: embedding-model
      ttlDays: 90
    systemMessage: |
      ...
      ## Remediation
      If you identify a fix that requires a code change in the GitOps repo:
      1. Call gitops-remediation-agent with:
         - What file needs changing
         - What the current value is
         - What it should be changed to
         - Why (your diagnosis)
      2. The gitops agent will create a merge request
      3. Include the MR URL in your output
      4. Do NOT attempt to apply fixes directly to the cluster
    tools:
      # K8s tools for investigation
      - type: McpServer
        mcpServer:
          name: kagent-tools
          namespace: kagent
          kind: Service
          toolNames:
            - k8s_get_resources
            - k8s_get_pod_logs
            - k8s_describe_resource
      # GitOps agent for remediation
      - type: Agent
        agent:
          name: gitops-remediation-agent
          namespace: kagent

---
# GitOps remediation agent — has git + GitLab MCP tools
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: gitops-remediation-agent
  namespace: kagent
spec:
  description: Creates merge requests to fix issues in the GitOps repo
  declarative:
    modelConfig: default-model-config
    systemMessage: |
      You create merge requests in the GitOps repository to fix Kubernetes issues.

      Rules:
      1. NEVER push directly to main — always create a branch and MR
      2. MR title must start with [Auto-Fix]
      3. MR description must include the diagnosis from the triage agent
      4. One fix per MR — do not batch unrelated changes
      5. If you cannot find the file or are unsure about the fix, return an error
         rather than making a wrong change
    tools:
      - type: McpServer
        mcpServer:
          name: git-mcp-server
          namespace: kagent
          kind: Service
          toolNames:
            - git_clone
            - git_checkout
            - git_commit
            - git_push
            - git_diff
            - file_read
            - file_write
      - type: McpServer
        mcpServer:
          name: gitlab-mcp-server
          namespace: kagent
          kind: Service
          toolNames:
            - create_merge_request
          requireApproval:
            - create_merge_request    # HITL gate — human sees MR before it's created
```

### The full flow with memory + A2A

```
K8s Warning Event
    │
    ▼
EventSource → Sensor → Argo Workflow
    │
    ▼
┌─────────────────────────────────────────────────┐
│  cert-manager-agent                              │
│                                                  │
│  1. load_memory("CrashLoopBackOff cert-manager") │
│     → "Seen before: #142, ACME endpoint issue"   │
│                                                  │
│  2. k8s_get_resources, k8s_get_pod_logs          │
│     → Confirms same root cause                   │
│                                                  │
│  3. Calls gitops-remediation-agent (A2A)         │
│     → "Fix acme-staging → acme-v02 in            │
│        clusters/prod/cert-manager/issuer.yaml"   │
│                                                  │
│  4. gitops-remediation-agent:                    │
│     ├── Clones repo                              │
│     ├── Creates branch                           │
│     ├── Applies fix                              │
│     ├── Creates MR !87                           │
│     └── Returns MR URL                           │
│                                                  │
│  5. save_memory("CrashLoopBackOff cert-manager:  │
│     same as #142, ACME endpoint. MR !87 created")│
│                                                  │
│  6. Final output:                                │
│     Diagnosis + memory context + MR link         │
└─────────────────────────────────────────────────┘
    │
    ▼
Workflow continues:
├── GitLab issue: includes diagnosis + MR link
├── Teams notification: "Fix available — merge MR !87 to apply"
└── Agent memory updated for next time
```

---

## 4. Safety Model

| Layer | Control |
|-------|---------|
| **Triage agent** | Read-only k8s tools — can investigate but not modify the cluster |
| **GitOps agent** | Can create branches and MRs, but NEVER pushes to main |
| **MR creation** | `requireApproval` HITL gate — human must approve MR creation |
| **MR merge** | Always manual — human reviews the diff and merges |
| **Flux sync** | Only Flux applies changes to the cluster — agents never `kubectl apply` directly |
| **Memory** | TTL-based (90 days), auto-pruned, agents can save but not delete |

**The agent never touches the cluster directly.** The fix path is always:
```
Agent diagnoses → Agent creates MR → Human merges → Flux syncs → Cluster updated
```

---

## 5. What We Need

### For memory (when kagent re-enables it)
- PostgreSQL with pgvector (already deployed on red cluster for LiteLLM)
- Optional: pgvectorscale for StreamingDiskANN indexing (swap postgres image to `timescale/timescaledb-ha`)
- An embedding ModelConfig (e.g. `text-embedding-3-small` via OpenAI, or a local embedding model via Ollama/KubeAI)

### For A2A remediation
- A git MCP server (clone, branch, commit, push)
- A GitLab MCP server (create MR, add comments)
- Both as Service-type MCP servers in the kagent namespace
- Git credentials as K8s Secret (SSH key or token)
- GitLab API token as K8s Secret

### What exists today vs what we'd build

| Component | Status |
|-----------|--------|
| Triage agents with k8s tools | Done — 11 namespace agents deployed |
| Argo Events → Sensor → Workflow → A2A | Done — full pipeline built and tested |
| kagent memory | Waiting — reverted in v0.8.3, expected back in future release |
| gitops-remediation-agent | Design only — needs git + GitLab MCP servers |
| Agent-as-tool (triage → gitops) | Proven — tested today with dev pipeline (Kimi, 6/6 tool calls) |
| PostgreSQL + pgvector | Deployed on red cluster (used by LiteLLM) |

---

## 6. Reference

### A2A agent-as-tool (proven pattern)
We tested this today with the dev pipeline — coordinator calls 4 worker agents via A2A, all through kagent's native `type: Agent` tool reference. Kimi successfully made 6 consecutive tool calls including a revision loop. Same pattern applies here: triage agent calls gitops agent as a tool.

See: `mission-control-shared/agents/dev-coordinator-agent.yaml`

### Memory implementation (reverted but designed)
- kagent design doc: `kagent/design/EP-1256-memory.md`
- CRD type: `MemorySpec` in `kagent/go/api/v1alpha2/agent_types.go`
- Python implementation: `kagent/python/packages/kagent-adk/src/kagent/adk/_memory_service.py`
- Tools: `save_memory`, `load_memory`, `prefetch_memory`

### Architecture diagrams
- Hybrid triage: `diagram-runtime-triage.excalidraw`
- Dev pipeline (A2A proof): `mission-control-shared/agents/dev-pipeline-architecture.excalidraw`
