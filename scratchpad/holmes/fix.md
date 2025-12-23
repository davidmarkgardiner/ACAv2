That's a LiteLLM configuration issue. The "no db connection" error occurs when LiteLLM tries to use database features (like usage tracking, caching, or team management) but no database is configured.

  Quick Fix Options

  Option 1: Disable Database-Dependent Features in LiteLLM

  Update your LiteLLM ConfigMap:

  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: litellm-config
    namespace: litellm
  data:
    config.yaml: |
      model_list:
        - model_name: gpt-4o-mini
          litellm_params:
            model: azure/gpt-4o-mini
            api_base: https://YOUR_AOAI.openai.azure.com
            api_version: "2024-10-21"

      litellm_settings:
        drop_params: true
        set_verbose: false
        # Disable features that require DB
        disable_spend_logs: true
        disable_reset_budget: true

      general_settings:
        # Don't require database
        database_url: null
        store_model_in_db: false

  Option 2: Add a Simple SQLite Database

  # In LiteLLM deployment
  env:
  - name: DATABASE_URL
    value: "sqlite:///tmp/litellm.db"

  Option 3: Check Which Endpoint is Failing

  # Check Holmes logs for the actual request
  kubectl logs -n holmes deploy/holmes-holmes --tail=100 | grep -i "400\|error\|litellm"

  # Check LiteLLM logs
  kubectl logs -n litellm deploy/litellm --tail=100 | grep -i "db\|database\|400"

  Option 4: Test LiteLLM Directly

  # Test from Holmes pod - simple completion (shouldn't need DB)
  kubectl exec -n holmes deploy/holmes-holmes -- curl -X POST \
    http://litellm.litellm.svc.cluster.local:4000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'

  # Check which endpoint Holmes is calling
  kubectl logs -n holmes deploy/holmes-holmes -f | grep -i "litellm\|POST\|GET"

  Most Likely Cause

  LiteLLM v1.50+ added stricter database requirements for certain features. If your config has any of these, they need DB:

  - team_id in requests
  - user tracking
  - budget limits
  - spend logging
  - /key/ endpoints

  Quick test - restart LiteLLM with minimal config:

  # Delete and recreate LiteLLM with simpler config
  kubectl delete configmap litellm-config -n litellm
  kubectl apply -f litellm-minimal-config.yaml
  kubectl rollout restart deployment/litellm -n litellm

  What does your current LiteLLM config look like? I can help adjust it to avoid the DB requirement.


d'\
\
are we using these?\
\

  - team_id in requests
  - user tracking
  - budget limits
  - spend logging
  - /key/ endpoints 
  ⎿  ⧉ Selected 1 lines from docs/HOLMESGPT-WORK-DEPLOYMENT-GUIDE2.md in Visual Studio Code

⏺ Read(docs/HOLMESGPT-WORK-DEPLOYMENT-GUIDE2.md)
  ⎿  Read 150 lines

⏺ Looking at the LiteLLM config in your guide:

  litellm_settings:
    drop_params: true
    set_verbose: false

  No, you're NOT explicitly using those features. The config is minimal.

  However, the problem is likely one of these:

  1. Holmes Adds user Field Automatically

  Holmes may be adding a user field to LiteLLM requests for tracking. Check Holmes logs:

  kubectl logs -n holmes deploy/holmes-holmes --tail=100 | grep -i "user\|request"

  2. LiteLLM Default Behavior

  Newer LiteLLM versions try to log requests by default, which needs a DB.

  Fix - Add these settings to disable DB requirements:

  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: litellm-config
    namespace: litellm
  data:
    config.yaml: |
      model_list:
        - model_name: gpt-4o-mini
          litellm_params:
            model: azure/gpt-4o-mini
            api_base: https://YOUR_AOAI.openai.azure.com
            api_version: "2024-10-21"

      litellm_settings:
        drop_params: true
        set_verbose: false

      general_settings:
        disable_spend_logs: true     # <-- ADD THIS
        disable_reset_budget: true   # <-- ADD THIS
        store_model_in_db: false     # <-- ADD THIS

  3. Quick Test - Add SQLite

  Or just give LiteLLM a simple SQLite DB:

  # In LiteLLM deployment, add env var:
  env:
  - name: DATABASE_URL
    value: "sqlite:////tmp/litellm.db"
  - name: LITELLM_CONFIG_PATH
    value: /config/config.yaml

  Which Fix to Apply?

  # First, check what's actually in LiteLLM logs
  kubectl logs -n litellm deploy/litellm --tail=50 | grep -i "db\|database\|400\|error"

  Then either:
  1. Update ConfigMap with disable_spend_logs: true
  2. Or add SQLite via env var

  Which approach do you prefer, or want me to see the actual error first?

──────────────────────────────────────────────────────────────────────────────────────────────
>  
──────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)          Context left until auto-compact: 1%




