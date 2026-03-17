# K8s Event Triage - Demo Handover Guide

> **Purpose**: Non-technical stakeholder overview of what we built, how it works, and why it matters.
> Suitable for presenting at demo sessions without deep Kubernetes knowledge.

---

## Excalidraw Architecture Diagram
https://excalidraw.com/#json=1qwkzt3Om5qMR0iSV6KFK,NVg54lKPCdBUjzN4W4gkGQ

## What We Built (One Sentence)

An **automated Kubernetes troubleshooting system** that detects problems across all our clusters, uses AI to diagnose them, creates fix-it tickets, and gives SREs copy-paste commands to resolve issues.

---

## The Problem

| Before | After |
|--------|-------|
| SREs manually watch dashboards across multiple clusters | System watches automatically 24/7 |
| Problems found hours/days later | Problems detected in seconds |
| Manual investigation: SSH in, read logs, guess | AI reads logs, identifies root cause, suggests fix |
| Knowledge locked in senior engineers' heads | AI captures diagnosis + fix in a ticket every time |
| No audit trail of what happened | Full event → diagnosis → fix trail in GitLab |

---

## How It Works (5 Steps)

```
 STEP 1              STEP 2               STEP 3              STEP 4              STEP 5
 DETECT              TRANSPORT            TRIAGE              DIAGNOSE            REMEDIATE

┌──────────┐     ┌──────────────┐     ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│          │     │              │     │              │    │              │    │              │
│  Alloy   │────►│  Event Hub   │────►│ Argo Events  │───►│  HolmesGPT   │───►│ GitLab Ticket│
│ (Watcher)│     │ (Message Bus)│     │ (Subscriber) │    │  (AI Brain)  │    │ (Action Plan)│
│          │     │              │     │              │    │              │    │              │
└──────────┘     └──────────────┘     └──────────────┘    └──────┬───────┘    └──────┬───────┘
                                                                 │                    │
 Runs on each       Azure managed        Runs on mgmt      Uses AKS MCP to     SRE copy-pastes
 AKS cluster        pub/sub service      cluster            log into clusters   fix into VSCode
                                                            and read logs
```

### Step 1: DETECT - Alloy (The Watcher)
- Runs on **every AKS cluster** we manage
- Watches for Kubernetes warning events (pod crashes, OOM kills, failed deployments, etc.)
- Lightweight — just listens and forwards

### Step 2: TRANSPORT - Azure Event Hub (The Message Bus)
- All clusters send events to **one central place**
- Azure-managed, reliable, scalable
- Think of it like a postal service for cluster events

### Step 3: TRIAGE - Argo Events (The Subscriber)
- Sits on our **management cluster** listening to Event Hub
- Filters out noise (not every event needs action)
- When something important arrives, triggers the AI investigation

### Step 4: DIAGNOSE - HolmesGPT (The AI Brain)
- Receives the event and the cluster it came from
- Uses the **AKS MCP server** (built by Microsoft/Azure) to:
  - Log into the affected cluster remotely
  - Read pod logs, describe resources, check events
  - Analyse what went wrong
- Produces a **root cause analysis** and **recommended fix**

### Step 5: REMEDIATE - GitLab Ticket (The Action Plan)
- Creates a GitLab issue automatically containing:
  - What happened (the event)
  - What's wrong (AI diagnosis)
  - How to fix it (commands + explanation)
  - A **ready-to-paste command block** for SRE to execute

---

## The SRE Experience

