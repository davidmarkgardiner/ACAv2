# Fluent Bit to Event Hub Authentication Options

## The Challenge

**Fluent Bit's Kafka output plugin does not support Azure AD Workload Identity** for Azure Event Hub authentication. The OAUTHBEARER mechanism in librdkafka requires a client secret, which conflicts with Workload Identity's federated token approach.

### Current State (Jan 2025)
- Fluent Bit Kafka plugin: Supports SASL/PLAIN (SAS tokens) and OAUTHBEARER (requires client secret)
- Azure Event Hub: Supports SAS tokens, Service Principal, Managed Identity
- Workload Identity: Uses federated OIDC tokens - no client secret

## Authentication Methods Comparison

| Method | Security | Rotation | Workload Identity | Fluent Bit Support |
|--------|----------|----------|-------------------|-------------------|
| SAS Tokens | Medium | Manual | No | Yes (SASL/PLAIN) |
| Service Principal + Secret | Medium | Manual | No | Yes (OAUTHBEARER) |
| UAMI + Federated Credentials | High | Automatic | Yes | **No** |

## Options

### Option 1: Azure Data Explorer (Kusto) Instead of Event Hub

**Fluent Bit has native Workload Identity support for Azure Data Explorer.**

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│ Fluent Bit  │────►│ Azure Data       │────►│ Argo Events │
│ (K8s Events)│     │ Explorer (Kusto) │     │ (Query ADX) │
└─────────────┘     └──────────────────┘     └─────────────┘
      │                                              │
      └──────── Workload Identity ─────────────────┘
```

**Pros:**
- Full Workload Identity support
- Rich query capabilities (KQL)
- Built-in retention and analytics

**Cons:**
- Additional Azure service cost
- Argo Events doesn't have native ADX EventSource
- Need custom polling mechanism

**Fluent Bit Config (Workload Identity):**
```ini
[OUTPUT]
    Name              azure_kusto
    Match             kube.events.*
    Tenant_Id         ${AZURE_TENANT_ID}
    Client_Id         ${AZURE_CLIENT_ID}
    Ingestion_Endpoint https://<cluster>.kusto.windows.net
    Database_Name     k8sevents
    Table_Name        Events
    # Workload Identity - uses projected token
    Auth_Type         workload_identity
    Token_Path        /var/run/secrets/azure/tokens/azure-identity-token
```

---

### Option 2: Azure Service Bus Instead of Event Hub

Azure Service Bus has better SDK support for Managed Identity.

```
┌─────────────┐     ┌─────────────────┐     ┌─────────────┐
│ Fluent Bit  │────►│ Azure Service   │────►│ Argo Events │
│ (via HTTP)  │     │ Bus Queue       │     │ EventSource │
└─────────────┘     └─────────────────┘     └─────────────┘
```

**Approach:** Use Fluent Bit HTTP output with a small Azure Function or container that:
1. Receives events via HTTP
2. Authenticates to Service Bus using Workload Identity
3. Forwards to Service Bus

**Pros:**
- Argo Events has native Azure Service Bus EventSource
- Service Bus supports Workload Identity

**Cons:**
- Requires intermediate component (Function/container)
- Additional complexity

---

### Option 3: Webhook Direct to Argo Events (Skip Message Queue)

Simplest approach - send events directly to Argo Events webhook.

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│ Fluent Bit  │────►│ Argo Events      │────►│ Workflow    │
│ (HTTP Out)  │     │ Webhook Source   │     │ Triggered   │
└─────────────┘     └──────────────────┘     └─────────────┘
```

**Fluent Bit Config:**
```ini
[OUTPUT]
    Name              http
    Match             kube.events.*
    Host              argo-events-webhook.argo-events.svc.cluster.local
    Port              12000
    URI               /k8s-events
    Format            json
    tls               Off
```

**Pros:**
- No external message queue needed
- No authentication complexity (internal cluster traffic)
- Simple architecture

