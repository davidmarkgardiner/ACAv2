  K8s Cluster generates Warning event
  (ImagePullBackOff, CrashLoopBackOff, OOMKilled, etc.)
                  ↓
  Argo Events EventSource (watches events API)
                  ↓
  Argo Events Sensor (rate limited: 3/min)
                  ↓
  Argo Workflow (AI triage)

  But you can trigger from multiple sources:

  | Trigger Source    | How It Works                                 |
  |-------------------|----------------------------------------------|
  | K8s Events        | EventSource watches kubectl get events       |
  | Prometheus Alerts | AlertManager webhook → Argo Events           |
  | Azure Monitor     | Event Grid → Argo Events webhook             |
  | Manual            | Engineer calls API or clicks button in UI    |
  | Scheduled         | CronWorkflow runs health checks periodically |

  For the Teams message, the trigger options are:

  ┌─────────────────────────────────────────────┐
  │           EVENT SOURCES                      │
  ├─────────────────────────────────────────────┤
  │  • K8s Warning Events (auto)                │
  │  • Prometheus Alerts (auto)                 │
  │  • Azure Monitor Alerts (auto)              │
  │  • Open WebUI chat (manual)                 │
  │  • Teams/Slack bot (manual)                 │
  │  • API call from any app (manual)           │
  └──────────────────┬──────────────────────────┘
                     ↓
              LiteLLM + AKS-MCP
                     ↓
              Diagnose & Fix

  So it's not just reactive to cluster events - engineers can also proactively ask "what's wrong with my cluster?" via chat or API.