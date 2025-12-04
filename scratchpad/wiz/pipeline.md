

```yaml
# azure-pipelines.yaml
trigger:
  branches:
    include:
      - main
  paths:
    include:
      - charts/app-team-widget/*

parameters:
  - name: namespace
    type: string
    default: 'widget-app'
  - name: releaseName
    type: string
    default: 'widget'
  - name: chartPath
    type: string
    default: 'charts/app-team-widget'
  - name: aadGroupId
    type: string
    displayName: 'AAD Group Object ID for RBAC assignment'

variables:
  - name: managementGroupId
    value: 'mg-aks-clusters'  # Your management group containing AKS clusters

stages:
- stage: Deploy
  displayName: 'Deploy to all AKS clusters'
  jobs:
  - job: GetClusters
    displayName: 'Discover AKS clusters'
    pool:
      vmImage: 'ubuntu-latest'
    steps:
    - task: AzureCLI@2
      name: ListClusters
      inputs:
        azureSubscription: $(serviceConnection)
        scriptType: bash
        scriptLocation: inlineScript
        inlineScript: |
          # Get all subscriptions under the management group
          SUBSCRIPTIONS=$(az account management-group entities list \
            --name $(managementGroupId) \
            --query "[?type=='Microsoft.Management/managementGroups/subscriptions'].name" -o tsv)
          
          # Build JSON array of all AKS clusters
          CLUSTERS="[]"
          for SUB in $SUBSCRIPTIONS; do
            az account set --subscription $SUB
            
            SUB_CLUSTERS=$(az aks list --query "[].{name:name, resourceGroup:resourceGroup, subscriptionId:'$SUB', id:id}" -o json)
            CLUSTERS=$(echo "$CLUSTERS" | jq --argjson new "$SUB_CLUSTERS" '. + $new')
          done
          
          echo "Found $(echo $CLUSTERS | jq length) clusters"
          echo "##vso[task.setvariable variable=clusterMatrix;isOutput=true]$CLUSTERS"

  - job: DeployToCluster
    displayName: 'Deploy to cluster'
    dependsOn: GetClusters
    pool:
      vmImage: 'ubuntu-latest'
    strategy:
      matrix: $[ convertToJson(dependencies.GetClusters.outputs['ListClusters.clusterMatrix']) ]
      maxParallel: 10
    steps:
    - task: AzureCLI@2
      displayName: 'Assign RBAC and deploy Helm chart'
      inputs:
        azureSubscription: $(serviceConnection)
        scriptType: bash
        scriptLocation: inlineScript
        inlineScript: |
          set -e
          
          CLUSTER_NAME="$(name)"
          RESOURCE_GROUP="$(resourceGroup)"
          SUBSCRIPTION_ID="$(subscriptionId)"
          CLUSTER_ID="$(id)"
          NAMESPACE="${{ parameters.namespace }}"
          AAD_GROUP_ID="${{ parameters.aadGroupId }}"
          
          echo "Processing cluster: $CLUSTER_NAME in $RESOURCE_GROUP"
          
          az account set --subscription $SUBSCRIPTION_ID
          
          # --- RBAC Assignment ---
          # Check if assignment already exists to avoid errors
          EXISTING=$(az role assignment list \
            --assignee $AAD_GROUP_ID \
            --scope "$CLUSTER_ID/namespaces/$NAMESPACE" \
            --role "Azure Kubernetes Service RBAC Writer" \
            --query "length(@)" -o tsv)
          
          if [ "$EXISTING" -eq "0" ]; then
            echo "Creating RBAC assignment for namespace $NAMESPACE"
            az role assignment create \
              --role "Azure Kubernetes Service RBAC Writer" \
              --assignee-object-id $AAD_GROUP_ID \
              --assignee-principal-type Group \
              --scope "$CLUSTER_ID/namespaces/$NAMESPACE"
            
            # Allow time for RBAC propagation
            echo "Waiting for RBAC propagation..."
            sleep 30
          else
            echo "RBAC assignment already exists"
          fi
          
          # --- Helm Deployment ---
          az aks get-credentials \
            --resource-group $RESOURCE_GROUP \
            --name $CLUSTER_NAME \
            --overwrite-existing
          
          # Create namespace if it doesn't exist
          kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
          
          # Deploy Helm chart
          helm upgrade --install ${{ parameters.releaseName }} ${{ parameters.chartPath }} \
            --namespace $NAMESPACE \
            --wait \
            --timeout 5m
          
          echo "Successfully deployed to $CLUSTER_NAME"
```

## Key Points

**RBAC assignment idempotency** - the script checks for existing assignments before creating, avoiding duplicate assignment errors.

**Propagation delay** - the 30-second wait after RBAC creation accounts for the up-to-five-minute propagation time. You might need to tune this or add retry logic.

**Parallel execution** - `maxParallel: 10` limits concurrent deployments. Adjust based on your Azure API rate limits and how aggressive you want to be.

**Cluster User Role** - the pipeline's service principal/managed identity needs `Azure Kubernetes Service Cluster User Role` at the management group or subscription level to pull credentials. It also needs `Microsoft.Authorization/roleAssignments/write` permission to create the RBAC assignments.

## Service Connection Permissions

The service connection identity needs:

```bash
# To create role assignments
az role assignment create \
  --assignee <pipeline-identity> \
  --role "User Access Administrator" \
  --scope /providers/Microsoft.Management/managementGroups/<mg-id>

# To access clusters
az role assignment create \
  --assignee <pipeline-identity> \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope /providers/Microsoft.Management/managementGroups/<mg-id>

# To deploy workloads (or use Azure RBAC Cluster Admin)
az role assignment create \
  --assignee <pipeline-identity> \
  --role "Azure Kubernetes Service RBAC Admin" \
  --scope /providers/Microsoft.Management/managementGroups/<mg-id>
```

Want me to add error handling, rollback logic, or a dry-run mode?