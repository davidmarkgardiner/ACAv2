---
name: dns-diagnostics
description: Comprehensive DNS diagnostic playbook for AKS clusters — CoreDNS, NodeLocalDNS, Cilium FQDN policies, and resolution paths.
---

# DNS Diagnostics Playbook

Use this skill when the user's question involves:

- Pods failing to resolve service names or external domains
- `Name or service not known`, `NXDOMAIN`, `SERVFAIL` errors
- Intermittent DNS failures
- Service unreachable by name but reachable by IP
- Questions about CoreDNS or NodeLocalDNS health

## Diagnostic Evidence Collection

Run these checks in order. Record the exact command and a one-line summary
of each result into the evidence table.

### Step 1 — CoreDNS pod health

```
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl describe deploy coredns -n kube-system
```

Check:
- All pods `Ready=True`
- No recent restarts (`RESTARTS` column)
- Deployment replica count matches desired

### Step 2 — CoreDNS service + endpoints

```
kubectl get svc kube-dns -n kube-system
kubectl get endpointslices -n kube-system -l k8s-app=kube-dns
```

Check:
- Service has ClusterIP
- EndpointSlice lists all CoreDNS pod IPs
- No endpoints missing

### Step 3 — CoreDNS configuration

```
kubectl get configmap coredns -n kube-system -o yaml
```

Look for:
- `forward` directive pointing somewhere valid (usually `/etc/resolv.conf`)
- `cache` block present (default 30s)
- Custom rewrite rules that may be broken
- `loop` plugin present (detects forwarding loops)

### Step 4 — CoreDNS logs for the last 5 minutes

```
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=200 --since=5m
```

Look for:
- `plugin/errors` entries showing upstream failures
- High rates of `SERVFAIL` or `REFUSED`
- Cache hit/miss ratio (if Prometheus plugin output is logged)

### Step 5 — CoreDNS metrics

```
kubectl get --raw /api/v1/namespaces/kube-system/services/http:kube-dns:metrics/proxy/metrics | grep -E 'coredns_dns_request_count|coredns_plugin_enabled|coredns_cache_hits'
```

Compute error rate:
- `sum(rate(coredns_dns_requests_total{rcode!="NOERROR"}[5m])) / sum(rate(coredns_dns_requests_total[5m]))`
- Anything > 5% is concerning.

### Step 6 — DNS resolution test from agent pod

```
# Internal (same namespace)
kubectl exec -n kagent deploy/kagent-controller -- nslookup kubernetes.default.svc.cluster.local

# External
kubectl exec -n kagent deploy/kagent-controller -- nslookup www.microsoft.com

# From the affected namespace/pod (user-specified)
kubectl exec -n <affected-ns> <pod> -- nslookup <name>
```

Note: DNS policy of the test pod may differ from the affected pod.
Always record `kubectl get pod <pod> -o jsonpath='{.spec.dnsPolicy}'`.

### Step 7 — NetworkPolicy blocking DNS

```
kubectl get networkpolicy -A
kubectl get ciliumnetworkpolicy -A 2>/dev/null
```

Look for:
- Policies in the affected namespace with `policyTypes: [Egress]`
- Egress rules that don't include port 53 UDP/TCP or the kube-dns endpoint
- Cilium `toFQDNs` policies missing the target domain

### Step 8 — NodeLocalDNS (if deployed)

```
kubectl get ds -n kube-system -l k8s-app=node-local-dns
kubectl logs -n kube-system -l k8s-app=node-local-dns --tail=50 --since=5m
```

Check:
- DaemonSet pods running on every node
- Interface `169.254.20.10` (or whatever the NodeLocalDNS IP is)
- Cilium `LocalRedirectPolicy` present (required for Cilium-based clusters)

## Failure Patterns & Root Causes

| Pattern | Evidence | Likely Root Cause |
|---|---|---|
| All pods can't resolve anything | Step 1 or 2 fails | CoreDNS down or no endpoints |
| Some pods resolve, others don't | Step 6 inconsistent | NetworkPolicy / node affinity / DNS policy difference |
| External names fail, internal works | Step 6 external fails | Upstream DNS misconfig, or Cilium toFQDNs not allowing domain |
| `SERVFAIL` in logs | Step 4 | Upstream DNS unreachable (check forward directive in Step 3) |
| Intermittent failures | Step 5 high error rate | CoreDNS capacity / caching issue, or upstream flaky |
| Resolution works in some namespaces only | Step 7 | NetworkPolicy blocking DNS egress |
| NodeLocalDNS-specific failures | Step 8 | Missing Cilium LocalRedirectPolicy |
| Custom domain not resolving | Step 3 `rewrite` or `forward` | Misconfigured ConfigMap |

## Proposed Remediation Examples

| Root Cause | Remediation | Proposed Tier |
|---|---|---|
| CoreDNS crashlooping | `kubectl rollout restart deployment/coredns -n kube-system` | T0 |
| NetworkPolicy missing DNS egress | Apply patched NetworkPolicy with port 53 UDP/TCP | T2 (staging), T3 (prod) |
| Cilium toFQDNs missing domain | Edit CiliumNetworkPolicy to add domain | T2 (staging), T3 (prod) |
| CoreDNS ConfigMap malformed | `kubectl edit configmap coredns -n kube-system` | T3 |
| NodeLocalDNS pods missing | `kubectl rollout restart daemonset/node-local-dns -n kube-system` | T0 |
| Upstream DNS server unreachable | Investigate Azure DNS / NAT gateway | T4 (escalate) |

## Ambiguity Handling

If after running steps 1-8 the evidence doesn't point clearly to one root cause:

1. Set `status: "insufficient_data"` in the output
2. List the specific additional data needed in `human_summary`
3. Suggest the user provide:
   - Specific pod/namespace that's affected
   - Exact error message they see
   - Whether it's consistent or intermittent
   - Whether it affects internal or external names

Never guess — escalate to a human.
