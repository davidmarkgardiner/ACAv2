# Open Questions for Platform Team — Managed LGTM Integration

These are the unknowns blocking implementation of the design in `README.md`. Each question lists the impact, the options we see, and what we need from the platform team.

---

## Q1 — Mimir remote_write endpoint, auth, and tenant ID

**Why it matters:** Without this we can't push any metrics from our cluster into Mimir.

**What we need:**
- Mimir push endpoint URL (e.g. `https://mimir.lgtm.example.com/api/v1/push`)
- Tenant ID header value (`X-Scope-OrgID`) — one tenant per cluster? per team? per environment?
- Auth method: bearer token? mTLS? Azure AD workload identity?
- Per-cluster rate limits (samples/sec, series count) so we can size scrape configs

**Default we'll assume if no answer:** OAuth2 client credentials, one tenant per environment (`dev`, `pre-prod`, `prod`).

---

## Q2 — Loki push endpoint, auth, and tenant ID

Same shape as Q1 but for Loki:
- Push URL (e.g. `https://loki.lgtm.example.com/loki/api/v1/push`)
- Tenant ID header
- Auth method
- Stream cardinality limits (so we know which fields to leave as labels vs `detected_fields`)

---

## Q3 — Rule provisioning model

**Why it matters:** This determines whether we own our alerts via GitOps in *this* repo, or whether we have to PR them into a platform-team-owned repo.

**Options:**

| Option | What we'd do | What platform team gives us |
|--------|-------------|----------------------------|
| **A. Alloy syncs CRDs** | Write `PrometheusRule` / `LokiRule` in this repo, apply to cluster, Alloy pushes via `mimir.rules.kubernetes` and `loki.rules.kubernetes` | Ruler API endpoint + token (per tenant) |
| **B. Central rules repo** | Open MR against platform repo with rule YAML | Repo URL + reviewer process + how long until rules are live |
| **C. Mimir tenant federation** | We run our own ruler that ships rules to managed Mimir | Federated tenant access + cost implications |

**Default we'll assume:** Option A. We'd rather own the rules in our application repo so they ship with the app.

---

## Q4 — How do alerts cross the network back to us? (THE BIG ONE)

**Why it matters:** This is the integration between managed AlertManager and our triage system. It is the **highest-risk** unknown.

**Sub-questions:**

1. Can the managed AlertManager call out to webhooks on the public internet? Or is it network-locked into the managed VPC?
2. Can it send to an Azure Event Hub HTTPS endpoint directly (it can't speak Kafka, but Event Hub also has REST)?
3. If neither — does the platform team operate a webhook-to-Kafka shim we can reuse?
4. What auth does the AlertManager support on outbound webhooks? Bearer token, mTLS, basic auth?

**Options ranked by preference:**

| Option | Pros | Cons |
|--------|------|------|
| **A. AM webhook → public HTTPS endpoint we own → Event Hub** | We control the contract; one bridge for all teams | Requires us to expose an ingress, auth it, monitor it |
| **B. AM webhook → managed Azure Function → Event Hub** | No infra for us; serverless | Costs Azure money; needs Function written + deployed |
| **C. AM webhook → Alloy `prometheus.receive_http` ingress in our cluster → Kafka** | Re-uses Alloy we already run | Same as A but with Alloy as the bridge — depends on Alloy's webhook receiver supporting AM payload |
| **D. We poll Mimir `ALERTS{alertstate="firing"}` series via Alloy and forward changes to Kafka** | No webhook needed | Polling is lossy and adds latency; only works if the metric is exposed |

**Default we'll assume:** Option C if the AM payload is JSON we can shape into OTLP, otherwise Option A.

---

## Q5 — Grafana dashboard provisioning

**Why it matters:** Determines whether we manage dashboards as code in this repo or hand-build them in the managed Grafana UI.

**Options:**

| Option | Pros | Cons |
|--------|------|------|
| **A. Grafana sidecar reads `ConfigMap grafana_dashboard=1` cluster-wide** | Pure GitOps from this repo | Only works if managed Grafana sidecar is configured to look at our cluster |
| **B. Grafana Operator with `GrafanaDashboard` CR** | Same as A but stricter typing | Requires Operator to be installed AND have access to our namespace |
| **C. UI-only — export JSON to repo for review** | Works today, no platform changes | No automatic sync; drift between UI and repo |
| **D. Grafana provisioning API + CI job** | Automated | Needs API token + CI runner with network access |

**Default we'll assume:** Option C while we wait for A/B to be possible.

---

## Q6 — Tempo / OTLP traces

**Why it matters:** Lower priority than metrics+logs but useful for KAgent / agentgateway latency debugging.

- Tempo OTLP endpoint (gRPC :4317 or HTTP :4318)?
- Sampling: are we expected to head-sample, tail-sample, or send 100%?
- Per-tenant trace retention?

**Default we'll assume:** Head-sample at 10%, send everything to a single tenant per environment.

---

## Q7 — Cardinality and cost guardrails

**Why it matters:** Easy to accidentally explode series count or log volume and either get throttled or get a bill.

- Per-cluster series limit?
- Per-cluster log ingest GB/day limit?
- Trace span limit?
- Are there pre-set "you are about to be throttled" alerts that fire back to us, or do we discover the limit by hitting it?

---

## Q8 — Multi-cluster naming convention

**Why it matters:** Three+ clusters writing to the same managed Mimir/Loki tenant collide unless every series carries a `cluster` label.

- Is there an org-wide naming convention for the `cluster` label?
- Should `environment` be a separate label or part of `cluster`?
- Any reserved label names we must not overwrite?

**Default we'll assume:** `cluster=<short-name>` and `environment=<dev|preprod|prod>` as separate labels. We'll relabel-replace any incoming `cluster` to avoid double-set conflicts.

---

## Q9 — Existing dashboards / alerts to inherit

**Why it matters:** If the platform team already ships standard "K8s cluster health" dashboards/alerts per tenant, we don't want to re-create them.

- What's already provisioned per tenant?
- Folder/alert namespace structure?
- How do we extend rather than duplicate?

---

## Q10 — Outage / drill plan

**Why it matters:** When the managed LGTM goes down, our triage pipeline starves. We need a runbook.

- What's the SLA on the managed service?
- Does Alloy buffer when Mimir/Loki is unreachable? For how long?
- Do alerts that fired during the outage get replayed?
- Is there a status page we can scrape and use to suppress noisy "no data" alerts?
