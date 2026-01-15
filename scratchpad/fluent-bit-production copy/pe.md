 How Private Endpoints Work                                                                                                                                                         
                                                                                                                                                                                     
                                      ┌─────────────────────────────────┐                                                                                                            
                                      │     Private DNS Zone            │                                                                                                            
                                      │ privatelink.servicebus.windows.net │                                                                                                         
                                      │                                 │                                                                                                            
                                      │ k8s-events-hub.servicebus...    │                                                                                                            
                                      │     → 10.0.1.4 (private IP)     │                                                                                                            
                                      └───────────────┬─────────────────┘                                                                                                            
                                                      │ DNS lookup                                                                                                                   
      ┌───────────────────┐                          │                                                                                                                               
      │   AKS Cluster     │                          │                                                                                                                               
      │   (VNet A)        │          ┌───────────────▼─────────────────┐                                                                                                             
      │                   │          │         VNet (peered)            │                                                                                                            
      │  ┌─────────────┐  │          │                                  │                                                                                                            
      │  │ Fluent Bit  │──┼──────────┼──► Private Endpoint (10.0.1.4)  │                                                                                                             
      │  │             │  │          │           │                      │                                                                                                            
      │  └─────────────┘  │          │           ▼                      │                                                                                                            
      │                   │          │    ┌─────────────────┐           │                                                                                                            
      └───────────────────┘          │    │  Event Hub      │           │                                                                                                            
                                     │    │  (no public IP) │           │                                                                                                            
                                     │    └─────────────────┘           │                                                                                                            
                                     └──────────────────────────────────┘                                                                                                            
                                                                                                                                                                                     
  What You Need to Connect                                                                                                                                                           
                                                                                                                                                                                     
  1. Private DNS Zone Linked to AKS VNet                                                                                                                                             
                                                                                                                                                                                     
  The Private DNS Zone privatelink.servicebus.windows.net must be linked to your AKS cluster's VNet:                                                                                 
                                                                                                                                                                                     
  # Check if Private DNS Zone exists                                                                                                                                                 
  az network private-dns zone list -o table                                                                                                                                          
                                                                                                                                                                                     
  # Get AKS VNet ID                                                                                                                                                                  
  AKS_VNET_ID=$(az aks show -g $RG -n $AKS_CLUSTER \                                                                                                                                 
    --query "networkProfile.vnetId" -o tsv)                                                                                                                                          
                                                                                                                                                                                     
  # If AKS uses a managed VNet, get it from node resource group                                                                                                                      
  AKS_NODE_RG=$(az aks show -g $RG -n $AKS_CLUSTER --query nodeResourceGroup -o tsv)                                                                                                 
  AKS_VNET_ID=$(az network vnet list -g $AKS_NODE_RG --query "[0].id" -o tsv)                                                                                                        
                                                                                                                                                                                     
  # Link Private DNS Zone to AKS VNet                                                                                                                                                
  az network private-dns link vnet create \                                                                                                                                          
    --resource-group $EVENTHUB_RG \                                                                                                                                                  
    --zone-name "privatelink.servicebus.windows.net" \                                                                                                                               
    --name "link-to-aks-vnet" \                                                                                                                                                      
    --virtual-network $AKS_VNET_ID \                                                                                                                                                 
    --registration-enabled false                                                                                                                                                     
                                                                                                                                                                                     
  2. Verify DNS Resolution from AKS                                                                                                                                                  
                                                                                                                                                                                     
  Test that pods can resolve the Event Hub to the private IP:                                                                                                                        
                                                                                                                                                                                     
  # Run a test pod                                                                                                                                                                   
  kubectl run dns-test --rm -it --image=busybox --restart=Never -- nslookup k8s-events-hub.servicebus.windows.net                                                                    
                                                                                                                                                                                     
  # Expected output (private IP):                                                                                                                                                    
  # Name:      k8s-events-hub.servicebus.windows.net                                                                                                                                 
  # Address 1: 10.0.1.4  ← Private IP, not public!                                                                                                                                   
                                                                                                                                                                                     
  3. Network Connectivity (VNet Peering if needed)                                                                                                                                   
                                                                                                                                                                                     
  If AKS is in a different VNet than the Private Endpoint:                                                                                                                           
                                                                                                                                                                                     
  # Peer AKS VNet to Event Hub VNet                                                                                                                                                  
  az network vnet peering create \                                                                                                                                                   
    --name aks-to-eventhub \                                                                                                                                                         
    --resource-group $AKS_RG \                                                                                                                                                       
    --vnet-name $AKS_VNET \                                                                                                                                                          
    --remote-vnet $EVENTHUB_VNET_ID \                                                                                                                                                
    --allow-vnet-access                                                                                                                                                              
                                                                                                                                                                                     
  # Peer the other direction                                                                                                                                                         
  az network vnet peering create \                                                                                                                                                   
    --name eventhub-to-aks \                                                                                                                                                         
    --resource-group $EVENTHUB_RG \                                                                                                                                                  
    --vnet-name $EVENTHUB_VNET \                                                                                                                                                     
    --remote-vnet $AKS_VNET_ID \                                                                                                                                                     
    --allow-vnet-access                                                                                                                                                              
                                                                                                                                                                                     
  Fluent Bit Configuration                                                                                                                                                           
                                                                                                                                                                                     
  No changes needed! Fluent Bit uses the same FQDN - DNS just resolves to private IP:                                                                                                
                                                                                                                                                                                     
  # Same config works for both public and private endpoints                                                                                                                          
  [OUTPUT]                                                                                                                                                                           
      Name                          kafka                                                                                                                                            
      Brokers                       ${EVENTHUB_FQDN}:9093   # Same FQDN                                                                                                              
      # DNS resolves to private IP automatically                                                                                                                                     
                                                                                                                                                                                     
  Checklist                                                                                                                                                                          
  ┌──────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────┐                                                          
  │               Step               │                                    Verification                                    │                                                          
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────┤                                                          
  │ Private Endpoint exists          │ az network private-endpoint list -g $RG -o table                                   │                                                          
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────┤                                                          
  │ Private DNS Zone exists          │ az network private-dns zone show -g $RG -n privatelink.servicebus.windows.net      │                                                          
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────┤                                                          
  │ DNS Zone linked to AKS VNet      │ az network private-dns link vnet list -g $RG -z privatelink.servicebus.windows.net │                                                          
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────┤                                                          
  │ DNS resolves to private IP       │ kubectl run dns-test --rm -it --image=busybox -- nslookup $EVENTHUB_FQDN           │                                                          
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────┤                                                          
  │ Network path exists              │ VNet peering if AKS and PE are in different VNets                                  │                                                          
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────┤                                                          
  │ Event Hub public access disabled │ Optional but recommended for security                                              │                                                          
  └──────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────┘                                                          
  Quick Diagnostic                                                                                                                                                                   
                                                                                                                                                                                     
  # From inside AKS, test connectivity                                                                                                                                               
  kubectl run nettest --rm -it --image=nicolaka/netshoot --restart=Never -- bash                                                                                                     
                                                                                                                                                                                     
  # Inside the pod:                                                                                                                                                                  
  nslookup k8s-events-hub.servicebus.windows.net                                                                                                                                     
  nc -zv k8s-events-hub.servicebus.windows.net 9093                                                                                                                                  
                                                                                                                                                                                     
  What's your current state? Do you have:                                                                                                                                            
  1. The Private DNS Zone created?                                                                                                                                                   
  2. Is it linked to the AKS VNet?                                                                                                                                                   
                                                                                                                                                                                     
