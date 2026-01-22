# Deployment Checklist - Fluent Bit + Event Hub (Production)

## Prerequisites
- [ ] External Secrets Operator installed on source cluster
- [ ] ClusterSecretStore configured for Azure Key Vault
- [ ] Event Hub namespace and hub created
- [ ] Event Hub connection string stored in Key Vault

## On Source Cluster (where K8s events originate)

1. **Create namespace**
   ```bash
   kubectl create namespace monitoring
   ```

2. **Apply External Secret** (syncs SAS token from Key Vault)
   ```bash
   # Update secretStoreRef.name in 00-external-secret.yaml first
   kubectl apply -f 00-external-secret.yaml
   ```

3. **Verify secret was created**
   ```bash
   kubectl get externalsecret eventhub-sas-secret -n monitoring
   kubectl get secret eventhub-sas-secret -n monitoring
   ```

4. **Update and apply Fluent Bit config**
   ```bash
   # No changes needed unless modifying filters
   kubectl apply -f 01-fluent-bit-config.yaml
   ```

5. **Update and apply Fluent Bit deployment**
   ```bash
   # Update CLUSTER_NAME in 02-fluent-bit-deployment.yaml
   # Update EVENTHUB_NAMESPACE, EVENTHUB_NAME, EVENTHUB_FQDN in ConfigMap
   kubectl apply -f 02-fluent-bit-deployment.yaml
   ```

6. **Verify Fluent Bit is running**
   ```bash
   kubectl get pods -n monitoring -l app=fluent-bit
   kubectl logs -n monitoring -l app=fluent-bit | grep -i kafka
   ```

## On Management Cluster (Argo Events consumer)

7. **Create Event Hub secret** (choose one method)

   **Option A: External Secrets (if ESO is installed)**
   ```bash
   # First store secrets in Key Vault:
   KEY_NAME="RootManageSharedAccessKey"
   KEY_VALUE=$(az eventhubs namespace authorization-rule keys list \
     --resource-group $RESOURCE_GROUP \
     --namespace-name $EVENTHUB_NAMESPACE \
     --name $KEY_NAME --query primaryKey -o tsv)

   az keyvault secret set --vault-name $KEY_VAULT --name eventhub-shared-access-key-name --value "$KEY_NAME"
   az keyvault secret set --vault-name $KEY_VAULT --name eventhub-shared-access-key --value "$KEY_VALUE"

   # Update secretStoreRef.name in 03a-mgmt-cluster-external-secret.yaml
   kubectl apply -f 03a-mgmt-cluster-external-secret.yaml
   ```

   **Option B: Manual secret**
   ```bash
   KEY_NAME="RootManageSharedAccessKey"
   KEY_VALUE=$(az eventhubs namespace authorization-rule keys list \
     --resource-group $RESOURCE_GROUP \
     --namespace-name $EVENTHUB_NAMESPACE \
     --name $KEY_NAME --query primaryKey -o tsv)

   kubectl create secret generic eventhub-listener-secret \
     --namespace argo-events \
     --from-literal=sharedAccessKeyName="$KEY_NAME" \
     --from-literal=sharedAccessKey="$KEY_VALUE"
   ```

8. **Apply EventSource** (consumes from Event Hub)
   ```bash
   # Update fqdn in 03-eventsource-workload-identity.yaml
   kubectl apply -f 03-eventsource-workload-identity.yaml
   ```

9. **Apply Sensor**
   ```bash
   # Update gitlab-project in 04-sensor-production.yaml
   kubectl apply -f 04-sensor-production.yaml
   ```

10. **Apply shared WorkflowTemplate** (if not already deployed)
    ```bash
    kubectl apply -f ../workflow-multi-cluster-triage.yaml
    ```

## Verification

11. **Generate test event**
    ```bash
    kubectl run test-event --image=invalid-image-xyz --restart=Never
    kubectl delete pod test-event --ignore-not-found
    ```

12. **Check pipeline**
    ```bash
    # Fluent Bit logs
    kubectl logs -n monitoring -l app=fluent-bit --tail=20

    # EventSource logs (management cluster)
    kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=20

    # Sensor logs
    kubectl logs -n argo-events -l sensor-name=fluent-bit-gitlab-issues --tail=20

    # Check workflows
    kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp | tail -5
    ```
