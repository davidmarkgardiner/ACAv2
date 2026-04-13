<!--
Title: "Security: Stonebranch UAG pod flagged for /etc/passwd modification at startup"
Labels: ~"security" ~"stonebranch" ~"platform" ~"medium"
-->

## 📝 Description

Our runtime threat detection flagged the Stonebranch Universal Agent (UAG) pod during startup. The alert reported a **"Missed modification to /etc/passwd"** by the `/bin/bash/ua_entrypoint` process, classified as unusual behaviour.

This is a known pattern caused by our current pod design — not a genuine compromise — but it needs to be resolved so the alert does not create noise or get confused with real threats.

## 🔍 Root Cause

The pod manifest (`stonebranch-poc/03-uag-agent.yaml`) works around `readOnlyRootFilesystem: true` by:

1. **initContainer** copies `/etc/passwd` from the image to an `emptyDir` volume
2. **Main container** mounts that copy back over `/etc/passwd` via a `subPath` volume mount
3. `ua_entrypoint` (the Stonebranch agent startup script) then **modifies `/etc/passwd`** at runtime — likely to add or update the agent's runtime user

The security tool correctly fires because this pattern is identical to the **T1136 - Create Account** MITRE ATT&CK technique.

## 🎯 Proposed Fix

**Option A — Pre-bake the passwd entry into a custom image (recommended)**
Build a custom image derived from `stonebranch/universal-agent:8.0.0.0-debian` with the correct user already present in `/etc/passwd`. The agent then has nothing to write at startup, eliminating the trigger entirely. No runtime exceptions needed.

**Option B — Add a Falco/runtime exception**
If we cannot build a custom image, add a scoped allowlist rule for this specific image + process:
```yaml
- rule: Modify etc passwd
  exceptions:
    - name: stonebranch_uag
      fields: [container.image.repository, proc.name]
      values:
        - [stonebranch/universal-agent, ua_entrypoint]
```

**Option C — Investigate if the write is actually needed**
Inspect what `ua_entrypoint` writes to `/etc/passwd`. If it can be made a no-op (e.g. user already exists with correct UID), no exception or custom image is required.

## ✅ Acceptance Criteria

- [ ] Identify exactly what `ua_entrypoint` writes to `/etc/passwd` and why
- [ ] Implement chosen fix (custom image, Falco exception, or no-op)
- [ ] Redeploy UAG pod and confirm no security alert fires on startup
- [ ] Document the decision and rationale in `stonebranch-poc/README.md`

## 🔗 Files

- `stonebranch-poc/03-uag-agent.yaml` — UAG pod manifest (initContainer passwd copy, subPath mount)

/label ~"security" ~"stonebranch" ~"platform" ~"medium"
