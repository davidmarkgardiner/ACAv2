**🚨 Image Pull Failures in Dev - Root Cause Identified**

Hi team,

Quick explanation of why dev image pulls are failing:

**The setup:**
- Golden Path pushes to **Snapshot Nexus** - that's fine
- Dev clusters *could* pull directly from Snapshot Nexus - that would work

**What's going wrong:**
- Golden Path is configuring the image pull location to point at **Dev ACR**
- But there's no copy job moving images from Snapshot Nexus → Dev ACR
- So dev tries to pull from ACR... and the image isn't there

**In short:** They're telling us to pull from ACR, but nobody's putting the images in ACR.

**Options:**
1. Pull directly from Snapshot Nexus (no ACR involved), or
2. Set up a copy job from Snapshot Nexus → Dev ACR if they want to use ACR



---

Here you go:

---

**🚨 Image Pull Failures in Dev - Root Cause Identified**

Hi team,

Quick explanation of why dev image pulls are failing:

**Option A - Push to Snapshot, pull from Snapshot ✅ (works)**
```
Snapshot Nexus  ──────────────────→  Dev cluster pulls directly
                                     ✅ Image is there, works fine
```

**Option B - Push to Main Nexus, pull from ACR ✅ (works)**
```
Main Nexus  ───── we copy ─────→  Dev ACR  ───→  Dev cluster pulls
                  (tier 1)                        ✅ Image is there, works fine
```

**What Golden Path is doing ❌ (broken)**
```
Snapshot Nexus                        Dev ACR  ───→  Dev cluster pulls
      │                                  │
      │         nobody copies            │            ❌ Image not found
      └──────────── ✖ ───────────────────┘
```

**The problem:**
Golden Path is pushing to Snapshot Nexus, but something on their end is mutating the image pull location to point at Dev ACR. We don't copy from Snapshot → ACR. That's not a thing.

**The fix (pick one):**
1. Push to Snapshot, pull from Snapshot (no mutation needed), or
2. Push to Main Nexus, and we'll copy to ACR for you (tier 1 solution)

Happy to jump on a call if helpful.

---

How's that?