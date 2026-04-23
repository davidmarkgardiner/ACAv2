# Skills Verification — kagent

How to confirm that skills have been cloned and are actually usable by an
agent, including the "permission denied on `ls /skills/`" case that most
people hit first.

## TL;DR — The Verification That Actually Matters

Skills are useful only if the **agent process** can read them. Whether
`kubectl exec ... ls /skills/` works is a separate question — the `exec`
uid differs from the agent's runtime uid, and permissions often deny one
while allowing the other.

**The real test** is asking the agent via A2A to enumerate its skills:

```bash
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &
sleep 2
curl -s -X POST "http://localhost:8083/api/a2a/kagent/<agent-name>/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send",
       "params":{"message":{"role":"user","parts":[{"kind":"text",
         "text":"List every skill you have loaded, with name and one-line description."
       }]}}}' \
  -m 120 | jq -r '.result.artifacts[0].parts[0].text'
```

If the agent lists your skills by their `name:` from each SKILL.md — ✅ loaded and usable.

If the agent says "no skills loaded" — something genuinely broken. Continue to the deeper checks below.

## The Five Verification Steps

Run top-to-bottom. If an earlier step fails, no point checking later ones.

### Step 1 — Init container exited cleanly

```bash
POD=$(kubectl get pod -n kagent -l kagent=<agent-name> -o name | head -1)
kubectl get $POD -n kagent \
  -o jsonpath='{range .status.initContainerStatuses[*]}{.name}: ready={.ready} exitCode={.state.terminated.exitCode}{"\n"}{end}'
```

Expected:
```
skills-init: ready=true exitCode=0
```

Non-zero exit → clone failed. Go to Step 2 for the reason.

### Step 2 — Init container logs

```bash
kubectl logs -n kagent $POD -c skills-init
```

Expected (for gitRefs):
```
Cloning https://gitlab.internal.bank.com/... (ref main) into /skills/<repo>
Cloning into '/skills/<repo>'...
```

Expected (for OCI refs):
```
Pulling image ghcr.io/org/skill:v1 → /skills/<skill-name>/
```

Common errors you might see at this step:

| Log line | Cause | Fix |
|---|---|---|
| `SSL certificate problem: unable to get local issuer certificate` | Corp CA not in init container's trust store | See [SKILLS-CORP-CA.md](#) or set `initContainer.env: [GIT_SSL_NO_VERIFY=true]` |
| `could not read Username for 'https://...'` | Missing auth secret | Create `git-credentials` Secret with `token` key; reference via `gitAuthSecretRef` |
| `fatal: repository '...' not found` | Repo URL typo OR PAT lacks read access | Check URL; re-test PAT with `git ls-remote` |
| `fatal: Remote branch X not found` | `ref:` is a non-existent branch/tag | Use the actual default branch name (`main`, `main-clean`, etc.) |
| `Error response from daemon: manifest unknown` | OCI image tag doesn't exist | Verify with `docker pull <image>` or `skopeo inspect` |

### Step 3 — Describe the pod (catches volume / mount issues)

```bash
kubectl describe pod -n kagent $POD
```

Look for:
- `Init Containers → skills-init → State: Terminated (Completed)`
- `Volumes → kagent-skills: ... Type: EmptyDir`
- `Mounts → kagent-skills → /skills` on both the init container and main container
- No `Warning` events about volume mounts

If Step 3 fails → Helm chart wasn't applied correctly. Re-install kagent or check CRD version.

### Step 4 — Agent accepted the skills spec

```bash
kubectl get agent <agent-name> -n kagent -o yaml | yq '.status'
```

Look for:
- `conditions[].type: Accepted` with `status: "True"`
- No warnings mentioning skills

### Step 5 — Agent can actually enumerate the skills (the real test)

See the TL;DR at the top. This is the verification that matters for day-to-day use.

Bonus verification — ask the agent to do something that requires skill content:

```bash
curl -s -X POST "http://localhost:8083/api/a2a/kagent/<agent-name>/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"2","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Walk me through step 3 of your DNS diagnostics playbook — what command do you run and what do you check?"}]}}}' \
  -m 120 | jq -r '.result.artifacts[0].parts[0].text'
```

If the agent quotes specifics from your SKILL.md (exact kubectl commands, specific check names) → the LLM is pulling skill content into its context correctly.

If the agent gives generic advice unrelated to your SKILL.md content → files are on disk but the LLM isn't using them. See "Files There But Not Used" below.

## The Permission-Denied on `kubectl exec ls /skills/` Problem

**Very common. Usually not a real problem — the agent is still working.**

### What's happening