### Scenario: Pod OOMKilled on production cluster

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │                    GitLab Ticket #1234                              │
 │                                                                     │
 │  Title: [aks-prod-uksouth-001] OOMKilled: payments/payment-api     │
 │                                                                     │
 │  ## Root Cause                                                      │
 │  The payment-api pod exceeded its 512Mi memory limit during peak    │
 │  traffic. Heap analysis shows unbounded cache growth in the         │
 │  /api/transactions endpoint.                                        │
 │                                                                     │
 │  ## Recommended Fix                                                 │
 │  Increase memory limit to 1Gi and add cache eviction policy.       │
 │                                                                     │
 │  ## Quick Fix (copy into VSCode Copilot Chat)                      │
 │  ┌─────────────────────────────────────────────────────────────┐   │
 │  │ @terminal Use AKS MCP to connect to cluster                │   │
 │  │ aks-prod-uksouth-001 and patch deployment payment-api in   │   │
 │  │ namespace payments: set memory limit to 1Gi, memory        │   │
 │  │ request to 512Mi. Then verify the rollout completes.       │   │
 │  └─────────────────────────────────────────────────────────────┘   │
 │                                                                     │
 │  ## Manual Commands (if preferred)                                  │
 │  kubectl --context=aks-prod-uksouth-001 -n payments \              │
 │    patch deployment payment-api --type=json -p '...'               │
 │                                                                     │
 └─────────────────────────────────────────────────────────────────────┘
```

### SRE Workflow (3 options, simplest first)

| Option | How | Skill Level |
|--------|-----|-------------|
| **A. Copy-paste into Copilot Chat** | Copy the "Quick Fix" block → paste into VSCode Copilot Chat → Copilot + AKS MCP executes it | Low |
| **B. Use AKS MCP directly** | Open Copilot Chat → ask it to investigate/fix using AKS MCP | Medium |
| **C. Run commands manually** | Copy the kubectl commands from the ticket → run in terminal | High |

---

## Architecture Diagram (For Technical Slides)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              WORKLOAD CLUSTERS                                   │
│                                                                                  │
│   ┌─────────────┐      ┌─────────────┐      ┌─────────────┐                    │
│   │ AKS Cluster │      │ AKS Cluster │      │ AKS Cluster │                    │
│   │  (Prod UK)  │      │ (Staging)   │      │  (Dev)      │                    │
│   │             │      │             │      │             │                    │
│   │  ┌───────┐  │      │  ┌───────┐  │      │  ┌───────┐  │                    │
│   │  │ Alloy │  │      │  │ Alloy │  │      │  │ Alloy │  │                    │
│   │  └───┬───┘  │      │  └───┬───┘  │      │  └───┬───┘  │                    │
│   └──────┼──────┘      └──────┼──────┘      └──────┼──────┘                    │
│          │  K8s events        │                     │                            │
└──────────┼────────────────────┼─────────────────────┼────────────────────────────┘
           │                    │                     │
           ▼                    ▼                     ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          AZURE EVENT HUB                                         │
│                     (Managed Pub/Sub Message Bus)                                │
│                       Topic: "k8s-events"                                        │
└────────────────────────────────┬────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         MANAGEMENT CLUSTER                                       │
│                                                                                  │
│  ┌─────────────┐    ┌──────────────┐    ┌──────────────────┐    ┌────────────┐ │
│  │ Argo Events │    │ Argo Events  │    │    HolmesGPT     │    │  GitLab    │ │
│  │ EventSource │───►│   Sensor     │───►│   (AI Triage)    │───►│  Ticket    │ │
│  │ (subscribe) │    │ (filter)     │    │                  │    │            │ │
│  └─────────────┘    └──────────────┘    │  ┌────────────┐  │    │ + Telegram │ │
│                                          │  │  AKS MCP   │  │    │   Alert    │ │
│                                          │  │  (Azure)   │  │    └────────────┘ │
│                                          │  └─────┬──────┘  │                    │
│                                          └────────┼─────────┘                    │
│                                                   │                              │
│                                    Logs in remotely to investigate                │
│                                                   │                              │
└───────────────────────────────────────────────────┼──────────────────────────────┘
                                                    │
                            ┌───────────────────────┼──────────────────────┐
                            ▼                       ▼                      ▼
                    ┌──────────────┐       ┌──────────────┐      ┌──────────────┐
                    │ AKS Prod UK  │       │ AKS Staging  │      │  AKS Dev     │
                    │  (read logs) │       │  (read logs) │      │  (read logs) │
                    └──────────────┘       └──────────────┘      └──────────────┘


                         ╔══════════════════════════════════════╗
                         ║        SRE REMEDIATION FLOW          ║
                         ╠══════════════════════════════════════╣
                         ║                                      ║
                         ║  GitLab Ticket                       ║
                         ║       │                              ║
                         ║       ▼                              ║
                         ║  SRE copies "Quick Fix" block        ║
                         ║       │                              ║
                         ║       ▼                              ║
                         ║  Pastes into VSCode Copilot Chat     ║
                         ║       │                              ║
                         ║       ▼                              ║
                         ║  Copilot + AKS MCP executes fix      ║
                         ║  on the correct cluster              ║
                         ║                                      ║
                         ╚══════════════════════════════════════╝
```

