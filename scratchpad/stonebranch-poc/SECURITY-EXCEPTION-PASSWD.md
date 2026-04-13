# Security Exception: Stonebranch UAG /etc/passwd Modification

**Exception ID:** SEC-EXC-UAG-001  
**Date Raised:** 2026-04-13  
**Raised By:** Platform Engineering  
**Review Date:** 2026-10-13 (6 months)  
**Status:** Pending Approval

---

## What We Are Asking For

A scoped runtime security exception to suppress the alert triggered when the Stonebranch Universal Agent (`ua_entrypoint`) modifies `/etc/passwd` during pod startup.

The exception is narrowly scoped to:
- **Image:** `stonebranch/universal-agent:8.0.0.0-debian`
- **Process:** `ua_entrypoint`
- **Action:** Write to `/etc/passwd`
- **Timing:** Container startup only

---

## Why the Alert Fires

The Stonebranch UAG pod runs with `readOnlyRootFilesystem: true`. To allow the agent startup script (`ua_entrypoint`) to register its runtime user, the pod uses an `emptyDir` volume to provide a writable copy of `/etc/passwd`. The security tool correctly identifies this as matching the **MITRE ATT&CK T1136 - Create Account** technique.

This is a known, deterministic behaviour of the vendor-supplied image. It is not a sign of compromise.

---

## Due Diligence Completed

- [x] Root cause identified — vendor startup script writes a user entry to `/etc/passwd` at init
- [x] Behaviour is deterministic and scoped to pod startup
- [x] Option A (custom image with pre-baked user) assessed — viable but requires build pipeline setup, registry approval process, and ongoing image maintenance on every upstream version bump
- [x] No evidence of privilege escalation, lateral movement, or unexpected network activity
- [x] Pod runs as UID 10010 (non-root), `allowPrivilegeEscalation: false`, all capabilities dropped

---

## Risks We Are Accepting

| Risk | Likelihood | Impact | Rationale for Acceptance |
|------|-----------|--------|--------------------------|
| Alert suppression masks a genuine future exploit using the same technique in this container | Low | Medium | Exception is scoped to a specific image + process. A different process writing to passwd in this pod would still alert. |
| Upstream image is compromised and `ua_entrypoint` is modified to add a malicious user | Low | High | Mitigated by image pull policy (pinned tag), registry scanning, and Stonebranch vendor trust. |
| Exception scope creeps to suppress broader passwd alerts | Low | High | Exception must name the exact image repository and process. Reviewed at 6 months. |
| `readOnlyRootFilesystem` bypass via emptyDir persists as a design weakness | Certain | Low | Acknowledged. The emptyDir passwd is writable but isolated to this pod. No other sensitive files are exposed this way. |

---

## Mitigating Controls Already in Place

- **`runAsNonRoot: true`** — pod cannot run as root
- **`runAsUser: 10010`** — fixed, non-privileged UID
- **`allowPrivilegeEscalation: false`** — no sudo, no setuid escalation
- **`capabilities: drop: ALL`** — no Linux capabilities granted
- **`seccompProfile: RuntimeDefault`** — syscall filtering active
- **Network policy** — pod has egress/ingress restrictions (see `04-networkpolicy.yaml`)
- **Pinned image tag** — `8.0.0.0-debian`, not `latest`
- All other runtime alerts remain active for this pod

---

## Exception Configuration

### Falco
```yaml
- rule: Write below etc
  exceptions:
    - name: stonebranch_uag_passwd
      fields: [container.image.repository, proc.name, fd.name]
      values:
        - [stonebranch/universal-agent, ua_entrypoint, /etc/passwd]
```

### Microsoft Defender for Containers / Prisma Cloud
Raise a suppress rule for:
- **Container image:** `stonebranch/universal-agent:8.0.0.0-debian`
- **Process name:** `ua_entrypoint`
- **File path:** `/etc/passwd`
- **Justification:** Vendor startup script registers runtime user at init. Behaviour is deterministic and isolated. All other security controls intact.

---

## Conditions of This Exception

1. Exception applies **only** to image `stonebranch/universal-agent:8.0.0.0-debian` — any new version must be re-evaluated
2. Exception is **not** transferable to other images or workloads
3. All other security controls on this pod remain in place and must not be relaxed
4. Exception is reviewed at **2026-10-13** — if Option A (custom image) becomes low-effort by then, this exception should be retired
5. If the Stonebranch image is upgraded, the new `ua_entrypoint` must be re-inspected before the exception is extended

---

## Approvals Required

| Role | Name | Approved | Date |
|------|------|----------|------|
| Platform Engineering Lead | | | |
| Security Team | | | |
| Service Owner | | | |