**Cons:**
- No event persistence/replay
- Single cluster only (Fluent Bit must reach Argo Events)
- No buffering during Argo Events downtime

---

### Option 4: Azure Monitor Log Analytics

Use Azure Monitor's native log collection with Workload Identity.

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│ Container   │────►│ Azure Monitor    │────►│ Alert Rules │
│ Insights    │     │ Log Analytics    │     │ → Webhook   │
└─────────────┘     └──────────────────┘     └─────────────┘
                                                    │
                                                    ▼
                                             ┌─────────────┐
                                             │ Argo Events │
                                             │ Webhook     │
                                             └─────────────┘
```

**Pros:**
- Native AKS integration
- Full Workload Identity support
- Built-in alerting and queries

**Cons:**
- Latency (Azure Monitor processing time)
- Cost (Log Analytics ingestion)
- Requires Azure Alert Rules configuration

---

### Option 5: Fluentd Instead of Fluent Bit

Fluentd has more mature Azure plugins with better Managed Identity support.

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│ Fluentd     │────►│ Azure Event Hub  │────►│ Argo Events │
│ (azure-     │     │                  │     │ EventSource │
│ event-hubs) │     │                  │     │             │
└─────────────┘     └──────────────────┘     └─────────────┘
```

**Plugin:** `fluent-plugin-azure-event-hubs`

**Pros:**
- May have better Managed Identity support
- More Azure-specific plugins available

**Cons:**
- Higher resource usage than Fluent Bit
- Need to verify current Workload Identity support

---

### Option 6: Custom Token Exchange Sidecar

Use a sidecar container that handles Workload Identity token exchange for Fluent Bit.

```
┌─────────────────────────────────────────┐
│ Pod                                      │
│  ┌─────────────┐    ┌─────────────────┐ │
│  │ Fluent Bit  │───►│ Token Exchange  │ │
│  │ (Kafka Out) │    │ Sidecar         │ │
│  └─────────────┘    └────────┬────────┘ │
└──────────────────────────────│──────────┘
                               │ Workload Identity
                               ▼
                    ┌──────────────────┐
                    │ Azure Event Hub  │
                    └──────────────────┘
```

**Pros:**
- Keeps Event Hub architecture
- Full Workload Identity support

**Cons:**
- Complex implementation
- Custom code to maintain
- Token refresh handling

---

## Recommendation for Production

### For Single-Cluster Setup
**Option 3: Webhook Direct** is simplest and requires no external dependencies or authentication.

### For Multi-Cluster Setup (Current Requirement)
**Option 1: Azure Data Explorer** or **Option 4: Azure Monitor** are the most production-ready with full Workload Identity support.

### Hybrid Approach
If you need Event Hub specifically:
1. Use Workload Identity for Argo Events EventSource (receiver) - this works
2. For sender, evaluate:
   - Option 5 (Fluentd) if it supports Workload Identity
   - Option 6 (Custom sidecar) if you have dev capacity
   - Fall back to SAS if approved by security team with proper rotation

---

## Next Steps

1. [ ] Confirm which Azure services are approved at work
2. [ ] Check if SAS with automated rotation is acceptable
3. [ ] Evaluate Azure Data Explorer costs
4. [ ] Test Fluentd azure-event-hubs plugin for Workload Identity support
5. [ ] Consider Azure Monitor if latency is acceptable

---

## References

- [Fluent Bit Azure Data Explorer](https://docs.fluentbit.io/manual/data-pipeline/outputs/azure_kusto)
- [Fluent Bit Workload Identity Issue #7525](https://github.com/fluent/fluent-bit/issues/7525)
- [Argo Events Azure Event Hub](https://argoproj.github.io/argo-events/eventsources/setup/azure-events-hub/)
- [Azure Event Hub Kafka Authentication](https://docs.microsoft.com/en-us/azure/event-hubs/event-hubs-for-kafka-ecosystem-overview)
