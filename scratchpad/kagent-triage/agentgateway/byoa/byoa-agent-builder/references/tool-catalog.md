# kagent Tool Catalog

Tools available via `kagent-tool-server` (RemoteMCPServer). Always specify `toolNames` explicitly — passing `None` causes a ValidationError.

Ground truth: cross-checked against `kagent-triage/cert-manager-agent.yaml`. Use only tool names that appear in deployed agents unless the target cluster has been separately verified.

## Read-Only Tools (safe for triage agents)

| Tool Name | Description |
|-----------|-------------|
| `k8s_get_resources` | List resources of a given kind in a namespace |
| `k8s_describe_resource` | Describe a specific resource (equivalent to `kubectl describe`) |
| `k8s_get_pod_logs` | Fetch container logs from a pod |
| `k8s_get_events` | Get Kubernetes events for a namespace or resource |
| `k8s_get_resource_yaml` | Get the raw YAML of a resource |
| `k8s_get_available_api_resources` | List available API resource types in the cluster |
| `k8s_get_cluster_configuration` | Get cluster-level configuration info |
| `k8s_check_service_connectivity` | Test connectivity between services |

## Write Tools (remediation agents only)

| Tool Name | Description | Risk |
|-----------|-------------|------|
| `k8s_apply_manifest` | Apply a YAML manifest to the cluster | Medium |
| `k8s_create_resource` | Create a new Kubernetes resource | Medium |
| `k8s_patch_resource` | Patch an existing resource (strategic merge) | Medium |
| `k8s_annotate_resource` | Add/update annotations on a resource | Low |
| `k8s_remove_annotation` | Remove annotations from a resource | Low |
| `k8s_label_resource` | Add/update labels on a resource | Low |
| `k8s_remove_label` | Remove labels from a resource | Low |
| `k8s_delete_resource` | Delete a Kubernetes resource | High |
| `k8s_execute_command` | Execute a command inside a container | High |

## Recommended Tool Sets

### Triage Agent (read-only)
```yaml
toolNames:
  - k8s_get_resources
  - k8s_describe_resource
  - k8s_get_pod_logs
  - k8s_get_events
  - k8s_get_resource_yaml
  - k8s_get_available_api_resources
  - k8s_get_cluster_configuration
  - k8s_check_service_connectivity
```

### Remediation Agent (full access)
```yaml
toolNames:
  - k8s_get_resources
  - k8s_describe_resource
  - k8s_get_pod_logs
  - k8s_get_events
  - k8s_get_resource_yaml
  - k8s_get_available_api_resources
  - k8s_get_cluster_configuration
  - k8s_check_service_connectivity
  - k8s_apply_manifest
  - k8s_create_resource
  - k8s_patch_resource
  - k8s_annotate_resource
  - k8s_remove_annotation
  - k8s_label_resource
  - k8s_remove_label
  - k8s_delete_resource
  - k8s_execute_command
```

## Not Observed in Deployed Agents

These tool names were previously documented here but do not appear in the ground-truth deployed `cert-manager-agent` tool list. Do not include them in generated Agent CRDs unless the live cluster confirms they exist.

| Tool Name | Previous Description |
|-----------|----------------------|
| `helm_list_releases` | List Helm releases in a namespace |
| `helm_get_release` | Get details of a specific Helm release |

## Notes

- Every Agent CRD tool reference must include `apiGroup: kagent.dev` under `spec.declarative.tools[].mcpServer`
- `k8s_execute_command` requires the target container to have a shell
- `k8s_delete_resource` should be avoided in triage agents — include only if explicitly requested
- The tool server has cluster-wide read access; namespace scoping is enforced via system prompt (soft) or RBAC (hard, for production)
