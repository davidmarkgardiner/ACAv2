# AKS Auto-Healer: Event-Driven AI Remediation

A conceptual architecture for building an autonomous self-healing system for AKS clusters using events, logs, and AI-powered decision making.

## The Gap

AKS-MCP provides excellent **on-demand** AI-assisted debugging, but it's reactive - you have to ask it questions. What if we could create a system that:

- **Watches** for problems continuously
- **Analyses** issues using AI
- **Decides** on remediation actions
- **Executes** fixes (with optional human approval)
- **Learns** from outcomes

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AKS CLUSTER                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │    Pods      │  │   Events     │  │    Logs      │  │   Metrics    │    │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘    │
└─────────┼─────────────────┼─────────────────┼─────────────────┼─────────────┘
          │                 │                 │                 │
          ▼                 ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         EVENT COLLECTION LAYER                               │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐          │
│  │  Argo Events     │  │  Azure Event     │  │  Prometheus/     │          │
│  │  EventSource     │  │  Grid            │  │  AlertManager    │          │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘          │
└───────────┼─────────────────────┼─────────────────────┼─────────────────────┘
            │                     │                     │
            ▼                     ▼                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         EVENT BUS / ROUTER                                   │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    Argo Events Sensor / EventBus                      │  │
│  │                    (Filter, Dedupe, Route by severity/type)           │  │
│  └────────────────────────────────┬─────────────────────────────────────┘  │
└───────────────────────────────────┼─────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AI ANALYSIS LAYER                                    │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    Argo Workflow: AI Triage                           │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │ Gather      │─▶│ Call LLM    │─▶│ Parse       │─▶│ Decision    │  │  │
│  │  │ Context     │  │ (Claude/    │  │ Response    │  │ Gate        │  │  │
│  │  │             │  │  GPT-4)     │  │             │  │             │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  └────────────────────────────────┬─────────────────────────────────────┘  │
└───────────────────────────────────┼─────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
            ┌───────────┐   ┌───────────┐   ┌───────────┐
            │ Auto-fix  │   │ Human     │   │ Escalate  │
            │ (Low Risk)│   │ Approval  │   │ (Alert)   │
            └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
                  │               │               │
                  ▼               ▼               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         REMEDIATION LAYER                                    │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    Argo Workflow: Execute Fix                         │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │ Apply       │─▶│ Verify      │─▶│ Rollback    │─▶│ Record      │  │  │
│  │  │ Fix         │  │ Health      │  │ if Failed   │  │ Outcome     │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Event Collection Layer

#### Kubernetes Events (Argo Events EventSource)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: k8s-events
  namespace: argo-events
spec:
  resource:
    k8s-events:
      namespace: ""  # All namespaces
      version: v1
      resource: events
      eventTypes:
        - ADD
        - UPDATE
      filter:
        # Focus on warning/error events
        labels:
          - key: type
            operation: "!="
            value: "Normal"
```

#### Pod Status Changes

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: pod-status
  namespace: argo-events
spec:
  resource:
    pods:
      namespace: ""
      version: v1
      resource: pods
      eventTypes:
        - UPDATE
      filter:
        # Trigger on CrashLoopBackOff, OOMKilled, etc.
        afterAction: true
        fields:
          - key: status.phase
            operation: "=="
            value: "Failed"
```

#### Azure Monitor Alerts (via Event Grid)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: azure-alerts
  namespace: argo-events
spec:
  azureEventsHub:
    alerts:
      fqdn: "<namespace>.servicebus.windows.net"
      hubName: "aks-alerts"
      sharedAccessKeyName: "RootManageSharedAccessKey"
      sharedAccessKey:
        name: azure-eventhub-secret
        key: sharedAccessKey
```

#### Prometheus AlertManager Webhook

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: alertmanager
  namespace: argo-events
spec:
  webhook:
    alertmanager:
      port: "12000"
      endpoint: /alerts
      method: POST
```

