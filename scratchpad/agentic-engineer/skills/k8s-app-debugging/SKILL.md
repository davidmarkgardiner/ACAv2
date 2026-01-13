---
name: k8s-app-debugging
description: Debug Kubernetes application-layer issues including pod failures, CrashLoopBackOff, OOMKilled, ImagePullBackOff, deployment rollouts, service connectivity, log analysis, and resource constraints. This skill should be used when investigating pod crashes, analyzing application logs, debugging service discovery issues, or troubleshooting deployment problems in any Kubernetes cluster.
---

# Kubernetes Application Debugging

## Overview

This skill provides systematic workflows for debugging application-layer issues in Kubernetes, from pod crashes to service connectivity problems.

## Quick Start Decision Tree

```
Application Issue
├── Pod Not Running
│   ├── Pending → Check scheduling, resources, node selectors
│   ├── CrashLoopBackOff → Check logs, container startup
│   ├── ImagePullBackOff → Check image name, registry auth
│   ├── OOMKilled → Check memory limits, application memory usage
│   └── Error → Check pod events, init containers
├── Pod Running But Not Working
│   ├── Readiness probe failing → Check probe config, app health endpoint
│   ├── Service not reachable → Check endpoints, selectors, network policies
│   └── Wrong behavior → Check logs, configuration, environment variables
└── Deployment Issues
    ├── Rollout stuck → Check replica status, PDB, resource availability
    └── Wrong version → Check image tags, rollout history
```

## Pod Debugging

### Initial Assessment

```bash
# Get pod status overview
kubectl get pods -n <namespace> -o wide

# Get detailed pod information
kubectl describe pod <pod-name> -n <namespace>

# Check pod events (most recent)
kubectl get events -n <namespace> --field-selector involvedObject.name=<pod-name> --sort-by='.lastTimestamp'
```

### CrashLoopBackOff

```bash
# Check current logs
kubectl logs <pod-name> -n <namespace>

# Check previous container logs (after crash)
kubectl logs <pod-name> -n <namespace> --previous

# Check all containers in multi-container pod
kubectl logs <pod-name> -n <namespace> -c <container-name>

# Stream logs
kubectl logs -f <pod-name> -n <namespace>
```

**Common Causes:**
1. Application startup failure - check logs for exceptions
2. Missing configuration - verify ConfigMaps/Secrets mounted
3. Dependency unavailable - check if databases/services are reachable
4. Incorrect command/args - verify container spec

### OOMKilled

```bash
# Check termination reason
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'

# View resource limits
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.containers[*].resources}'

# Check actual resource usage
kubectl top pod <pod-name> -n <namespace>
```

**Resolution:**
1. Increase memory limits in pod spec
2. Profile application for memory leaks
3. Check for memory-intensive operations

### ImagePullBackOff

```bash
# Check image name in events
kubectl describe pod <pod-name> -n <namespace> | grep -A5 "Events:"

# Verify image exists
docker pull <image-name>

# Check imagePullSecrets
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.imagePullSecrets}'
kubectl get secret <secret-name> -n <namespace> -o yaml
```

### Pending Pods

```bash
# Check scheduling issues
kubectl describe pod <pod-name> -n <namespace> | grep -A10 "Events:"

# Check node resources
kubectl describe nodes | grep -A5 "Allocated resources"

# Check node taints
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Check PVC status (if using persistent volumes)
kubectl get pvc -n <namespace>
```

## Container Debugging

### Execute Commands in Container

```bash
# Get a shell in the container
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh

# Run specific command
kubectl exec <pod-name> -n <namespace> -- cat /app/config.yaml

# Execute in specific container
kubectl exec -it <pod-name> -n <namespace> -c <container-name> -- /bin/bash
```

### Debug Container (Ephemeral Containers)

```bash
# Add debug container to running pod
kubectl debug -it <pod-name> -n <namespace> --image=busybox --target=<container-name>

# Create debug pod copying spec
kubectl debug <pod-name> -n <namespace> --copy-to=debug-pod --container=debug --image=busybox -it
```

### Check Container Environment

```bash
# View environment variables
kubectl exec <pod-name> -n <namespace> -- env

# Check mounted volumes
kubectl exec <pod-name> -n <namespace> -- ls -la /path/to/mount

# Verify DNS resolution
kubectl exec <pod-name> -n <namespace> -- nslookup <service-name>

# Test network connectivity
kubectl exec <pod-name> -n <namespace> -- wget -qO- http://<service>:<port>/health
```

