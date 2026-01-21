# Grafana Alloy Integration Options

This document describes how to integrate Grafana Alloy Operator with the Holmes AI triage pipeline as an alternative to Fluent Bit + Event Hub.

## Architecture Overview

### Current Architecture (Fluent Bit + Event Hub)

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────┐    ┌─────────┐
│  Fluent Bit │───►│  Event Hub  │───►│ Argo Events │───►│ Holmes  │───►│ GitLab/ │
│  (DaemonSet)│    │   (Azure)   │    │  (Sensor)   │    │   AI    │    │Mattermost│
└─────────────┘    └─────────────┘    └─────────────┘    └─────────┘    └─────────┘
```

### Alloy Integration Options

```
Option 1: Alloy → Webhook (Direct)
Option 2: Alloy → Loki → Alertmanager → Webhook (Recommended)
Option 3: Alloy → Kafka → Argo Events (High Volume)
```

---

## Option 1: Alloy Direct to Webhook

Simple replacement - Alloy forwards K8s events directly to Argo Events webhook.

```
┌─────────────┐    ┌─────────────┐    ┌─────────┐    ┌─────────┐
│   Alloy     │───►│ Argo Events │───►│ Holmes  │───►│ GitLab/ │
│ (DaemonSet) │    │  (Webhook)  │    │   AI    │    │Mattermost│
└─────────────┘    └─────────────┘    └─────────┘    └─────────┘
```

### Alloy Operator CRD

```yaml
apiVersion: monitoring.grafana.com/v1alpha1
kind: Alloy
metadata:
  name: k8s-event-collector
  namespace: monitoring
spec:
  replicas: 1
  config: |
    // Discover Kubernetes events
    discovery.kubernetes "events" {
      role = "node"
    }

    // Collect Kubernetes events
    loki.source.kubernetes_events "cluster_events" {
      job_name   = "kubernetes-events"
      namespaces = []  // All namespaces
    }

    // Filter for Warning events only
    loki.process "filter_warnings" {
      forward_to = [loki.write.argo_webhook.receiver]

      stage.json {
        expressions = {
          type      = "type",
          reason    = "reason",
          message   = "message",
          namespace = "involvedObject.namespace",
          name      = "involvedObject.name",
          kind      = "involvedObject.kind",
        }
      }

      stage.match {
        selector = '{type="Warning"}'
        action   = "keep"
      }

      // Filter specific warning reasons
      stage.match {
        selector = '{reason=~"BackOff|OOMKilled|Failed|FailedScheduling|ImagePullBackOff"}'
        action   = "keep"
      }
    }

    // Forward to Argo Events webhook
    loki.write "argo_webhook" {
      endpoint {
        url = "http://webhook-eventsource.argo-events.svc:12000/k8s-event"

        // Batch settings
        batch_wait    = "5s"
        batch_size    = 10
      }
    }
```

### Argo Events Webhook EventSource

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: alloy-webhook
  namespace: argo-events
spec:
  webhook:
    k8s-event:
      port: "12000"
      endpoint: /k8s-event
      method: POST
```

### Pros/Cons

| Pros | Cons |
|------|------|
| Simple setup | No event persistence |
| Low latency | No deduplication |
| Minimal components | Limited filtering |

---

## Option 2: Alloy → Loki → Alertmanager (Recommended)

Full Grafana stack integration with rich alerting capabilities.

```
┌───────┐    ┌──────┐    ┌────────────┐    ┌──────────────┐    ┌─────────────┐
│ Alloy │───►│ Loki │───►│ Loki Ruler │───►│ Alertmanager │───►│ Argo Events │
└───────┘    └──────┘    │ (Alerting) │    │  (Webhook)   │    │  (Webhook)  │
                         └────────────┘    └──────────────┘    └─────────────┘
                                                                      │
                                                                      ▼
                                                               ┌─────────────┐
                                                               │Holmes → GitLab│
                                                               └─────────────┘
```

### Alloy Config (Forward to Loki)

```yaml
apiVersion: monitoring.grafana.com/v1alpha1
kind: Alloy
metadata:
  name: k8s-event-collector
  namespace: monitoring
spec:
  config: |
    // Collect Kubernetes events
    loki.source.kubernetes_events "cluster_events" {
      job_name   = "kubernetes-events"
      namespaces = []
    }

    // Add cluster label
    loki.process "add_labels" {
      forward_to = [loki.write.default.receiver]

      stage.static_labels {
        values = {
          cluster = env("CLUSTER_NAME"),
        }
      }
    }

    // Forward to Loki
    loki.write "default" {
      endpoint {
        url = "http://loki.monitoring.svc:3100/loki/api/v1/push"
      }
    }
```

