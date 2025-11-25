  Issue: Need GPU quota (Standard NCADSA10v4 Family vCPUs) across multiple subscriptions

  Quick Check (per subscription):
  az vm list-usage --location westeurope --output table | grep "NCADSA10v4"

  VM Details:
  - SKU: Standard_NC24ads_A100_v4
  - vCPUs per node: 24
  - GPU: 1x NVIDIA A100 (80GB)

  Quota Request:
  - Portal: Azure Portal → Subscriptions → Usage + quotas → "Standard NCADSA10v4 Family vCPUs"
  - Suggested per subscription: 48 vCPUs (2 nodes) or 96 vCPUs (4 nodes)

  Blocker: Authorization required for quota requests - escalate to subscription owner/admin.