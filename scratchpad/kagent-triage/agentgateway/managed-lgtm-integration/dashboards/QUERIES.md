# Curated PromQL / LogQL queries for managed LGTM

Copy/paste into Grafana Explore against the **managed Mimir** (PromQL) or
**managed Loki** (LogQL) datasource. Every query assumes the common labels
described in `../alloy-snippets/00-common-labels.alloy` are present.

---

## PromQL — Mimir

### Pipeline health

```promql
# Argo Events Kafka consumer lag per tier
kafka_consumergroup_lag{consumergroup=~"consumer-(critical|warnings|infra|alerts)"}

# Workflow success rate by template, last 1h
sum by (workflow_template) (
  rate(argo_workflows_count{status="Succeeded"}[1h])
)
/
clamp_min(
  sum by (workflow_template) (rate(argo_workflows_count[1h])),
  1
)

# Sensor pod restart count (catches CrashLoop on the sensor itself)
increase(kube_pod_container_status_restarts_total{namespace="argo-events"}[1h])
```

### agentgateway / KAgent

```promql
# Tokens per minute per model (input vs output split)
sum by (gen_ai_request_model, gen_ai_token_type) (
  rate(agentgateway_gen_ai_client_token_usage_sum[1m]) * 60
)

# Cost proxy — total tokens × $/1k tokens (annotate via Grafana value mapping)
sum by (gen_ai_request_model) (
  rate(agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type="input"}[5m]) * 60
)

# KAgent agent error rate per agent
sum by (agent) (rate(kagent_agent_requests_total{status="error"}[5m]))
/
clamp_min(sum by (agent) (rate(kagent_agent_requests_total[5m])), 1)

# Cross-cluster: who's calling agentgateway from outside the mgmt cluster?
sum by (cluster, namespace) (
  rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"openai.*"}[5m])
)
```

### K8s health (per cluster)

```promql
# Top 5 namespaces by container restarts in the last 1h
topk(5,
  sum by (namespace) (increase(kube_pod_container_status_restarts_total[1h]))
)

# Pods stuck in Pending > 10m
count by (cluster, namespace) (
  kube_pod_status_phase{phase="Pending"} == 1
  and on(pod, namespace) (time() - kube_pod_created > 600)
)

# OOMKilled count in last 1h
sum by (cluster, namespace) (
  increase(kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}[1h])
)
```

---

## LogQL — Loki

### Application errors

```logql
# All ERROR/FATAL lines from a specific service across all clusters
{cluster=~".+", namespace="my-app", service="api"}
  |~ "(?i)\\b(error|fatal|panic)\\b"

# Rate of error lines per service per cluster
sum by (cluster, namespace, service) (
  rate({cluster=~".+"} |~ "(?i)\\berror\\b" [5m])
)

# Top 10 most frequent error messages in the last 1h
topk(10,
  sum by (msg) (
    count_over_time(
      {cluster=~".+", namespace="my-app"}
        |~ "(?i)error"
        | regexp `(?P<msg>error[: ].{0,80})`
        [1h]
    )
  )
)
```

### K8s events (replaces direct event-watching)

```logql
# All Warning events cluster-wide
{job="kubernetes-events", event_type="Warning"}

# CrashLoopBackOff specifically
{job="kubernetes-events", event_reason="BackOff"}

# Rate of Warning events per namespace
sum by (cluster, namespace) (
  rate({job="kubernetes-events", event_type="Warning"} [5m])
)

# Pull failures (image issues)
{job="kubernetes-events", event_reason="Failed"} |~ "ImagePullBackOff|ErrImagePull"
```

### Pipeline self-observation

```logql
# Argo Workflows controller errors
{namespace="argo", app="workflow-controller"} |~ "ERROR|panic"

# Sensor logs (did our triage trigger?)
{namespace="argo-events", sensor_name=~".+triage.+"}

# KAgent A2A parse errors (workflow template bugs)
{namespace="kagent"} |~ "parse error|invalid.*JSON-RPC|missing.*kind"
```

### Security signals

```logql
# Auth failures across the fleet
sum by (cluster, namespace, service) (
  count_over_time(
    {cluster=~".+"}
      |~ "(?i)(401 unauthorized|403 forbidden|invalid token)"
      [10m]
  )
)

# Privileged container creation events
{job="kubernetes-events"} |~ "privileged.*true"
```

---

## Cross-signal patterns (Grafana derived fields)

In a Grafana panel showing a metric, configure the Loki datasource as a "data
link" with this LogQL using the panel's labels:

```
{cluster="${__field.labels.cluster}", namespace="${__field.labels.namespace}", pod="${__field.labels.pod}"}
```

Click any metric point → jump to the matching pod logs at the same time. This
is the single biggest UX win from putting all three signals into the managed
LGTM with consistent labels.