### Loki Alerting Rules

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: k8s-event-alerts
  namespace: monitoring
spec:
  groups:
    - name: kubernetes-events
      rules:
        # OOMKilled Alert
        - alert: PodOOMKilled
          expr: |
            count by (namespace, name, cluster) (
              {job="kubernetes-events"}
              |= "OOMKilled"
              | json
              | type = "Warning"
            ) > 0
          for: 0m
          labels:
            severity: critical
            reason: OOMKilled
          annotations:
            summary: "Pod OOMKilled: {{ $labels.namespace }}/{{ $labels.name }}"
            description: "Pod {{ $labels.name }} in namespace {{ $labels.namespace }} was OOMKilled"
            cluster: "{{ $labels.cluster }}"

        # CrashLoopBackOff Alert
        - alert: PodCrashLoopBackOff
          expr: |
            count by (namespace, name, cluster) (
              {job="kubernetes-events"}
              |~ "BackOff|CrashLoop"
              | json
              | type = "Warning"
            ) > 2
          for: 5m
          labels:
            severity: critical
            reason: CrashLoopBackOff
          annotations:
            summary: "Pod CrashLoopBackOff: {{ $labels.namespace }}/{{ $labels.name }}"
            cluster: "{{ $labels.cluster }}"

        # ImagePullBackOff Alert
        - alert: ImagePullBackOff
          expr: |
            count by (namespace, name, cluster) (
              {job="kubernetes-events"}
              |~ "ImagePull|ErrImagePull"
              | json
              | type = "Warning"
            ) > 0
          for: 2m
          labels:
            severity: high
            reason: ImagePullBackOff
          annotations:
            summary: "Image pull failed: {{ $labels.namespace }}/{{ $labels.name }}"
            cluster: "{{ $labels.cluster }}"

        # FailedScheduling Alert
        - alert: PodFailedScheduling
          expr: |
            count by (namespace, name, cluster) (
              {job="kubernetes-events"}
              |= "FailedScheduling"
              | json
              | type = "Warning"
            ) > 0
          for: 5m
          labels:
            severity: high
            reason: FailedScheduling
          annotations:
            summary: "Pod scheduling failed: {{ $labels.namespace }}/{{ $labels.name }}"
            cluster: "{{ $labels.cluster }}"
```

### Alertmanager Config

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m

    route:
      group_by: ['alertname', 'cluster', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'argo-events-webhook'

      routes:
        # Critical alerts go immediately
        - match:
            severity: critical
          group_wait: 0s
          receiver: 'argo-events-webhook'

        # High severity with slight delay
        - match:
            severity: high
          group_wait: 2m
          receiver: 'argo-events-webhook'

    receivers:
      - name: 'argo-events-webhook'
        webhook_configs:
          - url: 'http://alertmanager-webhook.argo-events.svc:12000/alertmanager'
            send_resolved: false
            http_config:
              basic_auth:
                username: ''
                password: ''
```

### Argo Events for Alertmanager

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: alertmanager-webhook
  namespace: argo-events
spec:
  webhook:
    alertmanager:
      port: "12000"
      endpoint: /alertmanager
      method: POST
---
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: alertmanager-sensor
  namespace: argo-events
spec:
  eventBusName: default
  template:
    serviceAccountName: argo-events-sa

  dependencies:
    - name: alertmanager-event
      eventSourceName: alertmanager-webhook
      eventName: alertmanager

  triggers:
    - template:
        name: holmes-triage
        conditions: "alertmanager-event"
        argoWorkflow:
          operation: submit
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: alertmanager-triage-
              spec:
                workflowTemplateRef:
                  name: multi-cluster-triage
                serviceAccountName: argo-events-sa
                arguments:
                  parameters:
                    - name: cluster-name
                      value: ""
                    - name: namespace
                      value: ""
                    - name: resource-name
                      value: ""
                    - name: resource-kind
                      value: "Pod"
                    - name: event-reason
                      value: ""
                    - name: event-message
                      value: ""
                    - name: gitlab-project
                      value: "your-org/your-repo"
                    - name: holmes-url
                      value: "http://holmesgpt.holmesgpt.svc:80"
          parameters:
            # Map Alertmanager payload to workflow parameters
            - src:
                dependencyName: alertmanager-event
                dataKey: body.commonLabels.cluster
              dest: spec.arguments.parameters.0.value
            - src:
                dependencyName: alertmanager-event
                dataKey: body.commonLabels.namespace
              dest: spec.arguments.parameters.1.value
            - src:
                dependencyName: alertmanager-event
                dataKey: body.commonLabels.name
              dest: spec.arguments.parameters.2.value
            - src:
                dependencyName: alertmanager-event
                dataKey: body.commonLabels.reason
              dest: spec.arguments.parameters.4.value
            - src:
                dependencyName: alertmanager-event
                dataKey: body.commonAnnotations.description
              dest: spec.arguments.parameters.5.value
