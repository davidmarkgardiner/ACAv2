<!--
Labels: chore, tech-debt, k8s-event-triage
Milestone: Pipeline — Fix & Stabilise
Assignee:
-->

# Clean out old/unused configurations from repo

## Context

The `k8s-event-triage/` directory has accumulated multiple iterations of config files during PoC development. Now that the `working-config/` directory contains the validated production configs, the old directories need cleanup.

## Tasks

- [ ] Audit `management-cluster/` — identify what's superseded by `working-config/`
- [ ] Audit `workload-cluster/` — identify what's superseded by `working-config/`
- [ ] Audit `eventhub-otlp-pipeline/` — determine if still needed or folded into working-config
- [ ] Audit `localhost-stack/` — determine if still needed for local dev
- [ ] Audit `prometheus-alerting/` — separate pipeline, keep if still active
- [ ] Remove or archive superseded files
- [ ] Update `README.md` to point at `working-config/` as the canonical source
- [ ] Ensure `working-config/HANDOVER.md` is up to date

## Rules

- Do NOT delete `prometheus-alerting/` — that's a separate pipeline (Prometheus → AlertManager → Argo Events)
- Do NOT delete `working-config/` — that's the current production config
- Keep `GOTCHAS.md`, `HANDOVER.md`, `IMAGES.md`, `PRIVATE-REGISTRY.md` — these are reference docs

## Acceptance Criteria

- [ ] Only one canonical set of deployment configs exists
- [ ] README points to the right directory
- [ ] No broken references between files
