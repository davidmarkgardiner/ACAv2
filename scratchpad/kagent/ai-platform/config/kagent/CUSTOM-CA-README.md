# Mounting Custom CA into kagent (Enterprise/Work)

For environments where internal services use certificates signed by a private CA.

## Prerequisites

- ConfigMap `custom-ca` exists in the `kagent` namespace
- Check the key name:

```bash
kubectl get configmap custom-ca -n kagent -o jsonpath='{.data}' | jq 'keys'
```

## Which pods need the CA?

| Pod | Why | How |
|-----|-----|-----|
| kagent-controller | Talks to K8s API, manages agents | Helm values |
| kagent-tools (tool server) | Talks to K8s API, runs kubectl/helm | kubectl patch |
| Agent pods (k8s-agent, etc.) | Talk to LiteLLM, tool server, controller | kubectl patch |
| kagent-ui | Talks to controller (usually HTTP, not TLS) | Probably not needed |

## 1. Controller — via Helm values

Add to your work values file:

```yaml
controller:
  volumes:
    - name: custom-ca
      configMap:
        name: custom-ca
  volumeMounts:
    - name: custom-ca
      mountPath: /etc/ssl/certs/custom-ca.crt
      subPath: ca.crt
      readOnly: true
  env:
    - name: SSL_CERT_FILE
      value: /etc/ssl/certs/custom-ca.crt
```

Then upgrade:

```bash
helm upgrade kagent ./kagent/helm/kagent \
  --namespace kagent \
  -f kagent-values-work.yaml
```

## 2. Tool server — patch after install

```bash
kubectl -n kagent patch deploy kagent-tools --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "custom-ca",
      "configMap": {
        "name": "custom-ca"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "custom-ca",
      "mountPath": "/etc/ssl/certs/custom-ca.crt",
      "subPath": "ca.crt",
      "readOnly": true
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/env/-",
    "value": {
      "name": "SSL_CERT_FILE",
      "value": "/etc/ssl/certs/custom-ca.crt"
    }
  }
]'
```

## 3. Agent pods — patch each agent deployment

Agent deployments are created by the kagent controller from Agent CRDs. Patch each one:

```bash
# Patch all agent deployments at once
for deploy in $(kubectl get deploy -n kagent -o name | grep -E 'agent'); do
  echo "Patching $deploy..."
  kubectl -n kagent patch $deploy --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/volumes/-",
      "value": {
        "name": "custom-ca",
        "configMap": {
          "name": "custom-ca"
        }
      }
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/volumeMounts/-",
      "value": {
        "name": "custom-ca",
        "mountPath": "/etc/ssl/certs/custom-ca.crt",
        "subPath": "ca.crt",
        "readOnly": true
      }
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/env/-",
      "value": {
        "name": "SSL_CERT_FILE",
        "value": "/etc/ssl/certs/custom-ca.crt"
      }
    }
  ]'
done
```

**Note:** The controller may reconcile agent deployments and revert patches. If patches get reverted, you have two options:

### Option A: Patch the controller to inject the CA into agents it creates

Check if the controller supports a global env/volume injection (check controller configmap):

```bash
kubectl get configmap -n kagent -l app.kubernetes.io/component=controller -o yaml
```

### Option B: Set REQUESTS_CA_BUNDLE at the Python level

Agent pods run Python (Google ADK). Python's `requests` library uses `REQUESTS_CA_BUNDLE`:

```bash
for deploy in $(kubectl get deploy -n kagent -o name | grep -E 'agent'); do
  kubectl -n kagent patch $deploy --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/volumes/-",
      "value": {"name": "custom-ca", "configMap": {"name": "custom-ca"}}
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/volumeMounts/-",
      "value": {"name": "custom-ca", "mountPath": "/etc/ssl/certs/custom-ca.crt", "subPath": "ca.crt", "readOnly": true}
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/env/-",
      "value": {"name": "SSL_CERT_FILE", "value": "/etc/ssl/certs/custom-ca.crt"}
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/env/-",
      "value": {"name": "REQUESTS_CA_BUNDLE", "value": "/etc/ssl/certs/custom-ca.crt"}
    }
  ]'
done
```

## Verify

```bash
# Check all pods have the volume mounted
for deploy in $(kubectl get deploy -n kagent -o name); do
  echo "--- $deploy ---"
  kubectl -n kagent get $deploy -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null
  echo
done

# Test from inside a pod
kubectl exec -n kagent deploy/kagent-tools -- ls -la /etc/ssl/certs/custom-ca.crt
kubectl exec -n kagent deploy/kagent-tools -- env | grep -E 'SSL_CERT|REQUESTS_CA'
```

## Adjust subPath

Replace `ca.crt` everywhere above with the actual key name from your ConfigMap:

```bash
kubectl get configmap custom-ca -n kagent -o jsonpath='{.data}' | jq 'keys'
```
