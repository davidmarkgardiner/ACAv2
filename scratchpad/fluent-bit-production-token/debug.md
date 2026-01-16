NS=argo-events                                                                                                                                                     
```                                                                                                                                             
  # 1. Check EventBus exists (MOST COMMON ISSUE!)                                                                                                                    
  kubectl get eventbus -n $NS                                                                                                                                        
  # Should show: default   Running                                                                                                                                   
                                                                                                                                                                     
  # 2. Check all components                                                                                                                                          
  kubectl get eventbus,eventsource,sensor,workflowtemplate -n $NS                                                                                                    
                                                                                                                                                                     
  # 3. Check pods are running                                                                                                                                        
  kubectl get pods -n $NS                                                                                                                                            
                                                                                                                                                                     
  # 4. Check RBAC                                                                                                                                                    
  kubectl auth can-i create workflows --as=system:serviceaccount:$NS:argo-events-sa -n $NS                                                                           
  # Should return: yes                                                                                                                                               
                                                                                                                                                                     
  # 5. Check secret exists                                                                                                                                           
  kubectl get secret eventhub-listener-secret -n $NS                                                                                                                 
                                                                                                                                                                     
  # 6. Check EventSource logs (is it receiving from Event Hub?)                                                                                                      
  kubectl logs -n $NS -l eventsource-name=eventhub-k8s-events --tail=50                                                                                              
                                                                                                                                                                     
  # 7. Check Sensor logs (is it triggering workflows?)                                                                                                               
  kubectl logs -n $NS -l sensor-name=fluent-bit-gitlab-issues --tail=50                                                                                              
                                                                                                                                                                     
  # 8. Look for errors                                                                                                                                               
  kubectl logs -n $NS -l eventsource-name=eventhub-k8s-events --tail=100 | grep -i error                                                                             
  kubectl logs -n $NS -l sensor-name=fluent-bit-gitlab-issues --tail=100 | grep -i error                                                                             
                                                                                                                                                                     
  3. Correct Deployment Order                                                                                                                                        
                                                                                                                                                                     
  # 1. RBAC + EventBus (MUST BE FIRST!)                                                                                                                              
  kubectl apply -f 02a-mgmt-cluster-rbac.yaml                                                                                                                        
                                                                                                                                                                     
  # 2. Secret                                                                                                                                                        
  kubectl create secret generic eventhub-listener-secret \                                                                                                           
    --namespace argo-events \                                                                                                                                        
    --from-literal=sharedAccessKeyName="RootManageSharedAccessKey" \                                                                                                 
    --from-literal=sharedAccessKey="<your-key>"                                                                                                                      
                                                                                                                                                                     
  # 3. WorkflowTemplate                                                                                                                                              
  kubectl apply -f ../workflow-multi-cluster-triage.yaml                                                                                                             
                                                                                                                                                                     
  # 4. EventSource                                                                                                                                                   
  kubectl apply -f 03-eventsource-workload-identity.yaml                                                                                                             
                                                                                                                                                                     
  # 5. Sensor                                                                                                                                                        
  kubectl apply -f 04-sensor-production.yaml                                                                                                                         
                                                                                                                                                                     
  Most Likely Issues                                                                                                                                                 
  ┌──────────────────────────────┬────────────────────────┬────────────────────────────────────────────────────────┐                                                 
  │           Symptom            │         Cause          │                          Fix                           │                                                 
  ├──────────────────────────────┼────────────────────────┼────────────────────────────────────────────────────────┤                                                 
  │ No workflows at all          │ EventBus missing       │ kubectl apply -f 02a-mgmt-cluster-rbac.yaml            │                                                 
  ├──────────────────────────────┼────────────────────────┼────────────────────────────────────────────────────────┤                                                 
  │ "forbidden" in sensor logs   │ RBAC missing           │ kubectl apply -f 02a-mgmt-cluster-rbac.yaml            │                                                 
  ├──────────────────────────────┼────────────────────────┼────────────────────────────────────────────────────────┤                                                 
  │ "workflowtemplate not found" │ Template missing       │ kubectl apply -f ../workflow-multi-cluster-triage.yaml │                                                 
  ├──────────────────────────────┼────────────────────────┼────────────────────────────────────────────────────────┤                                                 
  │ "authentication failed"      │ Secret wrong           │ Recreate secret with correct keys                      │                                                 
  ├──────────────────────────────┼────────────────────────┼────────────────────────────────────────────────────────┤                                                 
  │ EventSource not receiving    │ Consumer group missing │ Create in Azure                                        │                                                 
  └──────────────────────────────┴────────────────────────┴────────────────────────────────────────────────────────┘                                                 
  Full troubleshooting guide: TROUBLESHOOTING.md                    