✻ Churned for 43s                                                                                                                                                                    
                                                                                                                                                                                     
❯ https://learn.microsoft.com/en-us/cli/azure/eventhubs/namespace/private-endpoint-connection?view=azure-cli-latest                                                                  
                                                                                                                                                                                     
⏺ Fetch(https://learn.microsoft.com/en-us/cli/azure/eventhubs/namespace/private-endpoint-connection?view=azure-cli-latest)                                                           
  ⎿  Received 127.6KB (200 OK)                                                                                                                                                       
                                                                                                                                                                                     
⏺ Got it. These commands manage the connection from the Event Hub side. Here's how to check and approve your private endpoint connection:                                            
                                                                                                                                                                                     
  Check Current Status                                                                                                                                                               
                                                                                                                                                                                     
  # Set your variables                                                                                                                                                               
  export EVENTHUB_NAMESPACE="your-eventhub-namespace"                                                                                                                                
  export RESOURCE_GROUP="your-rg"                                                                                                                                                    
                                                                                                                                                                                     
  # List all private endpoint connections                                                                                                                                            
  az eventhubs namespace private-endpoint-connection list \                                                                                                                          
    --namespace-name $EVENTHUB_NAMESPACE \                                                                                                                                           
    --resource-group $RESOURCE_GROUP \                                                                                                                                               
    -o table                                                                                                                                                                         
                                                                                                                                                                                     
  You'll see output like:                                                                                                                                                            
                                                                                                                                                                                     
  Name                                                  ProvisioningState    Status                                                                                                  
  ----------------------------------------------------  -------------------  --------                                                                                                
  your-namespace.abc123-456-789                         Succeeded            Pending   ← Needs approval!                                                                             
                                                                                                                                                                                     
  Approve the Connection                                                                                                                                                             
                                                                                                                                                                                     
  If status is Pending, approve it:                                                                                                                                                  
                                                                                                                                                                                     
  # Get the connection name from the list output                                                                                                                                     
  export CONNECTION_NAME="your-namespace.abc123-456-789"                                                                                                                             
                                                                                                                                                                                     
  # Approve the connection                                                                                                                                                           
  az eventhubs namespace private-endpoint-connection approve \                                                                                                                       
    --resource-group $RESOURCE_GROUP \                                                                                                                                               
    --namespace-name $EVENTHUB_NAMESPACE \                                                                                                                                           
    --name $CONNECTION_NAME \                                                                                                                                                        
    --description "Approved for AKS Fluent Bit integration"                                                                                                                          
                                                                                                                                                                                     
  Or approve by full resource ID:                                                                                                                                                    
                                                                                                                                                                                     
  # Get the connection ID                                                                                                                                                            
  CONNECTION_ID=$(az eventhubs namespace private-endpoint-connection list \                                                                                                          
    --namespace-name $EVENTHUB_NAMESPACE \                                                                                                                                           
    --resource-group $RESOURCE_GROUP \                                                                                                                                               
    --query "[0].id" -o tsv)                                                                                                                                                         
                                                                                                                                                                                     
  # Approve by ID                                                                                                                                                                    
  az eventhubs namespace private-endpoint-connection approve --id $CONNECTION_ID                                                                                                     
                                                                                                                                                                                     
  Verify Approved Status                                                                                                                                                             
                                                                                                                                                                                     
  az eventhubs namespace private-endpoint-connection show \                                                                                                                          
    --resource-group $RESOURCE_GROUP \                                                                                                                                               
    --namespace-name $EVENTHUB_NAMESPACE \                                                                                                                                           
    --name $CONNECTION_NAME \                                                                                                                                                        
    --query "{name:name, status:privateLinkServiceConnectionState.status, description:privateLinkServiceConnectionState.description}" \                                              
    -o table                                                                                                                                                                         
                                                                                                                                                                                     
  Expected output:                                                                                                                                                                   
  Name                                    Status     Description                                                                                                                     
  --------------------------------------  ---------  ---------------------------------                                                                                               
  your-namespace.abc123-456-789           Approved   Approved for AKS Fluent Bit...                                                                                                  
                                                                                                                                                                                     
  Full Connection Flow                                                                                                                                                               
                                                                                                                                                                                     
  1. Private Endpoint Created          2. Connection Appears on Event Hub    3. Approve Connection                                                                                   
     (in your VNet)                       (Status: Pending)                     (Status: Approved)                                                                                   
          │                                      │                                    │                                                                                              
          ▼                                      ▼                                    ▼                                                                                              
  ┌──────────────────┐                 ┌──────────────────┐                 ┌──────────────────┐                                                                                     
  │ az network       │                 │ az eventhubs     │                 │ az eventhubs     │                                                                                     
  │ private-endpoint │ ───────────────►│ namespace        │ ───────────────►│ namespace        │                                                                                     
  │ create           │                 │ private-endpoint │                 │ private-endpoint │                                                                                     
  │                  │                 │ -connection list │                 │ -connection      │                                                                                     
  └──────────────────┘                 └──────────────────┘                 │ approve          │                                                                                     
                                                                            └──────────────────┘                                                                                     
                                                                                                                                                                                     
  Quick Diagnostic Script                                                                                                                                                            
                                                                                                                                                                                     
  #!/bin/bash                                                                                                                                                                        
  # diagnose-private-endpoint.sh                                                                                                                                                     
                                                                                                                                                                                     
  EVENTHUB_NAMESPACE="${1:-your-namespace}"                                                                                                                                          
  RESOURCE_GROUP="${2:-your-rg}"                                                                                                                                                     
                                                                                                                                                                                     
  echo "=== Private Endpoint Connections ==="                                                                                                                                        
  az eventhubs namespace private-endpoint-connection list \                                                                                                                          
    --namespace-name $EVENTHUB_NAMESPACE \                                                                                                                                           
    --resource-group $RESOURCE_GROUP \                                                                                                                                               
    -o table                                                                                                                                                                         
                                                                                                                                                                                     
  echo ""                                                                                                                                                                            
  echo "=== Event Hub Network Rules ==="                                                                                                                                             
  az eventhubs namespace show \                                                                                                                                                      
    --name $EVENTHUB_NAMESPACE \                                                                                                                                                     
    --resource-group $RESOURCE_GROUP \                                                                                                                                               
    --query "{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSets.defaultAction}" \                                                                               
    -o table                                                                                                                                                                         
                                                                                                                                                                                     
  What does your private-endpoint-connection list show? Is the status Pending or Approved?                                                                                           
                                                                                                   