### 2. Event Router (Argo Events Sensor)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: aks-auto-healer
  namespace: argo-events
spec:
  dependencies:
    - name: k8s-warning-event
      eventSourceName: k8s-events
      eventName: k8s-events
      filters:
        data:
          - path: body.type
            type: string
            value:
              - "Warning"
    
    - name: pod-crashloop
      eventSourceName: pod-status
      eventName: pods
      filters:
        data:
          - path: body.status.containerStatuses[0].state.waiting.reason
            type: string
            value:
              - "CrashLoopBackOff"
              - "ImagePullBackOff"
              - "OOMKilled"
    
    - name: azure-alert
      eventSourceName: azure-alerts
      eventName: alerts
  
  triggers:
    - template:
        name: ai-triage-workflow
        k8sResource:
          operation: create
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: ai-triage-
              spec:
                workflowTemplateRef:
                  name: ai-triage-template
          parameters:
            - src:
                dependencyName: k8s-warning-event
                dataKey: body
              dest: spec.arguments.parameters.0.value
```

### 3. AI Analysis Workflow

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: ai-triage-template
  namespace: argo-events
spec:
  entrypoint: triage
  arguments:
    parameters:
      - name: event-data
      - name: cluster-name
        value: "production-aks"
      - name: resource-group
        value: "aks-rg"
  
  templates:
    - name: triage
      steps:
        # Step 1: Gather context
        - - name: gather-context
            template: gather-context
            arguments:
              parameters:
                - name: event-data
                  value: "{{workflow.parameters.event-data}}"
        
        # Step 2: AI Analysis
        - - name: ai-analysis
            template: call-llm
            arguments:
              parameters:
                - name: context
                  value: "{{steps.gather-context.outputs.parameters.context}}"
        
        # Step 3: Decision gate
        - - name: decision
            template: decision-gate
            arguments:
              parameters:
                - name: analysis
                  value: "{{steps.ai-analysis.outputs.parameters.analysis}}"
        
        # Step 4: Execute (based on decision)
        - - name: auto-fix
            template: execute-fix
            when: "{{steps.decision.outputs.parameters.action}} == 'auto-fix'"
            arguments:
              parameters:
                - name: fix-command
                  value: "{{steps.ai-analysis.outputs.parameters.fix-command}}"
          
          - name: request-approval
            template: human-approval
            when: "{{steps.decision.outputs.parameters.action}} == 'approval-required'"
          
          - name: escalate
            template: send-alert
            when: "{{steps.decision.outputs.parameters.action}} == 'escalate'"

    - name: gather-context
      inputs:
        parameters:
          - name: event-data
      container:
        image: mcr.microsoft.com/azure-cli:latest
        command: ["/bin/bash"]
        args:
          - -c
          - |
            EVENT='{{inputs.parameters.event-data}}'
            NAMESPACE=$(echo $EVENT | jq -r '.involvedObject.namespace // "default"')
            POD_NAME=$(echo $EVENT | jq -r '.involvedObject.name // ""')
            
            # Gather related context
            CONTEXT="{}"
            
            # Get pod details
            if [ -n "$POD_NAME" ]; then
              POD_INFO=$(kubectl get pod $POD_NAME -n $NAMESPACE -o json 2>/dev/null || echo "{}")
              POD_LOGS=$(kubectl logs $POD_NAME -n $NAMESPACE --tail=100 2>/dev/null || echo "")
              POD_EVENTS=$(kubectl get events -n $NAMESPACE --field-selector involvedObject.name=$POD_NAME -o json 2>/dev/null || echo "{}")
            fi
            
            # Get deployment info if applicable
            OWNER=$(echo $POD_INFO | jq -r '.metadata.ownerReferences[0].name // ""')
            if [ -n "$OWNER" ]; then
              DEPLOYMENT_INFO=$(kubectl get deployment $OWNER -n $NAMESPACE -o json 2>/dev/null || echo "{}")
            fi
            
            # Get node info
            NODE_NAME=$(echo $POD_INFO | jq -r '.spec.nodeName // ""')
            if [ -n "$NODE_NAME" ]; then
              NODE_INFO=$(kubectl get node $NODE_NAME -o json 2>/dev/null || echo "{}")
            fi
            
            # Compile context
            cat << EOF > /tmp/context.json
            {
              "original_event": $EVENT,
              "pod_info": $POD_INFO,
              "pod_logs": "$(echo "$POD_LOGS" | base64)",
              "pod_events": $POD_EVENTS,
              "deployment_info": ${DEPLOYMENT_INFO:-{}},
              "node_info": ${NODE_INFO:-{}}
            }
            EOF
            
            cat /tmp/context.json
      outputs:
        parameters:
          - name: context
            valueFrom:
              path: /tmp/context.json

    - name: call-llm
      inputs:
        parameters:
          - name: context
      container:
        image: curlimages/curl:latest
        command: ["/bin/sh"]
        args:
          - -c
          - |
            CONTEXT='{{inputs.parameters.context}}'
            
            PROMPT="You are an AKS cluster auto-healer. Analyze the following Kubernetes event and context, then provide:
            
            1. ROOT_CAUSE: A brief explanation of the root cause
            2. SEVERITY: One of [low, medium, high, critical]
            3. ACTION: One of [auto-fix, approval-required, escalate, no-action]
            4. FIX_COMMAND: If auto-fix, the kubectl command to fix it (or 'none')
            5. REASONING: Why you chose this action
            
            Context:
            $CONTEXT
            
            Respond in JSON format only:
            {
              \"root_cause\": \"...\",
              \"severity\": \"...\",
              \"action\": \"...\",
              \"fix_command\": \"...\",
              \"reasoning\": \"...\"
            }"
            
            curl -s https://api.anthropic.com/v1/messages \
              -H "Content-Type: application/json" \
              -H "x-api-key: $ANTHROPIC_API_KEY" \
              -H "anthropic-version: 2023-06-01" \
              -d "{
                \"model\": \"claude-sonnet-4-20250514\",
                \"max_tokens\": 1024,
                \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}]
              }" | jq -r '.content[0].text' > /tmp/analysis.json
            
            cat /tmp/analysis.json
        env:
          - name: ANTHROPIC_API_KEY
            valueFrom:
              secretKeyRef:
                name: llm-credentials
                key: anthropic-api-key
      outputs:
        parameters:
          - name: analysis
            valueFrom:
              path: /tmp/analysis.json
          - name: fix-command
            valueFrom:
              path: /tmp/analysis.json
              jsonPath: '$.fix_command'

    - name: decision-gate
      inputs:
        parameters:
          - name: analysis
      script:
        image: python:3.11-slim
        command: [python]
        source: |
          import json
          
          analysis = json.loads('''{{inputs.parameters.analysis}}''')
          
          severity = analysis.get('severity', 'medium')
          action = analysis.get('action', 'escalate')
          
          # Override rules (safety rails)
          SAFE_COMMANDS = [
              'kubectl rollout restart',
              'kubectl scale',
              'kubectl delete pod',  # Only specific pods
          ]
          
          fix_cmd = analysis.get('fix_command', '')
          
          # If high severity, always require approval
          if severity in ['high', 'critical']:
              action = 'approval-required'
          
          # If fix command looks dangerous, escalate
          dangerous_patterns = ['delete deployment', 'delete namespace', 'delete pvc', '--all']
          if any(p in fix_cmd.lower() for p in dangerous_patterns):
              action = 'escalate'
          
          # If command not in safe list, require approval
          if action == 'auto-fix' and not any(safe in fix_cmd for safe in SAFE_COMMANDS):
              action = 'approval-required'
          
          print(action)
      outputs:
        parameters:
          - name: action
            valueFrom:
              path: /dev/stdout

    - name: execute-fix
      inputs:
        parameters:
          - name: fix-command
      container:
        image: bitnami/kubectl:latest
        command: ["/bin/bash"]
        args:
          - -c
          - |
            FIX_CMD='{{inputs.parameters.fix-command}}'
            
            echo "Executing fix: $FIX_CMD"
            
            # Execute the fix
            eval $FIX_CMD
            
            # Wait and verify
            sleep 10
            
            # Check if problem resolved (basic health check)
            kubectl get pods -A | grep -E "(CrashLoopBackOff|Error|ImagePullBackOff)" && exit 1 || exit 0

    - name: human-approval
      suspend: {}
      # This pauses the workflow until human approves via:
      # argo resume <workflow-name>

    - name: send-alert
      container:
        image: curlimages/curl:latest
        command: ["/bin/sh"]
        args:
          - -c
          - |
            # Send to Slack/Teams/PagerDuty
            curl -X POST "$SLACK_WEBHOOK_URL" \
              -H "Content-Type: application/json" \
              -d '{
                "text": "🚨 AKS Auto-Healer Escalation",
                "blocks": [
                  {
                    "type": "section",
                    "text": {
                      "type": "mrkdwn",
                      "text": "AI analysis requires human intervention"
                    }
                  }
                ]
              }'
        env:
          - name: SLACK_WEBHOOK_URL
            valueFrom:
              secretKeyRef:
                name: notification-secrets
                key: slack-webhook
```

