# kagent Agent Memory — Reference

What kagent provides out of the box for agent memory, how to enable it, and
how it differs from sessions and shared-knowledge stores.

## Upstream Docs

- **Main reference:** https://www.kagent.dev/docs/kagent/concepts/agent-memory
- **Overview mention:** https://www.kagent.dev/docs/kagent/concepts/agents
  (under the Memory heading — links out to the full reference above)
- **Scaling / HA context** (same Postgres that backs memory also backs multi-replica):
  https://www.kagent.dev/docs/kagent/operations/operational-considerations

## TL;DR

| Question | Answer |
|---|---|
| Does kagent have memory? | Yes, native, built-in |
| What does it use? | PostgreSQL with the pgvector extension |
| Is it pluggable (Pinecone/Qdrant)? | No — backed by Google ADK memory under the hood |
| Cross-agent sharing? | **No** — each agent has isolated memory |
| Auto-extraction? | Yes — every 5th user message, agent extracts intent/learnings/preferences |
| Explicit tools? | Yes — `save_memory`, `load_memory`, `prefetch_memory` auto-added when enabled |
| TTL? | 15 days default, configurable via `ttlDays` |
| Embedding model? | Configurable via a separate `ModelConfig` reference |

## What It Is vs What It Isn't

### ✅ kagent memory is for

- Per-agent long-term context ("user Alice has asked about deploy issues 3 times")
- Cross-session continuity ("yesterday we discussed the payments namespace")
- Automatic extraction of key facts from conversations
- Semantic recall within one agent's history

### ❌ It is NOT for

- Cross-agent shared knowledge (team-wide lessons learned catalog)
- Structured incident databases with SQL queries
- Arbitrary user-managed write schemas
- Swapping in Pinecone / Qdrant / MongoDB

For any of those, build a separate MCP server that exposes typed tools to the
agents. The networking-triage-agent's `lessons-mcp` idea (shared lessons in
pgvector, queryable across all agents) is an example.

## Memory vs Sessions — Don't Confuse Them

Two different persistence mechanisms in kagent:

| | Sessions | Memory |
|---|---|---|
| What's stored | Full conversation history (raw messages) | Extracted key facts + embeddings |
| When accessed | Every turn of a conversation | When agent invokes memory tools |
| Scope | One session (conversation thread) | All sessions of that agent |
| Storage | Postgres (same one as memory) | Postgres + pgvector |
| Survives pod restart? | Yes if Postgres is the backend | Yes if Postgres + pgvector enabled |
| Survives agent restart? | Yes | Yes |

Sessions give you "remember what we said earlier in this chat." Memory gives
you "remember patterns across all chats with this agent."

## How to Enable — Two-Step

### 1. Configure kagent with Postgres + pgvector

Helm values overlay (add this to your existing kagent values):

```yaml
database:
  type: postgres
  postgres:
    # Either inline:
    url: "postgres://kagent:<pw>@<host>:5432/kagent"
    # Or better — from a mounted secret:
    urlFile: /var/secrets/db-url
    vectorEnabled: true       # ← THE FLAG THAT ENABLES MEMORY
    bundled:
      enabled: false           # use external Postgres

# If using urlFile, mount the secret:
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

Your Postgres instance must have the `vector` extension created:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

See `ai-platform/agentgateway/` discussion for the three pgvector enablement
paths (Azure Database for PostgreSQL Flexible Server, CloudNativePG, or
`pgvector/pgvector` image for dev).

### 2. Enable memory on individual Agents

Per-agent opt-in — Agents without `memory:` get none.

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: my-agent
  namespace: kagent
spec:
  type: Declarative
  declarative:
    modelConfig: agentgateway-azure-openai   # the reasoning model
    memory:
      modelConfig: agentgateway-qwen         # the embedding model (cheap)
      ttlDays: 30                            # optional; default 15
    systemMessage: |
      You are a helpful assistant with long-term memory.
```

Important:
- `memory.modelConfig` must point at a model that can produce embeddings
- 768-dimensional vectors with cosine similarity search (fixed, not configurable)
- If no `modelConfig` is supplied, kagent may fall back to the primary model
  for embeddings (check your version — this changes between releases)

When the agent starts, kagent adds three tools to its tool set automatically:

| Tool | Auto-invoked? | Purpose |
|---|---|---|
| `prefetch_memory` | ✅ Every turn | Retrieves relevant memories before the agent generates a response |
| `load_memory` | On-demand | Agent can search memories by query |
| `save_memory` | On-demand | Agent can explicitly save a fact |

Plus: every 5th user message, the agent automatically extracts intent / key
learnings / preferences and writes them as embedded memories.

## How to Verify It's Working

