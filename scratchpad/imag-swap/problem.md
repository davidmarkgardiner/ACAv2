# The Problem: Images Not Making It to Dev

## How It's Supposed to Work

```
┌─────────────────┐
│  Main Nexus     │  ← The "official" toy box everyone shares
│  (Production)   │
└────────┬────────┘
         │
         │ copies images to...
         ▼
┌─────────────────┐     ┌─────────────────┐
│  Dev ACR        │     │  Prod ACR       │
│  (Dev's copy)   │     │  (Prod's copy)  │
└─────────────────┘     └─────────────────┘
         ▲                       ▲
         │                       │
    Dev pulls               Prod pulls
    from here               from here
```

## What the Golden Path Team Is Doing Wrong

```
┌─────────────────┐
│  Snapshot Nexus │  ← They're putting toys HERE (wrong box!)
│  (NOT main)     │
└─────────────────┘
         │
         ╳  Nothing copies from here!
         
┌─────────────────┐
│  Dev ACR        │  ← Empty. No toys arrived.
└─────────────────┘
         ▲
         │
    Dev tries to pull... 💥 FAILS
```

---

## The Simple Version

1. **Golden Path pushes to**: Snapshot Nexus ❌
2. **Images get copied from**: Main Nexus only ✅
3. **Dev ACR tries to pull from**: Dev ACR (which is empty)
4. **Result**: "Image not found" 💀

---

## The Fix

Golden Path needs to push to **Main Nexus**, not Snapshot Nexus. Then the normal copy process will sync it to Dev ACR, and their pulls will work.

