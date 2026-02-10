Here's a quick approach using Azure CLI to dump and diff the NSG rules:

```bash
# Export NSGs from both subscriptions
az network nsg list --subscription "working-sub" -o json | jq '[.[] | {name, location, rules: .securityRules | sort_by(.priority)}]' > nsg-working.json

az network nsg list --subscription "broken-sub" -o json | jq '[.[] | {name, location, rules: .securityRules | sort_by(.priority)}]' > nsg-broken.json

# Diff them
diff <(jq -S . nsg-working.json) <(jq -S . nsg-broken.json)
```

If you want a more targeted view focusing just on the AKS-related NSGs (which typically follow the `aks-agentpool-*` naming pattern):

```bash
# Filter to AKS node resource group NSGs
az network nsg list --subscription "working-sub" -g "MC_myRG_myCluster_uksouth" -o json | \
  jq '[.[] | {name, rules: [.securityRules[] | {name, priority, direction, access, protocol, sourceAddressPrefix, destinationAddressPrefix, destinationPortRange}]}]' > nsg-working.json

az network nsg list --subscription "broken-sub" -g "MC_myRG_myCluster_uksouth" -o json | \
  jq '[.[] | {name, rules: [.securityRules[] | {name, priority, direction, access, protocol, sourceAddressPrefix, destinationAddressPrefix, destinationPortRange}]}]' > nsg-broken.json

diff --color -u nsg-working.json nsg-broken.json
```

For **subnet-level** NSG associations too:

```bash
# Show subnet -> NSG mappings per VNet
for SUB in "working-sub" "broken-sub"; do
  echo "=== $SUB ==="
  az network vnet list --subscription "$SUB" -o json | \
    jq -r '.[] | .subnets[] | "\(.name) -> \(.networkSecurityGroup.id // "NONE")"'
done
```

**Things to look for in the diff:**

- Missing inbound allow rules for LoadBalancer or AzureLoadBalancer service tag
- Blocked ports 443, 10250 (kubelet), 9000 (tunnel) between node subnets
- Differences in outbound rules — AKS needs egress to `AzureCloud`, `AzureContainerRegistry`, `MicrosoftContainerRegistry`
- If using Istio, check for missing allows on 15017 (istiod webhook), 15012 (xDS), and 15021 (health)
- Subnet delegation differences or missing route table associations

If the "not working" cluster is specifically failing on Istio ingress/east-west traffic, the issue might not be NSG at all but rather the subnet's route table or a missing UDR for the internal load balancer subnet. Worth checking `az network route-table list` in both subs too.