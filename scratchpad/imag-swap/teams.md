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


---

Got it - here's the updated version:

---

**🚨 Image Pull Failures in Dev - Root Cause Identified**

Hi team,

Quick explanation of why dev image pulls are failing:

**The current flow (what's actually happening):**
```
┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
│  Snapshot Nexus  │      │                  │      │                  │
│  Release Nexus   │ ───? │  Main Nexus      │ ───? │  Dev ACR         │
│                  │      │  (container-     │      │                  │
│  (images pushed  │      │   registry)      │      │  (where they're  │
│   here)          │      │                  │      │   trying to pull)│
└──────────────────┘      └──────────────────┘      └──────────────────┘
         │                        │                          │
         │    mystery job         │      nobody copying      │
         │    every ~30 mins?     │                          │
         └────────────────────────┘                          │
                                                             ▼
                                                    ❌ Image not found
```

**The problem:**
1. Users push to **Snapshot/Release Nexus**
2. Golden Path / ACR team are telling users to hardcode **Main Nexus (container-registry)** as the pull location
3. There's apparently some background job (every ~30 mins?) copying from Snapshot/Release → Main Nexus - but **nobody is owning this job or telling us about it**
4. Users see delays because they're waiting for this mystery copy job
5. Our job copies from **Main Nexus → ACR**, but if the image hasn't arrived in Main Nexus yet, there's nothing for us to copy

**What would actually work:**
```
Main Nexus  ───── our job copies ─────→  Dev ACR  ───→  Dev cluster pulls
(push here)        (we own this)                        ✅ Works immediately
```

**The ask:**
- Who owns the Snapshot/Release → Main Nexus copy job?
- Why are Golden Path / ACR telling users to point at Main Nexus when the image isn't there yet?

If users push directly to Main Nexus, our tier 1 solution picks it up and copies to ACR. No delays, no mystery jobs.

Happy to jump on a call to untangle this.

---

Does that capture it?