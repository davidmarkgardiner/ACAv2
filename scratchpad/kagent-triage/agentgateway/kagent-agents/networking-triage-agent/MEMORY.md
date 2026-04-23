# kagent Agent Memory — Reference

What kagent provides out of the box for agent memory, how to enable it in the
Helm chart, and how it differs from sessions and external memory providers.

**Ground truth:** this doc is cross-checked against the kagent source as of the
latest `main` branch (commit 24b6c5a, 2026-04-23). Specifically:
- CRD schema: `kagent/helm/kagent-crds/templates/kagent.dev_agents.yaml`
- External Memory CRD: `kagent/helm/kagent-crds/templates/kagent.dev_memories.yaml`
- Helm values: `kagent/helm/kagent/values.yaml`
- Design doc: `kagent/design/EP-1256-memory.md`
- Controller env wiring: `kagent/helm/kagent/templates/controller-configmap.yaml`

## Upstream Docs

- **User-facing concepts:** https://www.kagent.dev/docs/kagent/concepts/agent-memory
- **Operational:** https://www.kagent.dev/docs/kagent/operations/operational-considerations (Postgres HA context)
- **Design doc (authoritative):** `kagent/design/EP-1256-memory.md` in source

## Two Separate Memory Features — Don't Confuse Them

kagent has two distinct memory mechanisms with different CRD fields:

