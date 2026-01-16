The secret eventhub-listener-secret was referenced but never created. Now fixed with:                                                                              
                                                                                                                                                                     
  New file: 03a-mgmt-cluster-external-secret.yaml                                                                                                                    
  - ExternalSecret that syncs credentials from Key Vault to the management cluster                                                                                   
                                                                                                                                                                     
  Two options to create the secret:                                                                                                                                  
                                                                                                                                                                     
  Option A: External Secrets (if ESO is installed on mgmt cluster)                                                                                                   
  # Store in Key Vault first                                                                                                                                         
  KEY_NAME="RootManageSharedAccessKey"                                                                                                                               
  KEY_VALUE=$(az eventhubs namespace authorization-rule keys list \                                                                                                  
    --resource-group $RESOURCE_GROUP \                                                                                                                               
    --namespace-name $EVENTHUB_NAMESPACE \                                                                                                                           
    --name $KEY_NAME --query primaryKey -o tsv)                                                                                                                      
                                                                                                                                                                     
  az keyvault secret set --vault-name $KEY_VAULT --name eventhub-shared-access-key-name --value "$KEY_NAME"                                                          
  az keyvault secret set --vault-name $KEY_VAULT --name eventhub-shared-access-key --value "$KEY_VALUE"                                                              
                                                                                                                                                                     
  # Apply ExternalSecret                                                                                                                                             
  kubectl apply -f 03a-mgmt-cluster-external-secret.yaml                                                                                                             
                                                                                                                                                                     
  Option B: Manual secret (simpler)                                                                                                                                  
  KEY_NAME="RootManageSharedAccessKey"                                                                                                                               
  KEY_VALUE=$(az eventhubs namespace authorization-rule keys list \                                                                                                  
    --resource-group $RESOURCE_GROUP \                                                                                                                               
    --namespace-name $EVENTHUB_NAMESPACE \                                                                                                                           
    --name $KEY_NAME --query primaryKey -o tsv)                                                                                                                      
                                                                                                                                                                     
  kubectl create secret generic eventhub-listener-secret \                                                                                                           
    --namespace argo-events \                                                                                                                                        
    --from-literal=sharedAccessKeyName="$KEY_NAME" \                                                                                                                 
    --from-literal=sharedAccessKey="$KEY_VALUE"                                                                                                                      
                                                                                                                                                                     
  Updated files:                                                                                                                                                     
  - 03-eventsource-workload-identity.yaml - Added prerequisite comments                                                                                              
  - todo.md - Added step 7 for secret creation                                                                                                                       
  - README.md - Updated file reference table                                                                                                                         
                                                                                                                                                                     
✻ Sautéed for 2m 1s                                                                                                                                                  
                                                                                                                                                                     
❯ So the event source triggers the sensor, which then triggers the workflow, right?                                                                                  
  ⎿  ⧉ Selected 1 lines from application-stack/apps/holmesgpt/multi-cluster/fluent-bit-production/04-sensor-production.yaml in Visual Studio Code                    
                                                                                                                                                                     
⏺ Yes, exactly. The flow is:                                                                                                                                         
                                                                                                                                                                     
  Event Hub → EventSource → Sensor → Workflow                                                                                                                        
                                                                                                                                                                     
  Let me show you how they connect:                                                                                                                                  
                                                                                                                                                                     
⏺ Read(application-stack/apps/holmesgpt/multi-cluster/fluent-bit-production/04-sensor-production.yaml)                                                               
  ⎿  Read 70 lines                                                                                                                                                   
                                                                                                                                                                     
