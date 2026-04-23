---
name: k8s-networking
description: Diagnostic playbook for Kubernetes pod/service connectivity, endpoints, network policies, and Cilium/Hubble flows.
---

# Kubernetes Networking Playbook

Use this skill when the user's question involves:

- Pod-to-pod or pod-to-service communication failures
- Service with no endpoints
- NetworkPolicy blocking expected traffic
- Pod stuck Pending or not Ready
- Hubble reporting DROPPED flows

## Diagnostic Evidence Collection

### Step 1 — Pod status & scheduling

```
kubectl get pod <pod> -n <namespace> -o wide
kubectl describe pod <pod> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

Check:
- Pod `Ready` column shows all containers ready
- Pod has an IP assigned (not `None`)
- Pod scheduled to a node
- No recent events like `FailedScheduling`, `BackOff`, `Unhealthy`

### Step 2 — Service configuration

```
kubectl get svc <service> -n <namespace> -o yaml
```

Check:
- `spec.selector` labels — must match pod labels exactly
- `spec.ports[].targetPort` — must match pod's `containerPort`
- `spec.type` appropriate (ClusterIP for internal, LoadBalancer for external)

Common gotcha: `targetPort: 8080` on service but pod listens on `80` —
connections time out despite healthy endpoints.

### Step 3 — Service endpoints

```
kubectl get endpointslices -n <namespace> -l kubernetes.io/service-name=<service>
kubectl describe svc <service> -n <namespace>
```

Check:
- EndpointSlice exists and lists pod IPs
- If empty:
  - Selector mismatch (Step 2)
  - No pods ready (Step 1)
  - Pod readiness probes failing

### Step 4 — Pod labels match service selector

```
SEL=$(kubectl get svc <service> -n <namespace> -o jsonpath='{.spec.selector}')
kubectl get pods -n <namespace> -l "$(echo $SEL | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')"
```

If returns empty: selector doesn't match any pod.
If returns pods but not the expected one: label mismatch on the expected pod.

### Step 5 — Network policies

```
kubectl get networkpolicy -n <namespace>
kubectl get ciliumnetworkpolicy -n <namespace> 2>/dev/null
kubectl get ciliumclusterwidenetworkpolicy 2>/dev/null
```

For each policy, look at:
- `podSelector` — does it target the affected pod?
- `policyTypes` — Ingress? Egress? Both?
- `ingress.from` / `egress.to` — restrict what's allowed

Common issue: a "default deny all" policy without corresponding "allow"
policies — everything blocked.

### Step 6 — Hubble flow inspection (if ACNS enabled)

```
# Check Hubble is available
kubectl get daemonset -n kube-system hubble-relay 2>/dev/null || \
  kubectl get pod -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}'

# Observe flows to the affected pod
kubectl exec -n kube-system <cilium-pod> -- hubble observe \
  --to-pod <namespace>/<pod> --last 20 -o compact

# Look for DROPPED verdicts
kubectl exec -n kube-system <cilium-pod> -- hubble observe \
  --verdict DROPPED --to-pod <namespace>/<pod> --last 50
```

If Hubble isn't available (no ACNS): skip this step and note in evidence
that flow-level visibility isn't possible.

### Step 7 — DNS resolution of the service name (link to dns-diagnostics)

If the caller is using a DNS name rather than an IP:

```
kubectl exec -n <caller-ns> <caller-pod> -- nslookup <service>.<namespace>.svc.cluster.local
```

If this fails, it's actually a DNS issue — follow the dns-diagnostics skill.

### Step 8 — Direct connectivity test

Bypass DNS, use service IP directly:

```
SVC_IP=$(kubectl get svc <service> -n <namespace> -o jsonpath='{.spec.clusterIP}')
SVC_PORT=$(kubectl get svc <service> -n <namespace> -o jsonpath='{.spec.ports[0].port}')
kubectl exec -n <caller-ns> <caller-pod> -- timeout 3 nc -zv $SVC_IP $SVC_PORT
```

Outcomes:
- Success → the pod can reach the service IP; issue is DNS or application layer
- Connection refused → reached target node but no endpoint listening
- Timeout → network policy or routing issue

### Step 9 — Direct pod-to-pod connectivity

```
POD_IP=$(kubectl get pod <target> -n <namespace> -o jsonpath='{.status.podIP}')
kubectl exec -n <caller-ns> <caller> -- timeout 3 nc -zv $POD_IP <targetPort>
```

If pod-to-service fails but pod-to-pod succeeds: service misconfig (Step 2 / 3).
If both fail: network policy or routing issue.

## Failure Patterns & Root Causes

| Pattern | Evidence | Likely Root Cause |
|---|---|---|
| Service has no endpoints | Step 3 empty, Step 4 empty | Selector doesn't match any pod |
| Endpoints exist but timeouts | Step 3 OK, Step 8 timeout | NetworkPolicy blocking; or `targetPort` wrong (Step 2) |
| Pod-to-pod works, pod-to-service doesn't | Step 9 OK, Step 8 fails | Service config wrong (selector, targetPort, type) |
| Intermittent connectivity | Mix of Step 8 results | One endpoint failing readiness probe → check Step 1 on each endpoint |
| Hubble shows DROPPED verdict | Step 6 | NetworkPolicy (Cilium or K8s) dropping the flow |
| Pod stuck Pending | Step 1 | Scheduling issue; describe shows reason (resource, taint, affinity) |
| Pod running but not Ready | Step 1 + events | Readiness probe failing; describe shows probe details |

## Proposed Remediation Examples

| Root Cause | Remediation | Proposed Tier |
|---|---|---|
| Pod stuck Pending (no resources) | `kubectl scale deploy/<x> --replicas=N` to free up, or node scale | T1 / T2 |
| Service targetPort wrong | `kubectl patch svc <svc> -n <ns> --type merge -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}'` | T2 |
| Selector label missing on pod | Edit deployment template labels | T2 |
| Overly restrictive NetworkPolicy | Apply corrected NetworkPolicy | T2 (staging), T3 (prod) |
| Readiness probe failing | Investigate application (separate agent); suggest raising `initialDelaySeconds` | T2 |
| Cilium policy dropping flow | Edit CiliumNetworkPolicy | T3 |
| Pod has no IP (CNI issue) | `kubectl delete pod` to force reschedule; investigate CNI agent | T2 |

## Ambiguity Handling

If evidence is contradictory or insufficient:

1. Set `status: "insufficient_data"` or `"degraded"` with low confidence
2. List specifics needed: exact error message, timing, client pod name, target
3. Suggest re-running the diagnostic with that info

Prefer to propose a higher tier (more human review) when unsure — agent
output may mislead automated remediation if confidence is low.