| | Native memory | External memory providers |
|---|---|---|
| CRD field | `spec.declarative.memory` | `spec.memory` (list of strings) |
| Backend | Kagent's own Postgres + pgvector (or SQLite + Turso) | External provider (currently Pinecone) |
| Separate CRD | No — inline config | Yes — `kagent.dev/Memory` v1alpha1 |
| Pluggable | No — fixed implementation | Yes — provider types in spec |
| Isolation | Per-agent | Depends on external provider's indexing |
| Auto-extraction every 5 turns | Yes | No (external providers don't get auto-save) |
| Built-in `save_memory`/`load_memory`/`prefetch_memory` tools | Yes | No |
| Production readiness | Preview / stabilising | Stable if your provider is |

Most of this document is about the **native memory** path. The external
Memory CRD is covered in its own section at the end.

## Native Memory — TL;DR

| Question | Answer |
|---|---|
| Does kagent have built-in memory? | Yes — native, no external provider needed |
| Backend options? | Postgres + pgvector (prod) OR SQLite + Turso (local dev) |
| Cross-agent sharing? | **No** — each agent is isolated |
| Auto-extraction? | Yes — every 5 user turns, background summarization to embedding |
| Explicit tools? | `save_memory`, `load_memory`, `prefetch_memory` auto-added |
| When does `prefetch_memory` run? | ONLY on the first user message of a session, not every turn |
| TTL default? | 15 days, configurable via `ttlDays` in agent spec |
| Popularity-based extension? | Yes — memories with `access_count >= 10` get +15 days on expiry |
| Embedding dimension? | 768 (hardcoded) |
| Similarity function? | Cosine, with `min_score ~0.3` filter |
| Index type on pgvector? | HNSW (`idx_memory_embedding_hnsw`, `vector_cosine_ops`) |
| Pruning cadence? | Every 24 hours (cron-like) |

## Enable in the Helm Chart — Full Walkthrough

Memory is **off by default**. Turning it on needs two things: the controller
must know to use a vector-capable DB (Helm flag), and individual agents must
declare memory in their spec.

### Step 1 — Postgres with pgvector

Three deployment patterns, documented in source comments in
`kagent/helm/kagent/values.yaml`:

#### Option A — External Postgres (recommended for production)

You provide a Postgres that already has `pgvector` extension installed.

```yaml
# kagent Helm values
database:
  postgres:
    # Connection string OR urlFile — urlFile is safer (mount as Secret)
    urlFile: /var/secrets/db-url
    vectorEnabled: true            # ← REQUIRED — wires DATABASE_VECTOR_ENABLED=true
    bundled:
      enabled: false               # disable bundled — we're using external

# Mount the URL secret to the controller
controller:
  volumes:
    - name: db-secret
      secret:
        secretName: kagent-postgres-url
  volumeMounts:
    - name: db-secret
      mountPath: /var/secrets
      readOnly: true
```

Then on your Postgres (one-off):
```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

The controller reads `DATABASE_VECTOR_ENABLED` from the ConfigMap generated
from `controller-configmap.yaml`:

```yaml
# kagent/helm/kagent/templates/controller-configmap.yaml (line 54)
DATABASE_VECTOR_ENABLED: {{ .Values.database.postgres.vectorEnabled | quote }}
```

#### Option B — Bundled Postgres (dev/eval ONLY — has a gotcha)

`bundled.enabled: true` deploys a Postgres StatefulSet via the chart. **BUT**
the bundled image is `postgres:18.3-alpine` which does NOT include pgvector.

From `values.yaml`:
```yaml
database:
  postgres:
    bundled:
      image:
        registry: docker.io
        repository: library
        name: postgres
        tag: "18.3-alpine"       # ← No pgvector in this image!
```

**To use bundled + memory**, override the image to a pgvector-enabled one:

```yaml
database:
  postgres:
    vectorEnabled: true
    bundled:
      enabled: true
      image:
        registry: docker.io
        repository: pgvector          # ← override
        name: pgvector
        tag: "pg18"                    # ← pgvector tag, not postgres tag
```

And confirm it creates the extension on first start — with the
`pgvector/pgvector` image, the `vector` extension is available but you still
need to `CREATE EXTENSION vector;` in the `kagent` database.

The bundled option is explicitly flagged **"dev/eval only, not production"**
in the values file. Don't ship it to prod.

#### Option C — SQLite + Turso (local development only)

Per the design doc, kagent also supports SQLite with Turso's libSQL driver for
native vector support (no CGO, no pgvector needed). Useful for `kind` / `minikube`
dev where you don't want to run a separate Postgres.

Not exposed via the Helm chart at this time — you'd configure via env vars.
Not recommended for anything shared. See the design doc for detail if you
need this path.

### Step 2 — Enable memory per-agent

Important: memory is **opt-in per agent**. An Agent without a `memory:` block
gets no memory tools, no auto-extraction, nothing.

The **correct CRD schema** (from `kagent/helm/kagent-crds/templates/kagent.dev_agents.yaml` line 9925):

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: my-agent
  namespace: kagent
spec:
  type: Declarative
  declarative:
    modelConfig: agentgateway-azure-openai     # reasoning model
    memory:
      modelConfig: agentgateway-qwen           # embedding model (REQUIRED field)
      ttlDays: 30                               # optional; default 15; minimum 1
    systemMessage: |
      You are a helpful assistant with long-term memory.
```

**Notes on the schema:**
- `memory.modelConfig` is **required**. It must point at a ModelConfig whose
  provider can emit embeddings.
- `memory.ttlDays` is optional. Minimum 1, no documented maximum. Default 15.
- There is **no `enabled: true` field** — the design doc mentioned one but
  the current CRD doesn't have it. Having the block is the enablement.
- The block lives under `spec.declarative.memory`, NOT `spec.memory`.
  `spec.memory` is a separate feature for external providers (see below).

### Step 3 — Verify it wired up

```bash
# 1. Controller ConfigMap has DATABASE_VECTOR_ENABLED=true
kubectl get cm -n kagent kagent -o jsonpath='{.data.DATABASE_VECTOR_ENABLED}'
# Expected: "true"

# 2. Postgres has the pgvector extension
kubectl exec -n kagent <postgres-pod> -- \
  psql -U kagent -d kagent -c "SELECT extname, extversion FROM pg_extension WHERE extname='vector';"
# Expected: vector | 0.x.x  (one row)

# 3. Memory table exists (created on first memory write)
kubectl exec -n kagent <postgres-pod> -- \
  psql -U kagent -d kagent -c "\dt" | grep memor
# Expected: public | memories (or similar)

# 4. Functional test — see "Verification Recipe" below
```

### Step 4 — Functional test

```bash
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &

# Session 1 — teach it something
curl -s -X POST "http://localhost:8083/api/a2a/kagent/<agent-name>/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Please save this: my preferred namespace is platform-dev."}]}}}' \
  -m 60 | jq -r '.result.artifacts[0].parts[0].text'

# Session 2 — new conversation, ask it to recall
curl -s -X POST "http://localhost:8083/api/a2a/kagent/<agent-name>/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"2","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"What namespace do I prefer?"}]}}}' \
  -m 60 | jq -r '.result.artifacts[0].parts[0].text'

# Expected: agent recalls "platform-dev" via prefetch_memory + load_memory
```

### Step 5 — Inspect memories directly via HTTP API

The controller exposes a REST API for memory (designed for UI + automation):

```bash
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &

# List memories for an agent+user
curl -s "http://localhost:8083/api/memories?agentName=<agent>&userId=admin@kagent.dev" \
  -H "X-User-Id: admin@kagent.dev" | jq .

# Search memories semantically
curl -s -X POST "http://localhost:8083/api/memories/search" \
  -H "Content-Type: application/json" \
  -H "X-User-Id: admin@kagent.dev" \
  -d '{"agentName":"<agent>","query":"namespace preference","topK":5}' | jq .

# Delete all memories for an agent+user (reset)
curl -s -X DELETE "http://localhost:8083/api/memories?agentName=<agent>&userId=admin@kagent.dev" \
  -H "X-User-Id: admin@kagent.dev"
```

See design doc §2 for the full API surface.

## How the Three Tools Work

When memory is enabled on an agent, three tools are added to its toolkit
automatically (you don't list them in `tools:`):

### `prefetch_memory` — runs once at session start

- Triggered on the **first user message** of a new session, not every turn
  (that would be too expensive).
- User prompt is **split into sentences** before embedding — improves recall
  because most embedding models work best at sentence granularity, and a
  multi-part prompt may match different past memories on different parts.
- Top-K results (filtered by cosine similarity `min_score ~= 0.3`) are
  injected into the first turn's LLM request as context.

### `load_memory` — agent calls when it wants more context

- Agent decides during reasoning that it needs more background.
- Embedded query → cosine similarity search → filtered by score.
- Returns compact JSON (null/empty fields omitted — keeps token budget low).
- When a memory is returned, its `access_count` is incremented in the
  background (popularity tracking — see pruning section).

### `save_memory` — agent saves explicit facts

- Agent decides during reasoning to save a specific fact.
- No summarization — saved verbatim with embedding.
- Use for "the user told me X, I should remember this."

### Auto-save callback — every 5 user turns

Independent of the three tools, a callback fires every 5 user turns:

1. Sends the current session content to the LLM with a "extract and
   summarize key information" prompt.
2. Embeds the summary.
3. Writes to the memory table.

Runs **async as a background process** — doesn't block the agent's next turn.

## Pruning + Popularity

From the design doc and source:

- Every 24 hours a pruning job runs.
- Finds memories where `expires_at < now`.
- **Popular memories survive:** if `access_count >= 10`, the memory is deemed
  valuable. `expires_at` bumped by 15 days, `access_count` reset to 0.
- **Unpopular memories deleted:** if `access_count < 10`, deleted permanently.

**Implication:** useful memories stick around indefinitely through natural
selection; noise gets cleared. This is the only lifecycle control — you can't
tag a memory as "permanent" explicitly.

## Embedding Model — What to Point `modelConfig` At

The `memory.modelConfig` field must point at a ModelConfig whose provider can
generate embeddings. Our agentgateway setup gives you two options:

| ModelConfig | Cost per 1K tokens | Recommendation |
|---|---|---|
| `agentgateway-qwen` | ~free (in-cluster Qwen via vLLM) | ✅ Use for memory — embeddings are high-volume, low-stakes |
| `agentgateway-azure-openai` | ~$0.0001/1K (embedding tier) | Overkill for memory; save GPT tokens for reasoning |

Note: kagent **hardcodes the embedding dimension to 768**. If the chosen
model emits a different dimension, kagent will truncate/normalize. This is
called out as a limitation in the design doc — first-class embedding support
is limited.

## Sessions vs Memory — Quick Distinction

| | Sessions | Memory |
|---|---|---|
| What's stored | Full raw conversation history | Extracted facts + embeddings |
| Scope | One session (one conversation thread) | All sessions of that agent+user |
| Storage | kagent Postgres (doesn't need pgvector) | kagent Postgres (needs pgvector) |
| Use case | "What did we just discuss?" | "What has this user ever told me?" |
| Enabled by | `database.type: postgres` | `database.postgres.vectorEnabled: true` + per-agent `memory:` |

Both persist through controller pod restarts when Postgres is the backend.

## External Memory Providers — Separate CRD

kagent also has a `kagent.dev/Memory` CRD at v1alpha1 for external providers.
This is a **different feature** from native memory — designed for teams that
want to plug in Pinecone / similar.

**Current support:** only Pinecone (per the CRD schema).

```yaml
apiVersion: kagent.dev/v1alpha1
kind: Memory
metadata:
  name: my-pinecone-memory
  namespace: kagent
spec:
  provider: Pinecone              # only supported provider today
  apiKeySecretRef: pinecone-api-key
  apiKeySecretKey: api-key
  pinecone:
    indexHost: my-index-abc123.svc.pinecone.io
    namespace: default             # Pinecone index namespace, optional
    topK: 5
    scoreThreshold: "0.7"
    recordFields: []               # all fields if empty
```

Reference from an Agent via **`spec.memory`** (note: top-level, NOT inside
`declarative`):

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
spec:
  memory:
    - my-pinecone-memory           # or cross-namespace: <ns>/<name>
  # ... rest of agent spec
```

**Native memory and external memory can coexist** on the same agent — the
fields are separate. You'd typically pick one; using both adds complexity
without much benefit.

## Limits — Native Memory

| Limit | Value | Notes |
|---|---|---|
| Vectors per agent | No cap | Watch disk growth on Postgres |
| TTL default | 15 days | Configurable via `ttlDays` |
| TTL minimum | 1 day | CRD schema enforces `minimum: 1` |
| Deletion granularity | agent+user, full clear | No per-memory DELETE API |
| Embedding dimension | 768 | Hardcoded, not configurable |
| Similarity function | Cosine | Not configurable |
| Search filter threshold | `min_score ~= 0.3` | Not configurable |
| Cross-agent read | Not supported | By design |
| Cross-tenant read | Not supported | By design |
| Hybrid search (dense + sparse) | Not supported | Listed in "Future Improvements" |
| Reranking | Not supported | Listed in "Future Improvements" |

## When Native Memory Isn't Enough

Three scenarios, ranked by how often you'll hit them:

### 1. Cross-agent shared lessons

You want `triage-agent` and `remediation-agent` to share a lessons catalog.
Native memory is per-agent — can't.

**Solution:** build a small `lessons-mcp` MCP server with its own table in the
same Postgres (pgvector enabled). Both agents call `lessons.search` /
`lessons.add` as tools. See discussion in `ai-platform/agentgateway/` notes.

### 2. Structured queries over memory

"Show me all lessons tagged `networking` from the last 7 days authored by
team X." Native memory does semantic search only; no SQL filter.

**Solution:** same `lessons-mcp` with hybrid tools (semantic + SQL WHERE).

### 3. Audit / compliance requirements

Native memory doesn't expose a compliance-grade audit trail. If you need
"show every fact this agent learned about subject X, with timestamps and
source sessions" — the design doc flags audit as out of scope.

**Solution:** sensitive data goes through an MCP server with explicit schemas
and audit triggers, not native memory. Keep native memory for low-stakes
per-user preferences only.

## Our Current Usage

| Agent | Memory? | Rationale |
|---|---|---|
| `networking-triage-agent` | Native, 30-day TTL, Qwen embeddings | Benefits from cross-session pattern recall; individual (not shared) memory is fine |
| Fleet agents (`agent-*` in `kagent-triage/worker-cluster-bundle/`) | None yet | Short-lived task agents; no session continuity benefit today. Could opt in later. |
| Planned `lessons-mcp` | External MCP, not kagent memory | Cross-agent shared knowledge — native doesn't fit |

## Gotchas

1. **Helm flag `vectorEnabled: true` is necessary but not sufficient.** You
   also need the `CREATE EXTENSION vector;` on the actual database. The flag
   tells kagent to use the extension; it doesn't install it.

2. **Bundled Postgres doesn't have pgvector.** The default image is
   `postgres:18.3-alpine` — no pgvector. Override to `pgvector/pgvector:pg18`
   or equivalent if you insist on bundled + memory.

3. **Azure Database for PostgreSQL needs pgvector in the allowed extensions
   list BEFORE `CREATE EXTENSION` works:**
   ```bash
   az postgres flexible-server parameter set \
     --resource-group <rg> --server-name <srv> \
     --name azure.extensions --value vector
   az postgres flexible-server restart --name <srv> --resource-group <rg>
   ```
   Then connect and `CREATE EXTENSION vector;`. Don't skip the restart.

4. **The `memory` key is overloaded in the Agent CRD.** Two separate fields:
   - `spec.memory: [string]` → external Memory CRD references
   - `spec.declarative.memory: {modelConfig, ttlDays}` → native inline config
   Using the wrong one silently does nothing (or fails at reconcile — check
   `kubectl describe agent` for errors).

5. **No `enabled: true` field despite what some early design docs show.** The
   CRD evolved; just having the `memory:` block is the enablement. Adding an
   `enabled` field will be ignored (strict decoding off) or rejected
   (strict decoding on — likely in recent versions).

6. **Embedding model change mid-life breaks retrieval.** All existing memories
   are 768-dim vectors in the embedding space of the old model. If you switch
   `memory.modelConfig` to a different provider mid-operation, new vectors
   live in a different space and cosine similarity becomes meaningless. Either
   clear existing memories or pick the embedding model once and stick with it.

7. **Deleting an Agent deletes its memory.** No orphaned vectors — good for
   cleanup, bad if you expected continuity across a re-create. Plan for data
   migration if you need it.

## Related Docs In This Repo

| Topic | Where |
|---|---|
| pgvector enablement (3 paths: Azure FS, CloudNativePG, pgvector/pgvector image) | `ai-platform/agentgateway/` (scroll to "How do we enable pgvector") |
| Rationale for pgvector over Pinecone | Same — "one Postgres for HA + memory + lessons" |
| Example memory block in a real agent | `ai-platform/kagent-agents/networking-triage-agent/agent.yaml` |
| Cross-agent shared knowledge model | `ai-platform/cross-bank-integration/README.md` |

For anything not covered here, the upstream docs + source (top of this file)
are the definitive reference.
