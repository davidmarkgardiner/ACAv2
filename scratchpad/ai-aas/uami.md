
## The Core Argument

Both methods ultimately result in a token being presented to the LLM backend for authentication. The difference is **where the secret lives and who manages the token lifecycle**.

**Service Principal flow:**

1. A client secret (or certificate) is created and stored somewhere accessible to the workload — whether that's a Kubernetes secret, a Key Vault reference, or injected via EVA
2. The application uses that secret to authenticate to Entra ID and obtain a JWT
3. That JWT is presented to the backend service

The problems here are real and compound at scale. The secret is a long-lived credential that has to be rotated, stored, and protected. Anyone or anything that can read that secret can authenticate as your workload from anywhere. You also pick up a dependency on EVA for secret injection, which adds operational complexity and is another moving part that can break. In a multi-tenant AKS environment running at scale, you're now managing secret rotation, EVA availability, and the blast radius of a leaked credential across potentially many workloads.

**User-Assigned Managed Identity (UAMI) flow:**

1. The UAMI is assigned to the workload via Azure Workload Identity (federated credential bound to a Kubernetes service account)
2. The Azure identity platform issues a token directly to the pod via the OIDC token exchange
3. That JWT is presented to the backend service

No secret is ever created, stored, rotated, or exposed. The token is short-lived, automatically managed, and scoped to the specific workload identity. There is nothing to leak. An attacker who compromises the pod can use the token for its remaining lifetime, but they can't extract a long-lived credential and use it from outside the cluster.

## Why This Matters at Scale

When you're running one or two workloads, the operational overhead of a service principal is manageable. When you're running this across a production platform with many consumers, every service principal becomes a secret you have to lifecycle, an EVA dependency you have to maintain, and a credential that could be exfiltrated. UAMI with Workload Identity eliminates that entire class of risk and operational burden.

## The "Service vs Application" Point

Whether the backend is classified as a service or an application in Entra ID doesn't change how the **calling workload** should authenticate. The UAMI presents a valid Entra ID token just like a service principal does — the backend doesn't need to care which method the caller used to obtain it, only that the token is valid and has the correct claims. If the backend requires a specific app registration or role assignment, a UAMI can be granted those same roles and permissions.

## Summary

The ask is straightforward: let us authenticate using UAMI with Azure Workload Identity. It provides the same token-based authentication the backend expects, but eliminates secret management, removes the EVA dependency, reduces blast radius, and aligns with Microsoft's own recommended practice for workloads running on AKS. We can make the service principal work if it's truly the only option, but it introduces unnecessary risk and operational overhead that will only grow as we scale to production.

---

Microsoft's own guidance explicitly recommends Managed Identities over service principals for Azure workloads, and Workload Identity federation is the supported pattern for AKS. The "it's a service not an app" argument doesn't hold up because the authentication method of the caller is independent of how the target resource is registered. The token that lands at their door looks the same either way.