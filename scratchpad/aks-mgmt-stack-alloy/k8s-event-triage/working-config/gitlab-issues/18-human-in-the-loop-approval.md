<!--
Labels: discussion, architecture, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
-->

# Discussion: Human-in-the-loop approval for remediation

## Context

Once the triage pipeline is integrated with Teams, we need to decide how (or if) engineers approve remediation actions before agents execute them.

## Option A: Teams Adaptive Card with Approval Button

Microsoft Teams supports **Adaptive Cards** with action buttons. The workflow could:

1. Agent triages event and proposes remediation steps
2. Workflow posts an Adaptive Card to Teams channel with:
   - Event summary and severity
   - Proposed remediation action (e.g., "restart deployment X", "scale up replicas")
   - **Approve** / **Reject** buttons
3. Button click sends a webhook back to Argo Events
4. A second sensor picks up the approval event and triggers the remediation workflow

**Architecture:**
```
Triage Workflow → Teams Adaptive Card → Engineer clicks Approve
                                              ↓
                              Teams webhook → Argo Events EventSource
                                              ↓
                              Sensor → Remediation Workflow (KAgent)
```

**Pros:**
- Full audit trail (who approved, when)
- Engineers stay in Teams (no context switch)
- Works with existing Teams bot framework

**Cons:**
- Adds latency (waiting for human)
- Requires Teams bot registration and webhook setup
- Need timeout handling (what if nobody approves within X minutes?)
- More complex pipeline (two workflows instead of one)

### Implementation Notes
- Teams Adaptive Cards: use `Action.Http` or a Teams bot with `Action.Submit`
- The approval webhook URL would be an Argo Events webhook EventSource
- Timeout: use Argo Workflows `suspend` step with `duration` — auto-reject after e.g. 30 minutes

## Option B: Pre-Approved Remediation Allow-List

Define a list of actions agents are allowed to take without approval:

| Action | Auto-Approved | Requires Approval |
|--------|--------------|-------------------|
| Restart pod/deployment | Yes | — |
| Scale up replicas (within limits) | Yes | — |
| Rollback to previous image | — | Yes |
| Delete PVC | — | Yes |
| Modify NetworkPolicy | — | Yes |
| Modify RBAC | — | Never (manual only) |
| Scale down to 0 | — | Yes |
| Delete namespace resources | — | Never (manual only) |

**Pros:**
- No latency for safe operations
- Simpler pipeline (single workflow)
- Clear security boundary

**Cons:**
- Less flexibility
- Need to maintain the allow-list
- Risk of auto-remediation causing harm if allow-list is too broad

## Option C: Hybrid (Recommended)

Combine both approaches:
- **Tier 1 (auto):** Safe, reversible actions (restart, scale up) — execute immediately, notify Teams
- **Tier 2 (approval):** Potentially disruptive actions — post Adaptive Card, wait for approval
- **Tier 3 (manual only):** Destructive/irreversible actions — create Gitea issue, never auto-execute

## Decision Needed

- [ ] Which option to pursue (A, B, or C)?
- [ ] If C: define the tier boundaries
- [ ] If A or C: who registers the Teams bot and sets up the webhook?
- [ ] What's the approval timeout? (suggested: 30 minutes → auto-reject)

## Acceptance Criteria

- [ ] Decision documented
- [ ] If approval flow chosen: architecture diagram created
- [ ] If allow-list chosen: allow-list documented and reviewed by SRE team
