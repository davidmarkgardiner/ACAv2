```
                                                                                                                                                                    
  05-eventhub-eventsource.yaml (lines 40-57):                                                                                                                               
                                                                                                                                                                            
  azureEventsHub:                                                                                                                                                           
    k8s-warnings:                                                                                                                                                           
      # Event Hub FQDN                                                                                                                                                      
      fqdn: "k8s-events-hub-fb.servicebus.windows.net"                                                                                                                      
                                                                                                                                                                            
      # Event Hub name                                                                                                                                                      
      hubName: "kube-events"                                                                                                                                                
                                                                                                                                                                            
      # Consumer group                                                                                                                                                      
      consumerGroup: "$Default"                                                                                                                                             
                                                                                                                                                                            
      # Authentication via K8s secret                                                                                                                                       
      sharedAccessKeyName:                                                                                                                                                  
        name: eventhub-listener-secret                                                                                                                                      
        key: sharedAccessKeyName                                                                                                                                            
      sharedAccessKey:                                                                                                                                                      
        name: eventhub-listener-secret                                                                                                                                      
        key: sharedAccessKey                                                                                                                                                
                                                                                                                                                                            
  How It Works                                                                                                                                                              
                                                                                                                                                                            
  1. Argo Events EventSource uses the azureEventsHub type which is a built-in connector                                                                                     
  2. Connection details are in the EventSource spec:                                                                                                                        
    - fqdn: The Event Hub namespace FQDN                                                                                                                                    
    - hubName: The specific Event Hub within that namespace                                                                                                                 
    - consumerGroup: Which consumer group to use                                                                                                                            
  3. Authentication comes from a Kubernetes secret (eventhub-listener-secret) that must be created separately with the Shared Access Key                                    
                                                                                                                                                                            
  Required Secret Creation                                                                                                                                                  
                                                                                                                                                                            
  Before the EventSource can connect, you need to create the secret:                                                                                                        
                                                                                                                                                                            
  KEY_NAME="RootManageSharedAccessKey"                                                                                                                                      
  KEY_VALUE=$(az eventhubs namespace authorization-rule keys list \                                                                                                         
    --resource-group $RESOURCE_GROUP \                                                                                                                                      
    --namespace-name k8s-events-hub-fb \                                                                                                                                    
    --name $KEY_NAME --query primaryKey -o tsv)                                                                                                                             
                                                                                                                                                                            
  kubectl create secret generic eventhub-listener-secret \                                                                                                                  
    --namespace argo-events \                                                                                                                                               
    --from-literal=sharedAccessKeyName="$KEY_NAME" \                                                                                                                        
    --from-literal=sharedAccessKey="$KEY_VALUE"                                                                                                                             
                                                                                                                                                                            
  The EventSource pod will then connect to the Event Hub and listen for messages, forwarding them to the EventBus where Sensors can pick them up.       

  ```