```bash
# 1. Agent has the three memory tools
kubectl exec -n kagent deploy/<agent-name> -c kagent -- \
  env | grep -iE 'memory|postgres' | head
# You won't see memory directly here; indirect check below:

# 2. Memory table exists in Postgres
kubectl exec -n kagent statefulset/<postgres-pod> -- \
  psql -U kagent -d kagent -c '\dt' | grep -iE 'memory|embedding'

# 3. Have the agent remember something explicitly
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &

curl -s -X POST "http://localhost:8083/api/a2a/kagent/<agent-name>/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Please remember: my preferred namespace is platform-dev."}]}}}' \
  -m 60 | jq -r '.result.artifacts[0].parts[0].text'

# 4. Start a NEW session and ask the agent to recall
curl -s -X POST "http://localhost:8083/api/a2a/kagent/<agent-name>/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"2","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"What namespace do I prefer?"}]}}}' \
  -m 60 | jq -r '.result.artifacts[0].parts[0].text'
# Should recall "platform-dev" from the prior session
```

## Limits

| | Default |
|---|---|
| Vectors per agent | No documented cap (watch disk growth on Postgres) |
| TTL on memories | 15 days, configurable via `ttlDays` |
| Deletion granularity | Agent-wide only — can't delete a single memory via API |
| Embedding dimension | 768, not configurable |
| Similarity function | Cosine, not configurable |
| Cross-agent read | **Not supported** |
| Cross-tenant read (multi-team) | Not supported |

## Embedding Model Choice

You reference a `ModelConfig` in the `memory:` block. This should be a model
that can emit embeddings. Options on our agentgateway setup:

| ModelConfig | Good for | Why |
|---|---|---|
| `agentgateway-qwen` | Memory embeddings (recommended) | Cheap, high-volume, Qwen-served via agentgateway |
| `agentgateway-azure-openai` | Embeddings if you want max accuracy | Higher cost — probably overkill for memory |

Qwen is plenty for memory — you're not doing retrieval-heavy search, just
"which of my recent conversations are similar to this one."

## When Native Memory Is Not Enough

Three scenarios where you need something on top of kagent memory:

### 1. Cross-agent shared lessons

Multiple agents need to read/write the same knowledge base. kagent memory is
isolated per-agent — so you can't have `triage-agent` write a lesson that
`remediation-agent` reads tomorrow.

**Solution:** build an MCP server (`lessons-mcp`) that both agents call.
Table in the same Postgres/pgvector — doesn't need to be separate infra.

### 2. Structured queries beyond "similar to this"

kagent memory does semantic search only. If you need "all incidents tagged
`networking` from the last 7 days" or "lessons authored by team X," you need
SQL.

**Solution:** same `lessons-mcp` with SQL-backed tools. Mix semantic and
structured filters in one tool.

### 3. Audit / compliance requirements

kagent memory isn't designed for audit. The tables exist, but there's no
surfaced API for "show me everything this agent has learned about subject X."

**Solution:** if this matters, don't use native memory for the sensitive
data — push it to an MCP server you control with explicit schemas + audit
triggers.

## Our Current Usage

- **`networking-triage-agent`** — uses native memory (30 days TTL) so the
  agent remembers prior incident patterns it handled. Declared in
  `networking-triage-agent/agent.yaml`:
  ```yaml
  memory:
    modelConfig: agentgateway-qwen
    ttlDays: 30
  ```

- **Shared lessons catalog (planned, not yet built)** — would be an
  `lessons-mcp` server writing to the same Postgres (separate table) so
  every agent can contribute + retrieve. This sits OUTSIDE kagent memory.

- **Existing fleet agents** (`agent-cert-manager.yaml`, etc. in
  `kagent-triage/worker-cluster-bundle/`) — don't use memory currently.
  They're short-lived task agents — no session continuity value from memory.
  Could opt in later if any of them start to benefit.

## Gotchas

1. **`vectorEnabled: true` must be set at Helm level.** Just adding
   `memory:` to an Agent without this will be rejected or silently fail.

2. **pgvector extension must exist in the database.** `vectorEnabled: true`
   tells kagent to use it, but doesn't install it. You or your DBA runs
   `CREATE EXTENSION vector;` once.

3. **No way to export/import memories between environments.** Dev/staging/prod
   agents start with empty memory. If you care about transferring learned
   behaviour, you need the shared-lessons MCP path.

4. **Deleting an agent deletes its memory.** No orphaned vectors — good for
   cleanup, bad if you re-create an agent with the same name and expect
   continuity.

5. **Azure Database for PostgreSQL — allow pgvector server parameter:**
   ```bash
   az postgres flexible-server parameter set \
     --resource-group <rg> --server-name <srv> \
     --name azure.extensions --value vector
   az postgres flexible-server restart --name <srv> --resource-group <rg>
   ```
   Then connect and `CREATE EXTENSION vector;`. Common gotcha in the managed
   service.

## Related Docs In This Repo

| Topic | Where |
|---|---|
| pgvector enablement (3 paths) | `ai-platform/agentgateway/` discussion (scroll to "How do we enable pgvector") |
| Why we picked pgvector not Pinecone | Same — rationale is "one Postgres for HA + memory + lessons" |
| Agent referencing memory | `ai-platform/kagent-agents/networking-triage-agent/agent.yaml` |
| Cross-bank agent integration | `ai-platform/cross-bank-integration/README.md` — memory as shared resource |

For anything not covered here, the upstream docs (top of this file) are the
source of truth. This file captures the extra context and our specific usage.
