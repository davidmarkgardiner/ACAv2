<!--
Labels: testing, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
Depends on: #6
-->

# Create end-to-end smoke test script

## Context

Need a repeatable smoke test that validates the full pipeline: Event Hub → EventSource → Sensor → Workflow → Gitea + Mattermost.

## Tasks

- [ ] Create `smoke-test.sh` script that:
  1. Injects a synthetic K8s Warning event into Event Hub (via Kafka producer or Event Hub REST API)
  2. Waits for a workflow to be created in `argo-events` namespace
  3. Waits for workflow to reach Succeeded state
  4. Checks Gitea for a new issue matching the test event
  5. Reports pass/fail for each stage
- [ ] Support `--dry-run` mode (validates prerequisites without injecting events)
- [ ] Support `--cleanup` mode (deletes test workflows and Gitea issues)
- [ ] Add timeout handling (fail if workflow doesn't complete in 5 minutes)

## Acceptance Criteria

- [ ] `./smoke-test.sh` passes on a healthy pipeline
- [ ] `./smoke-test.sh` fails with clear error message when any component is down
- [ ] Script is idempotent (safe to run multiple times)
