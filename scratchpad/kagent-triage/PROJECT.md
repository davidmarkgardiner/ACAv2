# kagent Triage Integration

## Goal
Wire kagent AI agents into the existing Argo Events triage pipeline on the Kind cluster.
Events from K8s namespaces route to namespace-specific kagent agents for diagnosis and remediation.

## Architecture
```
K8s Warning Event (any namespace)
  → Argo EventSource (k8s-warning-events, already running)
  → New Sensor (kagent-triage-sensor)
  → Router WorkflowTemplate
    ├─ test-ns events → test-agent (kagent)
    ├─ cert-manager events → cert-manager-agent (kagent)
    └─ <namespace> events → <namespace>-agent (kagent)
```

## Existing Infrastructure (Kind cluster, context: kind-homelab)
- Argo Workflows: Running (argo namespace)
- Argo Events: Running (argo-events namespace)
- EventBus: NATS 3-replica (argo-events namespace)
- EventSource: k8s-warning-events (watching all namespaces)
- kagent: Running (kagent namespace, v0.8.0-beta4)
- kagent agents: helm-agent, k8s-agent, kgateway-agent
- LiteLLM proxy: routing to Kimi API
- ModelConfig: kimi-for-coding via LiteLLM

## Phase 1: Test Namespace (THIS SPRINT)
1. Create test-agent in kagent (namespace-aware system prompt for test-ns)
2. Create Argo WorkflowTemplate that invokes kagent agent via API
3. Create Sensor that routes test-ns events to the workflow
4. Create IngressRoute to expose kagent UI at kagent.xxx
5. Test: inject error in test-ns → verify agent diagnoses it
6. Document all YAML for lift-and-shift to work

## Phase 2: Cert-Manager Namespace (NEXT)
1. Create cert-manager-agent with cert-manager domain knowledge
2. Route cert-manager events to cert-manager-agent
3. Test: inject cert expiry / issuer errors

## Key Design Decisions
- kagent agents are invoked via REST API (controller at port 8083)
- Argo Workflow calls kagent API to create conversation + send message
- Agent response can be posted to Telegram or stored
- Each namespace gets its own kagent Agent CR with specialised system prompt
- All YAML portable to AKS (swap EventSource for Event Hub consumer)

## API Reference
- List agents: GET http://kagent-controller.kagent:8083/api/agents
- Create conversation: POST http://kagent-controller.kagent:8083/api/chat
- Agent invoke expects: agent_id, message, conversation_id

## Files
- 00-test-namespace.yaml       - Test namespace + RBAC
- 01-test-agent.yaml           - kagent Agent CR for test-ns
- 02-workflow-kagent-triage.yaml - Argo WorkflowTemplate
- 03-sensor-kagent-triage.yaml  - Argo Sensor routing events
- 04-ingress-kagent-ui.yaml    - Traefik IngressRoute
- 05-test-error-injection.yaml - Test pods with errors
- README.md                     - Documentation for lift-and-shift
