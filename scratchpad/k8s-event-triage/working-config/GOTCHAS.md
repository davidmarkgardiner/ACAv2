# Gotchas and Lessons Learned

Issues encountered during deployment, with fixes. Read before deploying.

---

## 1. Argo Events `stable` Tag = Rolling Release

**Problem:** Installing with `stable` tag pulls whatever version is latest. Between test and production deployment, the version changed and introduced Go panics.

**Fix:** Always pin to a specific version:
```bash
# WRONG
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml

# RIGHT
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-events/v1.9.10/manifests/install.yaml
```

---

## 2. Secret Key Names Must Match EXACTLY

**Problem:** EventSource Kafka SASL config references `key: username` but the secret had a key called `sasl-username`. EventSource pod starts but fails to connect with cryptic error about missing file.

**Error:** `failed to get secret value of name: eventhub-credentials, key: username, open /argo-events/secrets/eventhub-credentials/username: no such file or directory`

**Fix:** Secret keys must match the EventSource YAML exactly:
```bash
# EventSource says: sasl.userSecret.key: username
# So the secret MUST have a key named "username"
kubectl create secret generic eventhub-credentials -n argo-events \
  --from-literal=username='$ConnectionString' \
  --from-literal=connection-string='Endpoint=sb://...'
```

---

## 3. TLS CA Secret IS Required (Can't Skip It)

**Problem:** You might think `tls: {}` would use the system trust store. It doesn't — Argo Events v1.9.x validates that `caCertSecret` is set and rejects `tls: {}` with: *"invalid tls config, please configure either caCertSecret, or clientCertSecret and clientKeySecret, or both"*

**Fix:** You MUST create the CA cert secret, even for Azure Event Hub (public DigiCert CA):
```bash
echo | openssl s_client -connect <NAMESPACE>.servicebus.windows.net:9093 \
  -showcerts 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
  > /tmp/eventhub-ca-chain.pem

kubectl create secret generic eventhub-tls-ca -n argo-events \
  --from-file=ca.pem=/tmp/eventhub-ca-chain.pem
#            ^^^^^^ key must be ca.pem, not ca.crt
```

Generate once per Event Hub namespace — the cert rarely changes.

---

## 4. Event Hub Must Be Standard or Premium Tier

**Problem:** Azure Event Hub Basic tier does NOT support the Kafka protocol. The EventSource uses Kafka consumer groups to connect.

**Fix:** Use Standard or Premium tier when creating the Event Hub namespace.

---

## 5. Feedback Loop Prevention

**Problem:** Workflow pods generate K8s events (Scheduled, Pulled, Started, Created). If these events flow back through the pipeline, each workflow creates more workflows = exponential explosion.

**Fix:** Alloy's `loki.source.kubernetes_events` has a `namespaces` parameter. Only include application namespaces. NEVER include:
- `argo` (workflow controller)
- `argo-events` (workflow pods run here)
- `monitoring` (Alloy itself)
- `kube-system` (noisy, not useful)

---

## 6. Consumer Group Backlog Storm

**Problem:** When EventSource connects with a new consumer group, Event Hub may deliver all historical messages (even with `oldest: false`). This creates hundreds of workflows instantly.

**Fix options:**
1. Use a fresh consumer group name each time (e.g., `v3` -> `v4`)
2. Delete and recreate the Event Hub topic to clear messages
3. Sensor rate limiting helps but doesn't fully prevent it

---

## 7. EventBus Finalizer Gets Stuck

**Problem:** Deleting an EventBus while an EventSource still references it causes the controller to loop forever with "can not delete an EventBus with 1 EventSources connected".

**Fix:** Delete in the right order:
```bash
# 1. Delete EventSource first
kubectl delete eventsource <name> -n argo-events

# 2. If EventBus still stuck, remove finalizer
kubectl patch eventbus default -n argo-events \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

---

## 8. Workflow Pod GC Hides Logs

**Problem:** With `podGC.strategy: OnPodCompletion`, workflow pods are deleted immediately after completion. You can't `kubectl logs` them.

**Workaround:**
- Use Argo Workflows UI to view archived logs
- Or temporarily set `podGC.deleteDelayDuration: "300s"` to keep pods for 5 minutes
- Or use `kubectl get workflow <name> -o json` to see status (but not container stdout)

---

## 9. Alloy "no involved object for event" Errors

**Problem:** Alloy logs `error handling event ... no involved object for event` repeatedly.

**Cause:** Some K8s events (especially from Karpenter, node lifecycle) don't have an `involvedObject` field. Alloy can't process them.

**Impact:** None — Alloy skips these events and continues processing. The errors are harmless.

---

## 10. Event Hub TLS CA Chain

**Problem:** Azure Event Hub uses a specific CA chain (Microsoft TLS G2 RSA CA OCSP 16 -> Microsoft TLS RSA Root G2 -> DigiCert Global Root G2). The EventSource needs the full chain.

**Fix:** Extract the full chain from the Event Hub endpoint:
```bash
echo | openssl s_client -connect <NAMESPACE>.servicebus.windows.net:9093 \
  -showcerts 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
  > /tmp/eventhub-ca-chain.pem
```

This captures all intermediate + root certificates.

---

## 11. Argo Events RBAC: workflowtaskresults

**Problem:** Workflow pods fail with RBAC errors about `workflowtaskresults`.

**Fix:** The service account running workflows needs this additional role:
```yaml
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["workflowtaskresults"]
    verbs: ["create", "patch", "get", "list", "watch"]
```

This is included in `06-rbac.yaml`.

---

## 12. EventBus CR Image Overrides Are Ignored (Private Registry)

**Problem:** You set `streamImage`, `natsImage`, `reloaderImage`, or `metricsImage` on the EventBus CR, but the controller still pulls sidecar images from Docker Hub. The main NATS container may use your registry, but config-reloader and metrics-exporter sidecars fail with `ImagePullBackOff`.

**Cause:** The Argo Events controller reads image references from a **ConfigMap** (`argo-events-controller-config`), not from the EventBus CR. CR-level fields only affect the main container in some code paths. Sidecars are always read from the ConfigMap.

**Fix:** Override images at the **Helm chart level**, which populates the ConfigMap correctly:

```bash
helm upgrade --install argo-events argo/argo-events \
  -n argo-events --create-namespace \
  -f helm-values-argo-events.yaml
```

See `PRIVATE-REGISTRY.md` for the complete guide and `helm-values-argo-events.yaml` for the values file.

**Verify fix:**
```bash
kubectl get configmap argo-events-controller-config -n argo-events -o yaml | grep Image
# All image references should point to your private registry
```

---

## 13. JetStream replicas: 1 Deploys 3 Pods (Non-Clustered Mode Error)

**Problem:** EventBus YAML says `replicas: 1` but the controller deploys 3 pods. NATS then errors with: *"replicas > 1 not supported in non-clustered mode"*.

**Cause:** The Argo Events controller enforces a minimum of 3 replicas for JetStream EventBus, ignoring the CR value.

**Fix options:**
1. Set `replicas: 3` (recommended for production — enables NATS clustering)
2. Use native NATS EventBus instead of JetStream (simpler, no clustering required):
   ```yaml
   spec:
     nats:
       native:
         replicas: 3
         auth: token
   ```

Native NATS has no persistence (events in-flight are lost on restart) but is simpler to operate. Event Hub still has the messages, so the EventSource will re-consume.