- `skills-init` runs as **root** (uid 0) and writes files to the shared emptyDir with root ownership
- The main `kagent` container runs as **non-root** (uid 1000 or similar, enforced by `runAsNonRoot: true` in the kagent Helm chart)
- `kubectl exec` drops you into the main container under whatever uid the container runs as
- That uid can't read root-owned files unless group permissions or `fsGroup` allow it

`ls /skills/` failing from exec → real question is whether the **agent process** (uid 1000) can read the files. It usually can because:

- The kagent init container sets permissive modes (e.g. 0644 / 0755) on the files it writes
- OR kagent sets `fsGroup` somewhere, causing Kubernetes to chgrp the emptyDir to that group

So **test via A2A (Step 5) first** before assuming something's broken.

### If the agent really can't read them either

Symptom: A2A test reports "no skills loaded" OR skill-content-specific questions get generic answers.

Fix by setting `fsGroup` so the non-root main container can read root-written files:

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: <agent-name>
spec:
  declarative:
    deployment:
      podSecurityContext:
        runAsNonRoot: true
        fsGroup: 1000               # matches the main container's runAsGroup
```

When `fsGroup` is set, Kubernetes applies a recursive chgrp to the emptyDir
after init containers write. The main container reads as a member of
`fsGroup`.

If the CRD doesn't expose `podSecurityContext` per agent, set it at the
Helm level so every agent inherits it:

```yaml
# kagent Helm values
podSecurityContext:
  runAsNonRoot: true
  fsGroup: 1000
```

### How to read the files anyway (debug)

If you really need to see the files as root:

```bash
# Attach an ephemeral debug container as root sharing the target pod's pid namespace
kubectl debug -n kagent $POD -it --image=alpine:3.19 \
  --share-processes --copy-to=$POD-debug -- sh

# Inside the debug container, the main container's /skills is at /proc/1/root/skills
ls -la /proc/1/root/skills/
find /proc/1/root/skills -name 'SKILL.md'
```

Don't leave the debug copy of the pod running — it's a duplicate deployment
with privileged sidecar.

## "Files There But Not Used" — Agent Can't Find Skills

Symptom: `ls /skills/` works from exec, files present, but the agent says
"no skills loaded" or doesn't reference skill content in its responses.

Usual causes:

1. **SKILL.md missing frontmatter.** Must start with `---`, include `name:`
   and `description:`, end with `---` before the prose content.

2. **Frontmatter malformed.** YAML must parse. A tab character, unquoted
   value with a colon, or missing closing `---` will kill it.

   Verify by parsing locally:
   ```bash
   head -5 /path/to/SKILL.md | yq eval-all 'select(document_index == 0)' -
   # Should output the frontmatter as valid YAML
   ```

3. **System prompt doesn't instruct skill use.** Kagent's SkillsTool makes
   skills available, but the agent LLM needs to know to reach for them. Add
   to `systemMessage`:

   ```
   For DNS questions, ALWAYS follow the diagnostic workflow in
   /skills/<repo>/dns-diagnostics/SKILL.md.
   ```

   Make the association explicit.

4. **Nested too deep.** Files at `/skills/<repo>/<path>/<long>/<nested>/SKILL.md`
   sometimes don't get indexed. Keep skill dirs shallow (one or two levels
   under `/skills/`).

## Bonus: One-Liner Health Check

Combined pod + init + file presence check:

```bash
POD=$(kubectl get pod -n kagent -l kagent=<agent-name> -o name | head -1)
kubectl get $POD -n kagent \
  -o jsonpath='{range .status.initContainerStatuses[*]}{.name}: exit={.state.terminated.exitCode}{"\n"}{end}'
kubectl logs -n kagent $POD -c skills-init --tail=5
```

Combined with the A2A enumeration test, that's a complete verification in
under a minute.

## Summary — Verification Priority Order

| Priority | Check | Why |
|---|---|---|
| 1 | A2A query: "list your skills" | Only check that proves the agent can use them |
| 2 | Init container exit code | Cheapest failure signal |
| 3 | Init container logs | Tells you WHY if Step 1 failed |
| 4 | `kubectl describe pod` | Catches volume/mount issues |
| 5 | Agent CRD `.status.conditions` | Catches CRD-reject errors |
| 6 | Exec `ls /skills/` | Usually unnecessary; may fail on permissions even when agent is fine |
| 7 | `kubectl debug` as root | Last resort for deep inspection |

Start with #1. If it works, you're done regardless of what the other checks
say. If it fails, walk down the list.

## Related Docs

| Topic | File |
|---|---|
| Loading skills from private repos + corp CA issues | `../skills-as-images/README.md` |
| Networking triage agent using skills | `networking-triage-agent/README.md` |
| kagent memory (separate feature) | `MEMORY.md` |
| Agent builder / prompt authoring | (forthcoming) |