## Service Debugging

### Service Connectivity

```bash
# Check service exists and has endpoints
kubectl get svc <service-name> -n <namespace>
kubectl get endpoints <service-name> -n <namespace>

# Verify selector matches pods
kubectl get svc <service-name> -n <namespace> -o jsonpath='{.spec.selector}'
kubectl get pods -n <namespace> -l <selector-key>=<selector-value>

# Test from within cluster
kubectl run test-curl --image=curlimages/curl --rm -it --restart=Never -- curl -v http://<service>.<namespace>.svc.cluster.local:<port>
```

### DNS Issues

```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Test DNS resolution
kubectl run dns-test --image=busybox --rm -it --restart=Never -- nslookup <service>.<namespace>.svc.cluster.local

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
```

### Network Policies

```bash
# List network policies
kubectl get networkpolicies -n <namespace>

# Describe network policy
kubectl describe networkpolicy <policy-name> -n <namespace>

# Check if pod is affected by network policy
kubectl get pods -n <namespace> --show-labels
```

## Deployment Debugging

### Rollout Issues

```bash
# Check rollout status
kubectl rollout status deployment/<deployment-name> -n <namespace>

# View rollout history
kubectl rollout history deployment/<deployment-name> -n <namespace>

# Check replica sets
kubectl get rs -n <namespace> -l <deployment-selector>

# Describe deployment for events
kubectl describe deployment <deployment-name> -n <namespace>
```

### Rollback

```bash
# Rollback to previous version
kubectl rollout undo deployment/<deployment-name> -n <namespace>

# Rollback to specific revision
kubectl rollout undo deployment/<deployment-name> -n <namespace> --to-revision=<revision>

# Pause/Resume rollout
kubectl rollout pause deployment/<deployment-name> -n <namespace>
kubectl rollout resume deployment/<deployment-name> -n <namespace>
```

## Log Analysis

### Multi-Pod Logs

```bash
# Logs from all pods with label
kubectl logs -n <namespace> -l app=<app-name> --all-containers

# Logs with timestamps
kubectl logs <pod-name> -n <namespace> --timestamps

# Logs since specific time
kubectl logs <pod-name> -n <namespace> --since=1h
kubectl logs <pod-name> -n <namespace> --since-time="2024-01-01T00:00:00Z"

# Tail logs with line limit
kubectl logs <pod-name> -n <namespace> --tail=100
```

### Log Patterns to Search

Run `scripts/log-analyzer.sh` to search for common error patterns:

```bash
./scripts/log-analyzer.sh <namespace> <pod-name>
```

Common patterns:
- `error`, `Error`, `ERROR`
- `exception`, `Exception`, `EXCEPTION`
- `failed`, `failure`, `Failed`
- `timeout`, `Timeout`
- `connection refused`, `connection reset`
- `OOM`, `out of memory`

## Resource Analysis

### Check Resource Usage

```bash
# Pod resource usage
kubectl top pods -n <namespace>

# Container-level usage
kubectl top pods -n <namespace> --containers

# Node resource usage
kubectl top nodes

# Detailed resource requests/limits
kubectl get pods -n <namespace> -o custom-columns="NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,CPU_LIM:.spec.containers[*].resources.limits.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory,MEM_LIM:.spec.containers[*].resources.limits.memory"
```

### Resource Quotas and Limits

```bash
# Check namespace quotas
kubectl get resourcequota -n <namespace>
kubectl describe resourcequota -n <namespace>

# Check LimitRanges
kubectl get limitrange -n <namespace>
kubectl describe limitrange -n <namespace>
```

## Quick Reference

| Symptom | First Command |
|---------|---------------|
| Pod not starting | `kubectl describe pod <pod>` |
| Container crashing | `kubectl logs <pod> --previous` |
| Service unreachable | `kubectl get endpoints <svc>` |
| High resource usage | `kubectl top pods` |
| Deployment stuck | `kubectl rollout status deployment/<name>` |
| DNS issues | `kubectl logs -n kube-system -l k8s-app=kube-dns` |

## Resources

- **scripts/pod-diagnostics.sh** - Comprehensive pod health check
- **scripts/log-analyzer.sh** - Search logs for common error patterns
- **scripts/service-connectivity-test.sh** - Test service-to-service connectivity
- **references/common-errors.md** - Common Kubernetes errors and resolutions
