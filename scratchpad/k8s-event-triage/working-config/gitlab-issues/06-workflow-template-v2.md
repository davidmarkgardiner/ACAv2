<!--
Labels: feature, priority::high, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
Depends on: #1, #5, #8
-->

# Upgrade WorkflowTemplate to v2 (LLM + Gitea + notifications)

## Context

Replace the PoC `parse-and-log` stub with the full 5-step triage pipeline. See `PRODUCTION-PLAN.md` Phase 3.

## Pipeline Steps

1. **parse-event** — Extract fields from OTLP/raw K8s event JSON
2. **llm-triage** — Call Ollama qwen2.5:7b for severity classification (alert/noise/info)
3. **classify-and-alert** — Rule-based fallback + LLM verdict merge, decide if alert needed
4. **create-gitea-issue** — Create issue in Gitea repo (conditional on severity)
5. **notify-mattermost** — Post to Mattermost webhook (conditional on severity)

## Dependencies

- Ollama deployed and model pulled (#5)
- Secrets created (#8)
- Workflow pod creation working (#1)

## Tasks

- [ ] Apply `04-workflow-template-v2.yaml` from PRODUCTION-PLAN.md
- [ ] Verify template version: `kubectl get workflowtemplate k8s-event-triage -n argo-events -o jsonpath='{.metadata.labels.version}'` → `v2`
- [ ] Test with manual workflow submission using a sample event payload
- [ ] Verify all 5 steps complete successfully
- [ ] Verify Gitea issue created for warning-level events
- [ ] Verify Mattermost notification sent
- [ ] Keep v1 template tagged in git for rollback

## Rollback

```bash
kubectl apply -f 07-workflow-template.yaml  # v1 (current PoC)
```

In-flight workflows are not affected — they use the template version at creation time.

## Acceptance Criteria

- [ ] Sensor-triggered workflows run all 5 steps to completion
- [ ] LLM triage step returns alert/noise/info verdict
- [ ] Gitea issue created for warning+ events
- [ ] Mattermost notification sent for warning+ events
- [ ] `continueOn: failed` works — if Ollama is down, workflow still completes with rule-based fallback