```

### Pros/Cons

| Pros | Cons |
|------|------|
| Rich LogQL filtering | More components |
| Event deduplication | Higher complexity |
| Alerting rules | Requires Loki stack |
| Grafana dashboards | Learning curve |
| Silencing/Inhibition | |

---

## Option 3: Alloy → Kafka → Argo Events

High-volume, multi-consumer architecture.

```
┌───────┐    ┌───────┐    ┌─────────────────┐    ┌─────────────┐
│ Alloy │───►│ Kafka │───►│ Argo Events     │───►│Holmes/GitLab│
└───────┘    └───────┘    │ (Kafka Source)  │    └─────────────┘
                │         └─────────────────┘
                │
                └────────►│ Other Consumers │ (Splunk, DataDog, etc.)
```

### Alloy Config (Kafka Output)

```yaml
apiVersion: monitoring.grafana.com/v1alpha1
kind: Alloy
metadata:
  name: k8s-event-collector
  namespace: monitoring
spec:
  config: |
    // Collect Kubernetes events
    loki.source.kubernetes_events "cluster_events" {
      job_name = "kubernetes-events"
    }

    // Filter warnings
    loki.process "filter" {
      forward_to = [otelcol.exporter.kafka.default.input]

      stage.match {
        selector = '{type="Warning"}'
        action   = "keep"
      }
    }

    // Export to Kafka
    otelcol.exporter.kafka "default" {
      protocol_version = "2.0.0"
      brokers          = ["kafka.kafka.svc:9092"]
      topic            = "k8s-warning-events"
      encoding         = "json"
    }
```

### Argo Events Kafka EventSource

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: kafka-events
  namespace: argo-events
spec:
  kafka:
    k8s-events:
      url: kafka.kafka.svc:9092
      topic: k8s-warning-events
      consumerGroup:
        groupName: argo-events-consumer
      jsonBody: true
      partition: "0"
```

### Pros/Cons

| Pros | Cons |
|------|------|
| High throughput | Kafka overhead |
| Multiple consumers | More infrastructure |
| Event replay | Complexity |
| Durability | Cost |

---

## Comparison Matrix

| Feature | Option 1 (Direct) | Option 2 (Loki) | Option 3 (Kafka) |
|---------|-------------------|-----------------|------------------|
| Complexity | Low | Medium | High |
| Latency | Low | Medium | Low |
| Filtering | Basic | Advanced (LogQL) | Basic |
| Deduplication | No | Yes | Manual |
| Persistence | No | Yes (Loki) | Yes (Kafka) |
| Multi-consumer | No | Yes | Yes |
| Dashboards | No | Yes (Grafana) | Manual |
| Cost | Low | Medium | High |

---

## Recommendation

**For most use cases: Option 2 (Alloy → Loki → Alertmanager)**

- Rich filtering with LogQL
- Built-in deduplication and grouping
- Grafana dashboards for visibility
- Alertmanager handles notification routing
- Scales well with existing Grafana stack

**For simple setups: Option 1 (Direct Webhook)**

- Minimal components
- Quick to implement
- Good for single-cluster, low-volume

**For enterprise/multi-cluster: Option 3 (Kafka)**

- High availability
- Multiple downstream consumers
- Event replay capability

---

## Migration Path

### From Fluent Bit + Event Hub to Alloy

1. Deploy Alloy Operator
2. Create Alloy CRD with K8s event collection
3. Configure output (webhook/Loki/Kafka)
4. Test with parallel deployment
5. Disable Fluent Bit after validation
6. Remove Event Hub dependency

### Parallel Running (Testing)

```yaml
# Alloy can run alongside Fluent Bit during migration
# Both send to different endpoints for comparison
loki.write "test_webhook" {
  endpoint {
    url = "http://test-webhook.argo-events.svc:12001/k8s-event"  # Different port
  }
}
```

---

## Next Steps

1. Choose integration option based on requirements
2. Deploy Alloy Operator if not present
3. Configure Alloy for K8s event collection
4. Update Argo Events EventSource/Sensor
5. Test end-to-end pipeline
6. Migrate from Fluent Bit + Event Hub
