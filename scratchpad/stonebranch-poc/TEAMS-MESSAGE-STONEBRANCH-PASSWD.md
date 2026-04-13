# Teams Message — Stonebranch UAG Security Alert

---

**Subject / Thread title:** Stonebranch UAG — /etc/passwd alert (expected, not a breach)

---

Hi team,

Heads up — when we spun up the Stonebranch Universal Agent pod, it triggered a security alert for **modification of /etc/passwd** by the `ua_entrypoint` process.

**What happened?**
The alert is a false positive caused by our pod design. To run on a read-only filesystem, the pod copies `/etc/passwd` at init time and mounts it back — the Stonebranch startup script then modifies it (likely to register its runtime user). Security tooling correctly flags this as it matches the T1136 (Create Account) signature.

**Is it a real threat?**
No. The behaviour is deterministic and scoped to the Stonebranch image. No privilege escalation, no lateral movement.

**What's the fix?**
We've raised a ticket to resolve it properly. The preferred fix is building a custom image with the correct user pre-baked so nothing writes to passwd at startup. Alternatively we can add a scoped Falco exception for this image.

GitLab ticket: [link to issue]

Happy to jump on a call if anyone wants a walkthrough.

---