---

## What's Built vs. What's Planned

| Component | Status | Notes |
|-----------|--------|-------|
| Alloy event collection | Built + Tested | Alloy v1.12.2 validated with Event Hub |
| Event Hub transport | Built + Tested | Pub/sub working end-to-end |
| Argo Events subscription | Built + Tested | Sensor filtering and routing working |
| HolmesGPT AI triage | Built + Tested | Diagnoses issues, creates tickets |
| AKS MCP integration | Built + Tested | HolmesGPT logs into clusters remotely |
| GitLab ticket creation | Built + Tested | Auto-creates issues with diagnosis |
| Telegram alerts | Built + Tested | Real-time notifications |
| SRE copy-paste remediation | **Concept** | Copilot Chat command block in tickets |
| Automated remediation (HolmesGPT self-fix) | **Blocked** | GPT-4/GPT-5 Mini hitting 429 rate limits; context too large |
| Local LLM for remediation | **Planned** | KubeAI option exists; needs hardware |

---

## Known Limitations & Next Steps

### Rate Limiting (429s)
- Corporate GPT-4 and GPT-5 Mini endpoints return 429 errors during HolmesGPT remediation
- Root cause: HolmesGPT's investigation is multi-turn and context-heavy
- **Workaround**: Use KubeAI with a local LLM (Gemma 2B) for the remediation step
- **Future**: Dedicated LLM endpoint or quota increase

### SRE Tooling
- VSCode + GitHub Copilot + AKS MCP extension required on SRE machines
- The "Quick Fix" block in GitLab tickets needs HolmesGPT output formatting updated
- GitLab CLI (`glab`) is optional — copy-paste from browser works fine

---

## Demo Script (5 minutes)

1. **Show the architecture diagram** (this document) — 1 min
2. **Show a workload cluster** with Alloy running — 30 sec
3. **Trigger a problem** (e.g., deploy a pod with too-low memory limit) — 30 sec
4. **Show Event Hub** receiving the event — 30 sec
5. **Show Argo Events** sensor triggering the workflow — 30 sec
6. **Show HolmesGPT** investigating (workflow logs) — 1 min
7. **Show the GitLab ticket** created automatically — 30 sec
8. **Show the Copilot Chat** remediation concept — 30 sec

---

## Key Talking Points for Stakeholders

1. **"Zero human intervention from problem to diagnosis"** — Events flow automatically from cluster to AI to ticket
2. **"Works across all our clusters"** — One management cluster watches everything
3. **"AI does what a senior SRE would do"** — Reads logs, checks resources, identifies root cause
4. **"Actionable tickets, not just alerts"** — Every ticket has a diagnosis AND fix commands
5. **"SRE just copy-pastes to fix"** — Lowest possible barrier to remediation
6. **"Full audit trail"** — Every event, diagnosis, and fix is tracked in GitLab
7. **"Built on Azure-native + open source"** — Event Hub, AKS MCP (Microsoft-built), Argo (CNCF), HolmesGPT (Robusta)
