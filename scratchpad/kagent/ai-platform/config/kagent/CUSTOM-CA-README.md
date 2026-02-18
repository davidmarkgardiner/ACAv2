# Mounting Custom CA into kagent Controller

For enterprise environments where internal services use certificates signed by a private CA.

## Prerequisites

- ConfigMap `custom-ca` exists in the `kagent` namespace
- Check the key name in the ConfigMap:

```bash
kubectl get configmap custom-ca -n kagent -o jsonpath='{.data}' | jq 'keys'
```

## Values Override

Add to your kagent values file (adjust `subPath` to match the key name in your ConfigMap):

```yaml
controller:
  volumes:
    - name: custom-ca
      configMap:
        name: custom-ca
  volumeMounts:
    - name: custom-ca
      mountPath: /etc/ssl/certs/custom-ca.crt
      subPath: ca.crt          # Change to match your ConfigMap key
      readOnly: true
  env:
    - name: SSL_CERT_FILE
      value: /etc/ssl/certs/custom-ca.crt
```

## Install / Upgrade

```bash
helm upgrade --install kagent ./kagent/helm/kagent \
  --namespace kagent \
  -f kagent-values-work.yaml
```

## Verify

```bash
# Check the volume is mounted
kubectl describe deploy -n kagent kagent-controller | grep -A5 "Volumes\|Mounts"

# Check the cert is readable inside the pod
kubectl exec -n kagent deploy/kagent-controller -- cat /etc/ssl/certs/custom-ca.crt

# Check the env var is set
kubectl exec -n kagent deploy/kagent-controller -- env | grep SSL_CERT
```

## Alternative: Full CA Bundle Mount

If your ConfigMap contains a full CA bundle (your custom CA appended to system CAs), mount it directly to the system cert path instead:

```yaml
controller:
  volumes:
    - name: custom-ca
      configMap:
        name: custom-ca
  volumeMounts:
    - name: custom-ca
      mountPath: /etc/ssl/certs/ca-certificates.crt
      subPath: ca-bundle.crt   # Change to match your ConfigMap key
      readOnly: true
```

No `SSL_CERT_FILE` env var needed in this case — Go uses `/etc/ssl/certs/ca-certificates.crt` by default.
