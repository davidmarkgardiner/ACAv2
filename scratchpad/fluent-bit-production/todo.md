  To deploy at work:                                      
  1. Set environment variables (RESOURCE_GROUP,           
  CLUSTER_NAME, LOCATION)                                 
  2. Run ./00-setup-workload-identity.sh                  
  3. Update 02-fluent-bit-deployment.yaml with Client ID  
  and Tenant ID from script output                        
  4. Update 03-eventsource-workload-identity.yaml with    
  Event Hub FQDN                                          
  5. Update 04-sensor-production.yaml with your GitLab    
  project path                                            
  6. Apply manifests in order: 01, 02, 03, then 04   