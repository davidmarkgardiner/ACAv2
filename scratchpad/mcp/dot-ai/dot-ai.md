
## Yes! Viktor Farcic's `dot-ai` Has Built Exactly This

DevOps AI Toolkit brings AI-powered intelligence to platform engineering, Kubernetes operations, and development workflows. It provides intelligent Kubernetes deployment recommendations through capability discovery and semantic matching, AI-powered issue remediation, automated repository setup with governance and security files, and shared prompt libraries for consistent development workflows—all through natural language conversation.

### Key Features That Match Your Requirements

**AI-Powered Remediation:**

- 🔍 AI-Powered Root Cause Analysis: Multi-step investigation loop identifies the real cause behind Kubernetes failures
- 🛠️ Executable Remediation: Generates specific kubectl commands with risk assessment and validation
- ⚡ Dual Execution Modes: Manual approval workflow or automatic execution based on confidence thresholds
- 🔒 Safety Mechanisms: Automatic fallback to manual mode when validation discovers additional issues
- 🎯 Cross-Resource Intelligence: Understands how pod issues may require fixes in different resource types (storage, networking, etc.)


**Pattern & Policy Management:**
Capture organizational knowledge and governance policies that automatically enhance AI recommendations with best practices and compliance requirements. Uses vector search for intelligent semantic matching.

### How It Compares to What I Proposed

| Feature | dot-ai | My Auto-Healer Concept |
|---------|--------|------------------------|
| AI root cause analysis | ✅ Built-in | ✅ Via LLM call |
| Executable remediation | ✅ kubectl commands | ✅ kubectl commands |
| Dual execution modes | ✅ Manual/Auto | ✅ Manual/Auto |
| Confidence thresholds | ✅ Yes | ✅ Yes |
| Safety fallback | ✅ Built-in | ✅ Via decision gate |
| Cross-resource intelligence | ✅ Yes | ⚠️ Would need building |
| Organisational patterns | ✅ Vector search | ⚠️ ConfigMap-based |
| Policy enforcement | ✅ Built-in | ⚠️ Via Kyverno |
| MCP integration | ✅ Native | ❌ Argo Events-based |
| Event-driven triggers | ❌ On-demand | ✅ Continuous watching |

### The Key Difference

**dot-ai** is **on-demand** (like AKS-MCP) - you ask it to investigate and fix issues through conversation.

**My Auto-Healer concept** adds the **event-driven trigger layer** - it watches continuously and invokes AI when problems occur.

---

## You Could Combine Both

```
┌─────────────────────────────────────────────────────┐
│              Argo Events (Watch Layer)              │
│  - K8s Events, Pod Status, Prometheus Alerts        │
└──────────────────────┬──────────────────────────────┘
                       │ Trigger
                       ▼
┌─────────────────────────────────────────────────────┐
│              dot-ai MCP Server                      │
│  - AI Root Cause Analysis                           │
│  - Remediation with Safety Mechanisms               │
│  - Organisational Patterns & Policies               │
└──────────────────────┬──────────────────────────────┘
                       │ Execute
                       ▼
┌─────────────────────────────────────────────────────┐
│              Kubernetes Cluster                     │
└─────────────────────────────────────────────────────┘
```

### Setup Path

1. **Install dot-ai** via Docker or npm
2. **Configure it with your clusters**
3. **Use it conversationally** to test remediation
4. **Later**: Add Argo Events triggers to invoke dot-ai automatically

---

Want me to look at setting up dot-ai alongside the AKS-MCP you just configured, or update the auto-healer README to integrate dot-ai as the remediation engine?