### 4. Safe Auto-Fix Patterns

Define a library of safe, pre-approved remediation patterns:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: safe-remediation-patterns
  namespace: argo-events
data:
  patterns.yaml: |
    patterns:
      - name: restart-crashloop-pod
        trigger:
          reason: CrashLoopBackOff
          min_restarts: 5
        action:
          type: delete-pod
          command: "kubectl delete pod {pod_name} -n {namespace}"
        max_executions: 3
        cooldown: 300s
      
      - name: restart-deployment-oom
        trigger:
          reason: OOMKilled
          count_threshold: 3
        action:
          type: rollout-restart
          command: "kubectl rollout restart deployment/{deployment} -n {namespace}"
        max_executions: 2
        cooldown: 600s
      
      - name: scale-up-pending-pods
        trigger:
          reason: Insufficient resources
          pending_duration: 5m
        action:
          type: scale-nodepool
          # Requires readwrite access to AKS
          command: "az aks nodepool scale --resource-group {rg} --cluster-name {cluster} --name {nodepool} --node-count {current+1}"
        max_executions: 1
        cooldown: 1800s
        requires_approval: true
      
      - name: clear-imagepullbackoff
        trigger:
          reason: ImagePullBackOff
        action:
          type: delete-pod
          command: "kubectl delete pod {pod_name} -n {namespace}"
          # Often just needs a retry after image registry issue resolved
        max_executions: 2
        cooldown: 120s
