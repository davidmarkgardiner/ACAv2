# Noise Mitigation Strategy for Kubernetes Event Pipeline

This document outlines comprehensive strategies for reducing noise and preventing duplicate workflow triggers in the Fluent Bit → Event Hub → Argo Events pipeline.

## Table of Contents

- [Overview](#overview)
- [The Problem](#the-problem)
- [Mitigation Layers](#mitigation-layers)
- [Layer 1: Fluent Bit (Source Filtering)](#layer-1-fluent-bit-source-filtering)
- [Layer 2: Argo Events Sensor (Destination Filtering)](#layer-2-argo-events-sensor-destination-filtering)
- [Layer 3: Workflow-Level Controls](#layer-3-workflow-level-controls)
- [Layer 4: External State Management](#layer-4-external-state-management)
- [Phased Rollout Plan](#phased-rollout-plan)
- [Monitoring and Observability](#monitoring-and-observability)
- [Quick Reference](#quick-reference)

---

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          NOISE MITIGATION LAYERS                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
│  │   LAYER 1   │    │   LAYER 2   │    │   LAYER 3   │    │   LAYER 4   │  │
│  │             │    │             │    │             │    │             │  │
│  │ Fluent Bit  │───►│ Argo Sensor │───►│  Workflow   │───►│  External   │  │
│  │  Filtering  │    │  Filtering  │    │  Controls   │    │   State     │  │
│  │             │    │             │    │             │    │             │  │
│  │ • Severity  │    │ • Filters   │    │ • Mutex     │    │ • Redis     │  │
│  │ • Namespace │    │ • Transform │    │ • Semaphore │    │ • ConfigMap │  │
│  │ • Reason    │    │ • Condition │    │ • TTL       │    │ • Database  │  │
│  │ • Lua dedup │    │ • Rate limit│    │             │    │             │  │
│  └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘  │
│                                                                             │
│       SOURCE                              DESTINATION                       │
│    (AKS Clusters)                    (Management Cluster)                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## The Problem

### Current Behavior
1. **Every Kubernetes event triggers a workflow** - No deduplication
2. **Rapid-fire events** - A single pod crash can generate 10+ events in seconds
3. **Duplicate processing** - Same issue triggers multiple investigations
4. **Resource exhaustion** - Too many concurrent workflows overwhelm the cluster
5. **Alert fatigue** - Teams ignore notifications when flooded

### Example: Single Pod CrashLoopBackOff
```
Event 1: BackOff        (0s)   → Workflow 1 triggered
Event 2: Failed         (1s)   → Workflow 2 triggered
Event 3: BackOff        (10s)  → Workflow 3 triggered
Event 4: BackOff        (30s)  → Workflow 4 triggered
Event 5: BackOff        (60s)  → Workflow 5 triggered
...
```

**Result:** 5+ workflows for the same issue, all doing redundant work.

---

## Mitigation Layers

| Layer | Location | Purpose | Implementation Effort |
|-------|----------|---------|----------------------|
| 1 | Fluent Bit | Filter at source, reduce volume | Low |
| 2 | Argo Sensor | Filter on receive, smart conditions | Medium |
| 3 | Workflow | Prevent concurrent duplicates | Low |
| 4 | External State | Cross-workflow deduplication | High |

**Recommendation:** Implement Layers 1-3 first. Layer 4 only if needed.

---

## Layer 1: Fluent Bit (Source Filtering)

Filter events at the source before they reach Event Hub. This is the most efficient approach as it reduces network traffic and Event Hub costs.

### 1.1 Severity-Based Filtering

**Current (captures too much):**
```ini
[FILTER]
    Name          grep
    Match         kube.events.*
    Regex         type Warning
```

**Recommended Phase 1 - Critical Errors Only:**
```ini
# Only capture critical/error events by reason
[FILTER]
    Name          grep
    Match         kube.events.*
    Regex         reason ^(CrashLoopBackOff|OOMKilled|NodeNotReady|FailedMount|FailedScheduling|Evicted)$
```

**Phase 2 - Add Health-Related:**
```ini
[FILTER]
    Name          grep
    Match         kube.events.*
    Regex         reason ^(CrashLoopBackOff|OOMKilled|NodeNotReady|FailedMount|FailedScheduling|Evicted|Unhealthy|FailedKillPod|NetworkNotReady)$
```

### 1.2 Namespace Exclusion

Exclude noisy system namespaces:

```ini
# Exclude system namespaces
[FILTER]
    Name          grep
    Match         kube.events.*
    Exclude       involvedObject.namespace ^(kube-system|kube-public|kube-node-lease|gatekeeper-system|cert-manager|external-secrets|flux-system)$
```

**Whitelist approach (more restrictive):**
```ini
# Only include specific namespaces
[FILTER]
    Name          grep
    Match         kube.events.*
    Regex         involvedObject.namespace ^(production|staging|app-.*)$
```

### 1.3 Lua-Based Deduplication

Create a Lua script for time-window deduplication at the source:

**Script: `/fluent-bit/scripts/dedupe.lua`**
```lua
-- Deduplication cache
local cache = {}
local DEDUPE_WINDOW_SECONDS = 300  -- 5 minutes

function dedupe_event(tag, timestamp, record)
    -- Create unique key from event signature
    local key = string.format("%s/%s/%s/%s",
        record["involvedObject.namespace"] or "unknown",
        record["involvedObject.name"] or "unknown",
        record["involvedObject.kind"] or "unknown",
        record["reason"] or "unknown"
    )

    local now = os.time()

    -- Check if we've seen this event recently
    if cache[key] then
        local last_seen = cache[key]
        if (now - last_seen) < DEDUPE_WINDOW_SECONDS then
            -- Duplicate within window, drop it
            return -1, 0, 0  -- -1 means drop the record
        end
    end

    -- New event or outside window, allow it
    cache[key] = now

    -- Add dedupe metadata
    record["_dedupe_key"] = key
    record["_dedupe_window"] = DEDUPE_WINDOW_SECONDS

    -- Cleanup old cache entries periodically
    if math.random(1, 100) == 1 then
        for k, v in pairs(cache) do
            if (now - v) > DEDUPE_WINDOW_SECONDS * 2 then
                cache[k] = nil
            end
        end
    end

    return 1, timestamp, record  -- 1 means keep the record
end
```

**ConfigMap update:**
```yaml
data:
  filters.conf: |
    # Severity filter first
    [FILTER]
        Name          grep
        Match         kube.events.*
        Regex         reason ^(CrashLoopBackOff|OOMKilled|NodeNotReady|FailedMount)$

    # Namespace exclusion
    [FILTER]
        Name          grep
        Match         kube.events.*
        Exclude       involvedObject.namespace ^(kube-system|kube-public)$

    # Lua deduplication (5-minute window)
    [FILTER]
        Name          lua
        Match         kube.events.*
        script        /fluent-bit/scripts/dedupe.lua
        call          dedupe_event

    # Add cluster identifier
    [FILTER]
        Name          modify
        Match         kube.events.*
        Add           cluster ${CLUSTER_NAME}

  dedupe.lua: |
    -- [Lua script content from above]
```

### 1.4 Rate Limiting with Throttle Filter

Limit events per time window:

```ini
# Throttle: max 10 events per 60 seconds per unique key
[FILTER]
    Name          throttle
    Match         kube.events.*
    Rate          10
    Window        60
    Interval      60
    Print_Status  true
```

### 1.5 Event Severity Reference

| Reason | Severity | Action | Include Phase |
|--------|----------|--------|---------------|
| `CrashLoopBackOff` | Critical | Immediate | 1 |
| `OOMKilled` | Critical | Immediate | 1 |
| `NodeNotReady` | Critical | Immediate | 1 |
| `FailedMount` | Critical | Immediate | 1 |
| `FailedScheduling` | High | Investigate | 2 |
| `Evicted` | High | Investigate | 2 |
| `Unhealthy` | Medium | Monitor | 2 |
| `FailedKillPod` | Medium | Monitor | 2 |
| `BackOff` | Low | Aggregate | 3 |
| `Pulling` | Info | Ignore | Never |
| `Pulled` | Info | Ignore | Never |
| `Created` | Info | Ignore | Never |
| `Started` | Info | Ignore | Never |
| `Scheduled` | Info | Ignore | Never |

---

## Layer 2: Argo Events Sensor (Destination Filtering)

Filter and deduplicate events when received by the Argo Events Sensor on the management cluster.

### 2.1 Sensor Dependency Filters

Use Argo Events' built-in filtering on the sensor dependency:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: fluent-bit-filtered
  namespace: argo-events
spec:
  dependencies:
    - name: critical-errors
      eventSourceName: eventhub-k8s-events
      eventName: k8s-warnings
      filters:
        # Time filter - only events from last 5 minutes
        time:
          start: "-5m"
          stop: ""

        # Data filters - applied to decoded event body
        dataLogicalOperator: "and"
        data:
          # Filter by reason (critical only)
          - path: "reason"
            type: "string"
            comparator: "="
            value:
              - "CrashLoopBackOff"
              - "OOMKilled"
              - "NodeNotReady"
              - "FailedMount"
              - "FailedScheduling"

          # Exclude system namespaces
          - path: "involvedObject.namespace"
            type: "string"
            comparator: "!="
            value:
              - "kube-system"
              - "kube-public"
              - "gatekeeper-system"
```

### 2.2 Data Filter with Base64 Decoding

Since Event Hub wraps the payload in Base64, use `dataTemplate` for filtering:

```yaml
dependencies:
  - name: critical-errors
    eventSourceName: eventhub-k8s-events
    eventName: k8s-warnings
    filters:
      # Use expression filter for complex logic on decoded data
      exprs:
        - expr: 'reason in ["CrashLoopBackOff", "OOMKilled", "NodeNotReady"]'
          fields:
            - name: reason
              path: body
              # Decode base64 and extract reason field
              template: '{{ (b64dec .Input.body) | mustFromJson | dig "reason" "" }}'
```

### 2.3 Expression-Based Filtering (Advanced)

Complex filtering using CEL or Lua expressions:

```yaml
dependencies:
  - name: filtered-events
    eventSourceName: eventhub-k8s-events
    eventName: k8s-warnings
    filters:
      exprs:
        # Only critical reasons
        - expr: 'reason =~ "CrashLoopBackOff|OOMKilled|NodeNotReady"'
          fields:
            - name: reason
              path: body
              template: '{{ (b64dec .Input.body) | mustFromJson | dig "reason" "" }}'

        # Exclude test namespaces
        - expr: '!(namespace =~ "test-.*|dev-.*")'
          fields:
            - name: namespace
              path: body
              template: '{{ (b64dec .Input.body) | mustFromJson | dig "involvedObject" "namespace" "" }}'

        # Only if event is less than 5 minutes old
        - expr: 'eventAge < 300'
          fields:
            - name: eventAge
              path: body
              template: '{{ (b64dec .Input.body) | mustFromJson | dig "eventAge" "0" }}'
```

### 2.4 Transform for Deduplication Key

Add a transformation to create a deduplication key that workflows can use:

```yaml
triggers:
  - template:
      name: process-event
      argoWorkflow:
        operation: submit
        parameters:
          # Create dedupe key from event signature
          - src:
              dependencyName: critical-errors
              dataTemplate: |
                {{- $decoded := (b64dec .Input.body) | mustFromJson -}}
                {{- $ns := dig "involvedObject" "namespace" "unknown" $decoded -}}
                {{- $name := dig "involvedObject" "name" "unknown" $decoded -}}
                {{- $kind := dig "involvedObject" "kind" "unknown" $decoded -}}
                {{- $reason := dig "reason" "unknown" $decoded -}}
                {{ printf "%s/%s/%s/%s" $ns $name $kind $reason }}
            dest: spec.arguments.parameters.0.value
            # Parameter name: dedupe-key
```

### 2.5 Conditional Trigger Based on Event Age

Only trigger for recent events:

```yaml
triggers:
  - template:
      name: recent-events-only
      conditions: "critical-errors"
      conditionsReset:
        # Reset conditions every 5 minutes
        - byTime:
            cron: "*/5 * * * *"
            timezone: "UTC"
```

### 2.6 Rate Limiting at Sensor Level

Limit how often a trigger can fire:

```yaml
triggers:
  - template:
      name: rate-limited-trigger
      rateLimit:
        # Max 10 triggers per 5 minutes
        requestsPerUnit: 10
        unit: "Minute"
        # Or use duration
        # duration: "5m"
```

**Note:** As of Argo Events v1.8+, rate limiting is supported natively.

### 2.7 Complete Filtered Sensor Example

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: fluent-bit-filtered-production
  namespace: argo-events
  labels:
    app: k8s-event-consumer
    filtering: enabled
spec:
  eventBusName: default
  template:
    serviceAccountName: argo-events-sa

  dependencies:
    - name: critical-errors
      eventSourceName: eventhub-k8s-events
      eventName: k8s-warnings
      filters:
        # Expression-based filtering
        exprs:
          # Only critical event reasons
          - expr: 'reason in ["CrashLoopBackOff", "OOMKilled", "NodeNotReady", "FailedMount", "FailedScheduling"]'
            fields:
              - name: reason
                path: body
                template: '{{ (b64dec .Input.body) | mustFromJson | dig "reason" "" }}'

          # Exclude system namespaces
          - expr: '!(namespace in ["kube-system", "kube-public", "gatekeeper-system", "cert-manager"])'
            fields:
              - name: namespace
                path: body
                template: '{{ (b64dec .Input.body) | mustFromJson | dig "involvedObject" "namespace" "" }}'

  triggers:
    - template:
        name: create-investigation
        conditions: "critical-errors"
        argoWorkflow:
          operation: submit
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: investigate-
                labels:
                  app: k8s-event-handler
                  filtering: enabled
              spec:
                workflowTemplateRef:
                  name: multi-cluster-triage
                serviceAccountName: argo-events-sa
                # Synchronization prevents duplicate workflows
                synchronization:
                  mutex:
                    name: "event-{{ workflow.parameters.dedupe-key }}"
                arguments:
                  parameters:
                    - name: dedupe-key
                      value: ""
                    - name: cluster-name
                      value: ""
                    - name: namespace
                      value: ""
                    - name: resource-name
                      value: ""
                    - name: resource-kind
                      value: ""
                    - name: event-reason
                      value: ""
                    - name: event-message
                      value: ""
          parameters:
            # Dedupe key for mutex
            - src:
                dependencyName: critical-errors
                dataTemplate: |
                  {{- $d := (b64dec .Input.body) | mustFromJson -}}
                  {{ printf "%s-%s-%s-%s" (dig "involvedObject" "namespace" "x" $d) (dig "involvedObject" "name" "x" $d) (dig "involvedObject" "kind" "x" $d) (dig "reason" "x" $d) }}
              dest: spec.arguments.parameters.0.value
            # Other parameters...
            - src:
                dependencyName: critical-errors
                dataTemplate: '{{ (b64dec .Input.body) | mustFromJson | dig "cluster" "unknown" }}'
              dest: spec.arguments.parameters.1.value
            - src:
                dependencyName: critical-errors
                dataTemplate: '{{ (b64dec .Input.body) | mustFromJson | dig "involvedObject" "namespace" "default" }}'
              dest: spec.arguments.parameters.2.value
            - src:
                dependencyName: critical-errors
                dataTemplate: '{{ (b64dec .Input.body) | mustFromJson | dig "involvedObject" "name" "unknown" }}'
              dest: spec.arguments.parameters.3.value
            - src:
                dependencyName: critical-errors
                dataTemplate: '{{ (b64dec .Input.body) | mustFromJson | dig "involvedObject" "kind" "Pod" }}'
              dest: spec.arguments.parameters.4.value
            - src:
                dependencyName: critical-errors
                dataTemplate: '{{ (b64dec .Input.body) | mustFromJson | dig "reason" "Unknown" }}'
              dest: spec.arguments.parameters.5.value
            - src:
                dependencyName: critical-errors
                dataTemplate: '{{ (b64dec .Input.body) | mustFromJson | dig "message" "" }}'
              dest: spec.arguments.parameters.6.value
      retryStrategy:
        steps: 3
        duration: 30s
```

---

## Layer 3: Workflow-Level Controls

Prevent duplicate workflows from running concurrently using Argo Workflows synchronization features.

### 3.1 Mutex (Single Workflow Per Resource)

Only one workflow can run at a time for a given resource:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: multi-cluster-triage
spec:
  arguments:
    parameters:
      - name: dedupe-key
      - name: namespace
      - name: resource-name
      - name: resource-kind
      - name: event-reason

  # MUTEX: Only one workflow per unique resource
  synchronization:
    mutex:
      name: "triage-{{workflow.parameters.namespace}}-{{workflow.parameters.resource-name}}"

  entrypoint: investigate
  templates:
    - name: investigate
      # ... workflow steps
```

### 3.2 Semaphore (Limit Concurrent Workflows)

Limit total number of concurrent investigation workflows:

```yaml
# First, create a ConfigMap for semaphore configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: workflow-semaphores
  namespace: argo
data:
  investigation: "5"  # Max 5 concurrent investigations
  notification: "10"  # Max 10 concurrent notifications

---
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: multi-cluster-triage
spec:
  synchronization:
    semaphore:
      configMapKeyRef:
        name: workflow-semaphores
        key: investigation
  # ... rest of workflow
```

### 3.3 TTL Strategy (Auto-Cleanup)

Automatically clean up completed workflows:

```yaml
spec:
  ttlStrategy:
    secondsAfterCompletion: 3600   # Delete 1 hour after completion
    secondsAfterSuccess: 1800      # Delete 30 min after success
    secondsAfterFailure: 86400     # Keep failures for 24 hours
```

### 3.4 Active Deadline (Prevent Stuck Workflows)

Set maximum runtime to prevent zombie workflows:

```yaml
spec:
  activeDeadlineSeconds: 1800  # 30 minute max runtime
```

### 3.5 Pod Disruption Budget Awareness

Ensure workflows don't overwhelm the cluster:

```yaml
spec:
  podPriorityClassName: low-priority  # Lower priority than production workloads
  parallelism: 3                       # Max 3 parallel pods per workflow
```

### 3.6 Complete Workflow Template with All Controls

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: multi-cluster-triage-safe
  namespace: argo
spec:
  arguments:
    parameters:
      - name: dedupe-key
        description: "Unique key for deduplication"
      - name: cluster-name
      - name: namespace
      - name: resource-name
      - name: resource-kind
      - name: event-reason
      - name: event-message

  # === SYNCHRONIZATION ===
  synchronization:
    # Mutex: One workflow per resource at a time
    mutex:
      name: "triage-{{workflow.parameters.dedupe-key}}"
    # Semaphore: Max 5 total investigations
    # semaphore:
    #   configMapKeyRef:
    #     name: workflow-semaphores
    #     key: investigation

  # === TIMEOUTS ===
  activeDeadlineSeconds: 1800  # 30 min max

  # === CLEANUP ===
  ttlStrategy:
    secondsAfterCompletion: 3600
    secondsAfterSuccess: 1800
    secondsAfterFailure: 86400

  # === RESOURCE CONTROLS ===
  podPriorityClassName: low-priority
  parallelism: 2

  # === RETRY POLICY ===
  retryStrategy:
    limit: 2
    retryPolicy: "OnError"
    backoff:
      duration: "30s"
      factor: 2
      maxDuration: "5m"

  serviceAccountName: argo-events-sa
  entrypoint: main

  templates:
    - name: main
      dag:
        tasks:
          - name: check-not-duplicate
            template: check-recent-workflows
            arguments:
              parameters:
                - name: dedupe-key
                  value: "{{workflow.parameters.dedupe-key}}"

          - name: investigate
            template: run-investigation
            dependencies: [check-not-duplicate]
            when: "{{tasks.check-not-duplicate.outputs.result}} == proceed"

    - name: check-recent-workflows
      inputs:
        parameters:
          - name: dedupe-key
      script:
        image: bitnami/kubectl:latest
        command: [bash]
        source: |
          #!/bin/bash
          DEDUPE_KEY="{{inputs.parameters.dedupe-key}}"

          # Check for workflows with same dedupe-key in last 30 minutes
          RECENT=$(kubectl get workflows -n argo \
            -l dedupe-key="${DEDUPE_KEY}" \
            --field-selector=status.phase=Running \
            -o name 2>/dev/null | wc -l)

          if [ "$RECENT" -gt 1 ]; then
            echo "skip"  # Another workflow is handling this
          else
            echo "proceed"
          fi

    - name: run-investigation
      # ... actual investigation steps
      container:
        image: your-investigation-image
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Investigating {{workflow.parameters.event-reason}} in {{workflow.parameters.namespace}}"
            # ... investigation logic
```

---

## Layer 4: External State Management

For advanced deduplication across workflow restarts and cluster boundaries.

### 4.1 Redis-Based Deduplication

Use Redis to track processed events:

```yaml
- name: check-redis-dedupe
  inputs:
    parameters:
      - name: dedupe-key
      - name: ttl-seconds
        default: "1800"  # 30 minutes
  script:
    image: redis:7-alpine
    command: [sh]
    source: |
      #!/bin/sh
      DEDUPE_KEY="{{inputs.parameters.dedupe-key}}"
      TTL="{{inputs.parameters.ttl-seconds}}"
      REDIS_HOST="${REDIS_HOST:-redis.argo.svc.cluster.local}"

      # Try to set key with NX (only if not exists)
      RESULT=$(redis-cli -h $REDIS_HOST SET "dedupe:$DEDUPE_KEY" "1" NX EX $TTL)

      if [ "$RESULT" = "OK" ]; then
        echo "proceed"  # First time seeing this event
      else
        echo "skip"     # Already processed
      fi
    env:
      - name: REDIS_HOST
        value: "redis.argo.svc.cluster.local"
```

### 4.2 ConfigMap-Based State (Simpler)

Use a ConfigMap to track recent events:

```yaml
- name: check-configmap-dedupe
  inputs:
    parameters:
      - name: dedupe-key
  script:
    image: bitnami/kubectl:latest
    command: [bash]
    source: |
      #!/bin/bash
      DEDUPE_KEY="{{inputs.parameters.dedupe-key}}"
      CM_NAME="event-dedupe-state"
      NAMESPACE="argo"
      TTL_MINUTES=30

      # Get current timestamp
      NOW=$(date +%s)
      CUTOFF=$((NOW - TTL_MINUTES * 60))

      # Check if event was processed recently
      LAST_SEEN=$(kubectl get cm $CM_NAME -n $NAMESPACE \
        -o jsonpath="{.data['${DEDUPE_KEY//\//-}']}" 2>/dev/null || echo "0")

      if [ "$LAST_SEEN" -gt "$CUTOFF" ]; then
        echo "skip"
        exit 0
      fi

      # Mark as processed
      kubectl patch cm $CM_NAME -n $NAMESPACE --type=merge \
        -p "{\"data\":{\"${DEDUPE_KEY//\//-}\":\"$NOW\"}}" 2>/dev/null || \
      kubectl create cm $CM_NAME -n $NAMESPACE \
        --from-literal="${DEDUPE_KEY//\//-}=$NOW"

      echo "proceed"
```

### 4.3 Database-Backed Deduplication

For high-volume environments:

```sql
-- PostgreSQL schema for event deduplication
CREATE TABLE IF NOT EXISTS event_dedupe (
    id SERIAL PRIMARY KEY,
    dedupe_key VARCHAR(512) UNIQUE NOT NULL,
    cluster VARCHAR(128) NOT NULL,
    namespace VARCHAR(253) NOT NULL,
    resource_name VARCHAR(253) NOT NULL,
    resource_kind VARCHAR(63) NOT NULL,
    event_reason VARCHAR(128) NOT NULL,
    first_seen TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    last_seen TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    occurrence_count INTEGER NOT NULL DEFAULT 1,
    workflow_name VARCHAR(253),
    status VARCHAR(32) DEFAULT 'pending'
);

-- Index for fast lookups
CREATE INDEX idx_dedupe_key ON event_dedupe(dedupe_key);
CREATE INDEX idx_last_seen ON event_dedupe(last_seen);

-- Function to check/insert with TTL
CREATE OR REPLACE FUNCTION check_event_dedupe(
    p_dedupe_key VARCHAR(512),
    p_cluster VARCHAR(128),
    p_namespace VARCHAR(253),
    p_resource_name VARCHAR(253),
    p_resource_kind VARCHAR(63),
    p_event_reason VARCHAR(128),
    p_ttl_minutes INTEGER DEFAULT 30
) RETURNS VARCHAR AS $$
DECLARE
    v_result VARCHAR(32);
    v_cutoff TIMESTAMP WITH TIME ZONE;
BEGIN
    v_cutoff := NOW() - (p_ttl_minutes || ' minutes')::INTERVAL;

    -- Try to find recent occurrence
    SELECT 'skip' INTO v_result
    FROM event_dedupe
    WHERE dedupe_key = p_dedupe_key
      AND last_seen > v_cutoff;

    IF v_result = 'skip' THEN
        -- Update last_seen and increment count
        UPDATE event_dedupe
        SET last_seen = NOW(),
            occurrence_count = occurrence_count + 1
        WHERE dedupe_key = p_dedupe_key;

        RETURN 'skip';
    END IF;

    -- Insert new record (or update if exists but expired)
    INSERT INTO event_dedupe (
        dedupe_key, cluster, namespace, resource_name,
        resource_kind, event_reason, first_seen, last_seen
    ) VALUES (
        p_dedupe_key, p_cluster, p_namespace, p_resource_name,
        p_resource_kind, p_event_reason, NOW(), NOW()
    )
    ON CONFLICT (dedupe_key) DO UPDATE SET
        last_seen = NOW(),
        occurrence_count = event_dedupe.occurrence_count + 1;

    RETURN 'proceed';
END;
$$ LANGUAGE plpgsql;
```

---

## Phased Rollout Plan

### Phase 1: Critical Errors Only (Week 1-2)

**Goal:** Minimal noise, only critical issues trigger workflows.

**Changes:**
1. Update Fluent Bit filter to critical errors only
2. Add namespace exclusions for system namespaces
3. Add workflow mutex synchronization

**Events captured:**
- `CrashLoopBackOff`
- `OOMKilled`
- `NodeNotReady`
- `FailedMount`

**Expected volume:** ~5-20 events/day per cluster

### Phase 2: Add Scheduling Issues (Week 3-4)

**Goal:** Capture resource/scheduling problems.

**Additional events:**
- `FailedScheduling`
- `Evicted`
- `InsufficientMemory`
- `InsufficientCPU`

**Expected volume:** ~20-50 events/day per cluster

### Phase 3: Health Monitoring (Week 5-6)

**Goal:** Proactive health issue detection.

**Additional events:**
- `Unhealthy`
- `ProbeWarning`
- `FailedPreStopHook`

**Expected volume:** ~50-100 events/day per cluster

### Phase 4: Sensor-Level Filtering (Week 7-8)

**Goal:** Fine-grained control at the sensor level.

**Implement:**
- Sensor dependency filters
- Rate limiting
- Expression-based filtering

### Phase 5: Full Warning Coverage (Week 9+)

**Goal:** Comprehensive monitoring with smart aggregation.

**Implement:**
- Lua deduplication at source
- Redis-based cross-workflow deduplication
- Event aggregation and batching

---

## Monitoring and Observability

### Metrics to Track

```yaml
# Prometheus metrics for monitoring the pipeline
- name: k8s_events_received_total
  help: Total Kubernetes events received by Fluent Bit
  type: counter
  labels: [cluster, namespace, reason, severity]

- name: k8s_events_filtered_total
  help: Events filtered/dropped by Fluent Bit
  type: counter
  labels: [cluster, filter_reason]

- name: k8s_events_deduplicated_total
  help: Events dropped due to deduplication
  type: counter
  labels: [cluster]

- name: workflows_triggered_total
  help: Workflows triggered from events
  type: counter
  labels: [cluster, reason, workflow_template]

- name: workflows_skipped_mutex_total
  help: Workflows skipped due to mutex lock
  type: counter
  labels: [cluster, reason]
```

### Grafana Dashboard Queries

```promql
# Events received vs workflows triggered (noise ratio)
rate(k8s_events_received_total[5m]) / rate(workflows_triggered_total[5m])

# Deduplication effectiveness
sum(rate(k8s_events_deduplicated_total[1h])) / sum(rate(k8s_events_received_total[1h]))

# Top noisy namespaces
topk(10, sum by (namespace) (rate(k8s_events_received_total[1h])))

# Top event reasons
topk(10, sum by (reason) (rate(k8s_events_received_total[1h])))
```

### Alerting Rules

```yaml
groups:
  - name: event-pipeline
    rules:
      - alert: HighEventVolume
        expr: rate(k8s_events_received_total[5m]) > 100
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High volume of Kubernetes events"
          description: "Receiving {{ $value }} events/sec"

      - alert: LowDeduplicationRate
        expr: |
          sum(rate(k8s_events_deduplicated_total[1h])) /
          sum(rate(k8s_events_received_total[1h])) < 0.5
        for: 1h
        labels:
          severity: info
        annotations:
          summary: "Low deduplication rate"
          description: "Only {{ $value | humanizePercentage }} events deduplicated"

      - alert: WorkflowBacklog
        expr: |
          count(argo_workflows_status{status="Running"}) > 50
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Large workflow backlog"
```

---

## Quick Reference

### Fluent Bit Filter Cheat Sheet

| Filter | Purpose | Example |
|--------|---------|---------|
| `grep Regex` | Include matching | `Regex reason CrashLoop` |
| `grep Exclude` | Exclude matching | `Exclude namespace kube-system` |
| `lua` | Custom logic | Deduplication script |
| `throttle` | Rate limit | `Rate 10` per minute |
| `modify Add` | Add field | `Add cluster my-cluster` |

### Sensor Filter Cheat Sheet

| Filter Type | Purpose | Example |
|-------------|---------|---------|
| `data` | Field matching | `path: reason, value: [CrashLoop]` |
| `exprs` | Expression | `expr: 'age < 300'` |
| `time` | Time window | `start: "-5m"` |

### Workflow Sync Cheat Sheet

| Feature | Purpose | Example |
|---------|---------|---------|
| `mutex` | Single instance | `name: "triage-{{param}}"` |
| `semaphore` | Limit concurrent | `configMapKeyRef: limit` |
| `ttlStrategy` | Auto-cleanup | `secondsAfterSuccess: 1800` |
| `activeDeadlineSeconds` | Timeout | `1800` (30 min) |

---

## Implementation Checklist

- [ ] **Phase 1: Source Filtering**
  - [ ] Update Fluent Bit to filter critical errors only
  - [ ] Add namespace exclusions
  - [ ] Test with controlled event generation
  - [ ] Monitor Event Hub message volume

- [ ] **Phase 2: Workflow Controls**
  - [ ] Add mutex synchronization to workflow template
  - [ ] Configure TTL strategy
  - [ ] Set active deadline
  - [ ] Test mutex behavior

- [ ] **Phase 3: Sensor Filtering**
  - [ ] Implement sensor dependency filters
  - [ ] Add expression-based filtering
  - [ ] Test filter logic with debug sensor

- [ ] **Phase 4: Advanced Deduplication**
  - [ ] Implement Lua deduplication in Fluent Bit
  - [ ] Set up Redis for cross-workflow state
  - [ ] Configure monitoring dashboards

- [ ] **Phase 5: Monitoring**
  - [ ] Deploy Prometheus metrics
  - [ ] Create Grafana dashboards
  - [ ] Configure alerting rules

---

*Last updated: $(date +%Y-%m-%d)*
*Document version: 1.0*
