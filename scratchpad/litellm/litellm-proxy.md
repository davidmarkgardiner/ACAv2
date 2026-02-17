# LiteLLM Proxy

HolmesGPT includes LiteLLM as a built-in library for LLM provider support. For production and enterprise deployments, you can run an **external LiteLLM Proxy server** as a gateway between Holmes and your LLM providers to gain centralized management, monitoring, and cloud-native authentication.

## Why Use an External Proxy

**Cloud-native authentication (Workload Identity)**

The proxy handles token exchange for Azure Managed Identity, GCP Workload Identity, and AWS IAM Roles for Service Accounts. Holmes connects to the proxy without any API keys — no more managing secrets per deployment.

**Cost tracking and budgets**

Per-team, per-user, and per-model cost breakdowns. Set spending limits and get alerts. Essential when running multiple Holmes instances across clusters.

**Rate limiting and queuing**

Set RPM/TPM limits per model or per consumer. Requests are queued during spikes instead of returning 429 errors. Critical when sharing model access with other services.

**Model fallback and load balancing**

Automatically retry on a different deployment or provider when the primary fails. Load balance across multiple Azure OpenAI deployments to exceed a single deployment's TPM quota.

**Centralized key management**

API keys live only in the proxy. Create virtual keys for each consumer. Rotate provider keys in one place without updating every Holmes deployment.

**Caching**

Cache identical LLM requests to reduce costs and latency. Useful when multiple Holmes instances investigate similar issues.

**Shared gateway for multiple consumers**

If you run Holmes alongside other LLM-powered tools, one proxy provides unified governance, logging, and cost attribution across all of them.

**Audit logging**

Centralized log of every LLM request and response for compliance in regulated environments.

**Guardrails and hooks**

Pre/post-processing hooks for PII redaction, content filtering, or custom validation before requests reach the LLM provider.

## When to Use It

| Scenario | Built-in LiteLLM | External Proxy |
|----------|-------------------|----------------|
| Single Holmes instance, simple setup | Good | Overkill |
| Multiple Holmes instances across clusters | Works | Recommended |
| Need Workload Identity (no API keys) | Not supported | Required |
| Cost tracking and budgets | Not available | Built-in |
| Load balancing across deployments | Not available | Built-in |
| Sharing LLM access with other tools | N/A | Recommended |
| Compliance / audit logging | Not available | Built-in |

## Configuration

Deploy the LiteLLM Proxy server, then point Holmes at it using the [OpenAI-Compatible](openai-compatible.md) provider configuration.

### Step 1: Deploy LiteLLM Proxy

See the [LiteLLM Proxy documentation](https://docs.litellm.ai/docs/proxy/quick_start){:target="_blank"} for deployment options (Docker, Kubernetes Helm chart, etc.).

Example `litellm_config.yaml`:

```yaml
model_list:
  - model_name: "gpt-4.1"
    litellm_params:
      model: azure/gpt-4.1
      api_base: https://your-resource.openai.azure.com/
      api_version: "2025-01-01-preview"
      api_key: os.environ/AZURE_API_KEY

  - model_name: "gpt-4.1"
    litellm_params:
      # Second deployment for load balancing
      model: azure/gpt-4.1
      api_base: https://your-resource-2.openai.azure.com/
      api_version: "2025-01-01-preview"
      api_key: os.environ/AZURE_API_KEY_2

  - model_name: "claude-sonnet"
    litellm_params:
      model: anthropic/claude-sonnet-4-5-20250929
      api_key: os.environ/ANTHROPIC_API_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

### Step 2: Configure Holmes

Point Holmes at the proxy using the OpenAI-compatible endpoint format:

=== "Holmes CLI"

    ```bash
    export OPENAI_API_BASE="http://litellm-proxy:4000/v1"
    export OPENAI_API_KEY="your-litellm-virtual-key"

    holmes ask "what pods are failing?" --model="openai/gpt-4.1"
    ```

=== "Holmes Helm Chart"

    ```yaml
    # values.yaml
    additionalEnvVars:
      - name: OPENAI_API_BASE
        value: "http://litellm-proxy.litellm.svc.cluster.local:4000/v1"
      - name: OPENAI_API_KEY
        valueFrom:
          secretKeyRef:
            name: holmes-secrets
            key: litellm-api-key

    modelList:
      gpt-41:
        api_key: "{{ env.OPENAI_API_KEY }}"
        api_base: "{{ env.OPENAI_API_BASE }}"
        model: openai/gpt-4.1
        temperature: 0

      claude-sonnet:
        api_key: "{{ env.OPENAI_API_KEY }}"
        api_base: "{{ env.OPENAI_API_BASE }}"
        model: openai/claude-sonnet
        temperature: 1

    config:
      model: "gpt-41"
    ```

=== "Robusta Helm Chart"

    ```yaml
    # values.yaml
    holmes:
      additionalEnvVars:
        - name: OPENAI_API_BASE
          value: "http://litellm-proxy.litellm.svc.cluster.local:4000/v1"
        - name: OPENAI_API_KEY
          valueFrom:
            secretKeyRef:
              name: robusta-holmes-secret
              key: litellm-api-key

      modelList:
        gpt-41:
          api_key: "{{ env.OPENAI_API_KEY }}"
          api_base: "{{ env.OPENAI_API_BASE }}"
          model: openai/gpt-4.1
          temperature: 0

        claude-sonnet:
          api_key: "{{ env.OPENAI_API_KEY }}"
          api_base: "{{ env.OPENAI_API_BASE }}"
          model: openai/claude-sonnet
          temperature: 1

      config:
        model: "gpt-41"
    ```

!!! note "Model naming"
    Use the `openai/` prefix with the **model names you defined in the proxy's `model_list`**, not the actual provider model names. The proxy handles the translation to the real provider.

### Azure Workload Identity Example

To use Azure Managed Identity with the proxy (no API keys needed):

```yaml
# litellm_config.yaml on the proxy
model_list:
  - model_name: "gpt-4.1"
    litellm_params:
      model: azure/gpt-4.1
      api_base: https://your-resource.openai.azure.com/
      api_version: "2025-01-01-preview"
      # No api_key — uses Azure Managed Identity automatically
```

The proxy's pod needs a Managed Identity with the **Cognitive Services OpenAI User** role on the Azure OpenAI resource. Holmes itself needs no cloud credentials at all.

## Additional Resources

- [LiteLLM Proxy documentation](https://docs.litellm.ai/docs/proxy/quick_start){:target="_blank"}
- [LiteLLM Virtual Keys](https://docs.litellm.ai/docs/proxy/virtual_keys){:target="_blank"}
- [LiteLLM Load Balancing](https://docs.litellm.ai/docs/proxy/load_balancing){:target="_blank"}
- [OpenAI-Compatible provider configuration](openai-compatible.md) - How Holmes connects to any OpenAI-compatible endpoint
