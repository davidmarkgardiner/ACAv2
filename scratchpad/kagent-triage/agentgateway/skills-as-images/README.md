# Skills as Container Images — The Corp-CA-Safe Path

Each skill is a tiny container image carrying its `SKILL.md` + scripts.
kagent pulls the image in an init container, extracts files to `/skills`.

**Why this approach instead of `gitRefs`:** image pulls go through kubelet,
which uses the **node's** CA trust store — already pre-loaded with your
corporate root CA on AKS. The `gitRefs` path runs `git clone` inside a
container whose trust store has only public CAs — fails against internal
Gitea/GitLab served with corp certs.

**Upstream documented path.** The kagent docs page
(`/docs/kagent/examples/skills`) exclusively shows container images. `gitRefs`
works but is less formally supported.

## How It Works

```
Developer edits SKILL.md in git repo
       │
       │ git push
       ▼
Gitea / GitHub Actions
       │ docker build + docker push
       ▼
Container registry (gitea.internal / harbor / ACR)
       │
       │ bump tag in agent.yaml via GitOps
       ▼
Flux / ArgoCD syncs updated Agent resource
       │
       ▼
kagent init container pulls image (uses NODE's CA trust — no corp CA config needed)
       │
       ▼
Files extracted to /skills/<skill-name>/
       │
       ▼
Agent's SkillsTool reads SKILL.md, exposes skill to the LLM
```

## When to Use This vs `gitRefs`

| Situation | Recommend |
|---|---|
| Git repo hosted on public GitHub / GitLab.com | `gitRefs` — simpler, no build pipeline |
| Git repo on internal Gitea/GitLab with corp-CA cert | **Images** (this folder) |
| Air-gapped environment | **Images** |
| Production use, audit trail requirements | **Images** — immutable tags, scannable |
| Quick POC, iteration | Either; `gitRefs` has faster edit-commit-reload loop |

At work (AKS + internal Gitea) → images.

## Anatomy of a Skill Image

### File layout in your git repo

```
my-skill/
├── Dockerfile                # 3 lines — just copies files into scratch image
├── build-image.sh            # optional local build helper
└── skill/                    # everything under here goes to / in the image
    ├── SKILL.md              # frontmatter + instructions — required
    ├── scripts/              # optional — any scripts the skill references
    │   └── helper.sh
    └── resources/            # optional — templates, manifests, etc.
        └── example.yaml
```

### The Dockerfile (always the same)

```dockerfile
FROM scratch
COPY skill/ /
```

That's it. Three lines. Image size <10 KB typically.

### Build + push

```bash
docker build -t gitea.internal.bank.com/platform/my-skill:v1 .
docker push gitea.internal.bank.com/platform/my-skill:v1
```

See `example-skill/` in this folder for a ready-to-copy template.

## Agent YAML — referencing images

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: my-agent
  namespace: kagent
spec:
  type: Declarative
  skills:
    refs:
      - gitea.internal.bank.com/platform/dns-diagnostics:v1
      - gitea.internal.bank.com/platform/k8s-networking:v1
    # Optional: skip TLS verification for dev registries with self-signed cert
    # insecureSkipVerify: true
  declarative:
    modelConfig: agentgateway-azure-openai
    # ... rest of agent spec
```

No `gitRefs`. No `gitAuthSecretRef`. Done.

## Registry Authentication

Image pulls need credentials if the registry is private. Three common patterns:

### Pattern A — Cluster-level credentials (most common at banks)

Platform team has already configured kubelet with registry credentials. You do nothing:

```bash
# Quick test — can any workload pull from the registry?
kubectl run test -n kagent --rm --restart=Never \
  --image=gitea.internal.bank.com/platform/any-existing-image:latest -- /bin/true
# If this works without --overrides or imagePullSecrets, you're on Pattern A
```

### Pattern B — Per-namespace image-pull secret

Create a docker-registry secret in the kagent namespace:

```bash
kubectl create secret docker-registry gitea-pull-secret \
  -n kagent \
  --docker-server=gitea.internal.bank.com \
  --docker-username=<gitea-user> \
  --docker-password=<gitea-pat-with-read-package-scope>
```

Then either:
- Attach to the kagent ServiceAccount so all pods inherit it:
  ```bash
  kubectl patch sa default -n kagent -p \
    '{"imagePullSecrets":[{"name":"gitea-pull-secret"}]}'
  ```
- Or reference explicitly per-agent (check kagent CRD for `imagePullSecrets` field — may not be supported; SA patching is more reliable)

### Pattern C — Workload Identity to ACR / private ACR with AAD

If using Azure Container Registry and Workload Identity (the pattern you're
using for agentgateway → Azure OpenAI):

```bash
# Grant the agent's SA pull access on the ACR
az role assignment create \
  --assignee <uami-client-id> \
  --role "AcrPull" \
  --scope $(az acr show --name <acr-name> --query id -o tsv)
```

No imagePullSecret needed — kubelet authenticates via the federated identity.

## CI Pipeline — Gitea Actions Example

Build + push each skill when `SKILL.md` changes:

```yaml
# .gitea/workflows/build-skills.yaml — lives in your skills repo
name: build-skills
on:
  push:
    branches: [main]
    paths:
      - 'skills/**/SKILL.md'
      - 'skills/**/scripts/**'
      - 'skills/**/resources/**'