⏺ Here's how they connect:                                                                                                                                           
                                                                                                                                                                     
  ┌─────────────────────────────────────────────────────────────────────────┐                                                                                        
  │                              FLOW                                        │                                                                                       
  ├─────────────────────────────────────────────────────────────────────────┤                                                                                        
  │                                                                          │                                                                                       
  │  1. EVENT HUB                                                            │                                                                                       
  │     └── Receives K8s events from Fluent Bit                             │                                                                                        
  │                    │                                                     │                                                                                       
  │                    ▼                                                     │                                                                                       
  │  2. EVENTSOURCE (eventhub-k8s-events)                                   │                                                                                        
  │     └── Consumes from Event Hub                                          │                                                                                       
  │     └── Publishes to EventBus as event: "k8s-warnings"                  │                                                                                        
  │                    │                                                     │                                                                                       
  │                    ▼                                                     │                                                                                       
  │  3. SENSOR (fluent-bit-gitlab-issues)                                   │                                                                                        
  │     └── dependencies:                                                    │                                                                                       
  │           eventSourceName: eventhub-k8s-events  ◄── links to EventSource│                                                                                        
  │           eventName: k8s-warnings               ◄── the event name      │                                                                                        
  │     └── triggers:                                                        │                                                                                       
  │           argoWorkflow:                                                  │                                                                                       
  │             workflowTemplateRef: multi-cluster-triage                   │                                                                                        
  │                    │                                                     │                                                                                       
  │                    ▼                                                     │                                                                                       
  │  4. WORKFLOW (multi-cluster-triage)                                     │                                                                                        
  │     └── Runs HolmesGPT investigation                                    │                                                                                        
  │     └── Creates GitLab issue                                            │                                                                                        
  │                                                                          │                                                                                       
  └─────────────────────────────────────────────────────────────────────────┘                                                                                        
                                                                                                                                                                     
  The key linkages:                                                                                                                                                  
  ┌─────────────┬─────────────┬───────────────────────────────────────────┐                                                                                          
  │  Component  │  Links To   │                    Via                    │                                                                                          
  ├─────────────┼─────────────┼───────────────────────────────────────────┤                                                                                          
  │ EventSource │ Event Hub   │ fqdn, hubName, consumerGroup              │                                                                                          
  ├─────────────┼─────────────┼───────────────────────────────────────────┤                                                                                          
  │ Sensor      │ EventSource │ eventSourceName: eventhub-k8s-events      │                                                                                          
  ├─────────────┼─────────────┼───────────────────────────────────────────┤                                                                                          
  │ Sensor      │ Workflow    │ workflowTemplateRef: multi-cluster-triage │                                                                                          
  └─────────────┴─────────────┴───────────────────────────────────────────┘                                                                                          
  The Sensor extracts data from the event and passes it to the Workflow:                                                                                             
  parameters:                                                                                                                                                        
    - src:                                                                                                                                                           
        dependencyName: k8s-warning-event                                                                                                                            
        dataTemplate: '{{ (b64dec .Input.body) | dig "cluster" "unknown" }}'                                                                                         
      dest: spec.arguments.parameters.0.value  # → cluster-name                                                                                                      
                                                                                                                                                                     
  This decodes the base64 Event Hub payload and maps fields like cluster, reason, namespace to workflow parameters.                                                  
                                                                                                                                                                     
❯ so where is template?                                                                                                                                              
  ⎿  ⧉ Selected 1 lines from application-stack/apps/holmesgpt/multi-cluster/fluent-bit-production/04-sensor-production.yaml in Visual Studio Code                    
                                                                                                                                                                     
⏺ The workflowTemplateRef: multi-cluster-triage references a WorkflowTemplate in the parent folder:                                                                  
                                                                                                                                                                     
  application-stack/apps/holmesgpt/multi-cluster/                                                                                                                    
  ├── fluent-bit-production/                                                                                                                                         
  │   ├── 04-sensor-production.yaml      ← Sensor (references template)                                                                                              
  │   └── ...                                                                                                                                                        
  └── workflow-multi-cluster-triage.yaml  ← The WorkflowTemplate lives HERE                                                                                          
                                                                                                                                                                     
⏺ Read(application-stack/apps/holmesgpt/multi-cluster/workflow-multi-cluster-triage.yaml)                                                                            
  ⎿  Read 332 lines                                                                                                                                                  
                                                                                                                                                                     
⏺ The WorkflowTemplate is at:                                                                                                                                        
  ../workflow-multi-cluster-triage.yaml                                                                                                                              
                                                                                                                                                                     
  (One level up from fluent-bit-production/)                                                                                                                         
                                                                                                                                                                     
  The workflow has 3 steps (DAG):                                                                                                                                    
                                                                                                                                                                     
  ┌─────────────────────┐                                                                                                                                            
  │  1. investigate     │  ← Calls HolmesGPT API                                                                                                                     
  │     (holmes-        │                                                                                                                                            
  │      investigate)   │                                                                                                                                            
  └─────────┬───────────┘                                                                                                                                            
            │                                                                                                                                                        
            ▼                                                                                                                                                        
  ┌─────────────────────┐                                                                                                                                            
  │  2. create-issue    │  ← Creates GitLab issue with AI analysis                                                                                                   
  │     (create-gitlab- │                                                                                                                                            
  │      issue)         │                                                                                                                                            
  └─────────┬───────────┘                                                                                                                                            
            │                                                                                                                                                        
            ▼                                                                                                                                                        
  ┌─────────────────────┐                                                                                                                                            
  │  3. notify-         │  ← Sends RocketChat notification                                                                                                           
  │     completion      │                                                                                                                                            
  │     (notify-        │                                                                                                                                            
  │      rocketchat-    │                                                                                                                                            
  │      completion)    │                                                                                                                                            
  └─────────────────────┘                                                                                                                                            
                                                                                                                                                                     
  Why it's in the parent folder: It's a shared template used by multiple setups:                                                                                     
  - fluent-bit-production/04-sensor-production.yaml                                                                                                                  
  - fluent-bit-local/04-sensor-gitlab.yaml                                                                                                                           
  - etc.                                                                                                                                                             
                                                                                                                                                                     
  To deploy it:                                                                                                                                                      
  kubectl apply -f ../workflow-multi-cluster-triage.yaml                                                                                                             
                                                                                                                                                                     
  Prerequisites the template needs:                                                                                                                                  
  1. gitlab-mcp-secret - GitLab PAT for creating issues                                                                                                              
  2. rocketchat-webhook-config - ConfigMap with webhook URL (optional)                                                                                               
  3. HolmesGPT running at http://holmesgpt.holmesgpt.svc.cluster.local         