```

### 5. Feedback Loop & Learning

Store outcomes for continuous improvement:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: record-outcome
spec:
  templates:
    - name: record
      inputs:
        parameters:
          - name: event-id
          - name: action-taken
          - name: outcome  # success, failed, rolled-back
          - name: ai-analysis
      container:
        image: curlimages/curl:latest
        command: ["/bin/sh"]
        args:
          - -c
          - |
            # Store in Azure Log Analytics or a database
            curl -X POST "$LOG_ANALYTICS_ENDPOINT" \
              -H "Content-Type: application/json" \
              -d '{
                "event_id": "{{inputs.parameters.event-id}}",
                "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
                "action": "{{inputs.parameters.action-taken}}",
                "outcome": "{{inputs.parameters.outcome}}",
                "ai_analysis": {{inputs.parameters.ai-analysis}}
              }'
```

## Implementation Phases

### Phase 1: Observe Only (Week 1-2)
- Deploy event collection
- Log all events and what AI would recommend
- No automatic actions
- Build confidence in AI analysis quality

### Phase 2: Low-Risk Auto-Fix (Week 3-4)
- Enable auto-fix for safe patterns only:
  - Pod restarts (CrashLoopBackOff after N restarts)
  - Deployment rollout restarts
- All other actions require approval

### Phase 3: Expanded Automation (Week 5-8)
- Add more patterns based on Phase 1-2 learnings
- Implement node-level actions (cordon, drain)
- Scale operations with approval gates