jobs:
  build:
    runs-on: docker-runner
    steps:
      - uses: actions/checkout@v4

      - name: Login to Gitea container registry
        run: |
          echo "${{ secrets.GITEA_TOKEN }}" \
            | docker login gitea.internal.bank.com \
              -u ${{ gitea.actor }} --password-stdin

      - name: Build + push each skill
        run: |
          SHA=${GITHUB_SHA:0:7}
          for d in skills/*/; do
            NAME=$(basename "$d")
            IMAGE="gitea.internal.bank.com/platform/skill-$NAME"

            echo "Building $IMAGE:$SHA"
            docker build -t "$IMAGE:$SHA" "$d"
            docker push "$IMAGE:$SHA"

            # Optional: floating tag for dev environments
            docker tag "$IMAGE:$SHA" "$IMAGE:main"
            docker push "$IMAGE:main"
          done
```

Equivalents for GitHub Actions / GitLab CI are near-identical.

## Update Flow Once the Pipeline Exists

### Option 1 — Floating tag (easy, dev)

Agent references `gitea.internal/platform/skill-dns-diagnostics:main`.
Pipeline updates `main` tag on every push.
Agent pod restart picks up the new layers.

Pros: zero Agent YAML changes per skill edit.
Cons: untagged = harder to audit what's running; rollback by re-pushing old content.

### Option 2 — Immutable SHA tag (production)

Agent references `gitea.internal/platform/skill-dns-diagnostics:abc1234`.
Pipeline builds new SHA; Flux/ArgoCD auto-bumps the Agent YAML's `refs` via
a separate "image updater" automation (Flux Image Automation Controller or
ArgoCD Image Updater).

Pros: strong audit, proper versioning, easy rollback (point at old SHA).
Cons: requires image updater infra; extra moving part.

### Option 3 — Semver (release-style)

Agent references `:v1.2.3`. Pipeline only pushes on git tag / release.
Manual bumps.

Pros: deliberate, versioned.
Cons: friction for iterating on prompts.

My suggestion for the bank: **Option 2** for prod agents, **Option 1** for
dev/test agents. Same pipeline supports both.

## Verification Steps

Once you've built + pushed + applied:

```bash
# 1. Agent pod exists and is Running
kubectl get pod -n kagent -l kagent=<agent-name>

# 2. Init container pulled images without error
POD=$(kubectl get pod -n kagent -l kagent=<agent-name> -o name | head -1)
kubectl logs -n kagent $POD -c skills-init

# 3. Files are in /skills
kubectl exec -n kagent $POD -c kagent -- ls -la /skills/
# Expected: a directory per skill ref, each containing SKILL.md

# 4. Agent reports the skills as available
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &
curl -s -X POST "http://localhost:8083/api/a2a/kagent/<agent-name>/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"What skills do you have loaded?"}]}}}' \
  -m 30 | jq -r '.result.artifacts[0].parts[0].text'
```

## Gotchas

1. **`FROM scratch` is important.** Anything else (alpine, ubuntu) adds 5+ MB of base image you don't need. `FROM scratch` means the image is literally just your files.

2. **`SKILL.md` must be at the root of the skill directory.** kagent's SkillsTool expects `<mount>/SKILL.md`, not `<mount>/skill/SKILL.md` etc. The Dockerfile's `COPY skill/ /` already puts it in the right place.

3. **Frontmatter is required.** SKILL.md must start with `---` / YAML frontmatter / `---`. Without it, kagent won't recognise the file as a skill.

4. **Image tag != git SHA automatically.** Your CI must pass the SHA as the tag, or use your own tagging scheme. Floating `:latest` or `:main` are fine for dev but opaque for audit.

5. **Small is good, but verify.** `docker images | grep my-skill` — expect a few KB, not MB. If it's megabytes, something's leaked into the image that shouldn't be there.

6. **Init container uses the node's CA, but the registry auth still needs an image pull secret if the registry is private.** Two different trust paths — TLS trust for HTTPS (node CA ✅), and registry auth (needs credentials).

## Converting The Networking-Triage POC To Images

Not yet done — the existing `networking-triage-agent/` uses `gitRefs`.
To convert when you're ready:

1. Restructure `skills/dns-diagnostics/` and `skills/k8s-networking/` to add
   `Dockerfile` + `skill/` subfolder (move the existing `SKILL.md` into
   `skill/SKILL.md`).
2. Add a Gitea Actions workflow to the repo to build on push.
3. Push to Gitea; tag `:main` or `:v1`.
4. Change `agent.yaml`:
   ```yaml
   # Remove gitAuthSecretRef + gitRefs
   # Add:
   skills:
     refs:
       - gitea.internal.bank.com/platform/dns-diagnostics:v1
       - gitea.internal.bank.com/platform/k8s-networking:v1
   ```

See `example-skill/` in this folder for the file layout + a ready-to-copy
skeleton.

## Files in This Folder

| File | Purpose |
|---|---|
| `README.md` | You are here |
| `example-skill/` | Copyable template — Dockerfile + `skill/SKILL.md` + scripts dir |
| `example-skill/Dockerfile` | The 3-line Dockerfile |
| `example-skill/build-image.sh` | Local build helper (not CI — for testing) |
| `example-skill/skill/SKILL.md` | Template SKILL.md with proper frontmatter |