### Phase 4: Full Autonomy (Optional)
- AI-driven decisions with safety rails
- Human-in-the-loop for critical/destructive actions
- Continuous learning from outcomes

## Safety Rails

### Hard Limits (Never Auto-Fix)

```yaml
never_automate:
  - delete namespace
  - delete pvc (data loss)
  - delete statefulset
  - modify RBAC
  - modify network policies
  - scale to zero
  - delete more than 1 pod at a time
  - any action in kube-system
  - any action on control plane components
```

### Rate Limits

```yaml
rate_limits:
  global:
    max_actions_per_hour: 10
    max_actions_per_day: 50
  per_namespace:
    max_actions_per_hour: 3
  per_deployment:
    max_actions_per_hour: 2
    cooldown_after_action: 300s
```

### Approval Requirements

```yaml
require_approval_when:
  - severity >= high
  - action affects > 1 resource
  - action affects production namespace
  - action involves scaling
  - action involves node operations
  - confidence_score < 0.8
```

## Integration with Existing Stack

Given your GitOps-first approach with Argo and Kyverno:

### Kyverno Integration

Use Kyverno to validate AI-generated fixes before execution:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: validate-auto-healer-actions
spec:
  validationFailureAction: Enforce
  rules:
    - name: block-dangerous-deletions
      match:
        any:
          - resources:
              kinds:
                - Pod
              operations:
                - DELETE
              selector:
                matchLabels:
                  auto-healer-action: "true"
      validate:
        message: "Auto-healer cannot delete pods in protected namespaces"
        deny:
          conditions:
            any:
              - key: "{{request.namespace}}"
                operator: In
                value: ["kube-system", "argo-system", "istio-system"]
```

### Argo Events + Argo Workflows

Already covered above - this is the core of the architecture.

### Azure Service Operator

For cloud-level remediation (scaling nodepools, etc.):

```yaml
apiVersion: containerservice.azure.com/v1api20231001
kind: ManagedClustersAgentPool
metadata:
  name: userpool
  namespace: aks-operator
spec:
  owner:
    name: my-cluster
  count: 3  # AI could patch this for scaling
```

## Cost Considerations

| Component | Estimated Monthly Cost |
|-----------|----------------------|
| LLM API calls (1000 events/day) | ~$50-100 |
| Argo Workflows compute | Included in cluster |
| Log Analytics storage | ~$20-50 |
| Event Hub (Azure) | ~$10-20 |

## Monitoring the Auto-Healer

```yaml
# Prometheus metrics to expose
auto_healer_events_total{severity, namespace}
auto_healer_actions_total{action_type, outcome}
auto_healer_ai_latency_seconds
auto_healer_fix_success_rate
auto_healer_approvals_pending
```

## Getting Started

1. **Deploy Argo Events** (if not already)
   ```bash
   kubectl create namespace argo-events
   kubectl apply -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml
   ```

2. **Create LLM API Secret**
   ```bash
   kubectl create secret generic llm-credentials \
     --from-literal=anthropic-api-key=$ANTHROPIC_API_KEY \
     -n argo-events
   ```

3. **Deploy EventSources** (start with k8s-events only)

4. **Deploy Sensor in observe-only mode**

5. **Review AI recommendations for 1-2 weeks**

6. **Enable auto-fix for low-risk patterns**

## Resources

- [Argo Events Documentation](https://argoproj.github.io/argo-events/)
- [Argo Workflows Documentation](https://argoproj.github.io/argo-workflows/)
- [AKS-MCP Server](https://github.com/Azure/aks-mcp)
- [Kyverno Policies](https://kyverno.io/policies/)
- [Azure Service Operator](https://azure.github.io/azure-service-operator/)