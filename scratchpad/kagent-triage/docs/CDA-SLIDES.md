---
marp: true
theme: house-dark
paginate: true
html: true
style: |
  /* @theme house-dark */

  @import url('https://fonts.googleapis.com/css2?family=Outfit:wght@400;600;700;800&family=Raleway:wght@100;200;300;400&display=swap');

  section {
    --accent: #ff6b1a;
    --accent-hover: #ff8c4a;
    --dark: #000;
    --card: #141414;
    --card-hover: #1a1a1a;
    --border: #2a2a2a;
    --body: #b5b5b5;
    --label: #888;
    --muted: #666;
    --light: #ffffff;
    --green: #22c55e;
    --red: #ef4444;
    --yellow: #f5a623;
    --blue: #3b82f6;

    background: #000;
    color: #ffffff;
    font-family: 'Raleway', sans-serif;
    font-weight: 300;
    padding: 56px 72px;
    font-size: 24px;
    line-height: 1.5;
    width: 1280px;
    height: 720px;
    display: block;
  }

  section h1 {
    font-family: 'Outfit', sans-serif;
    font-weight: 800;
    font-size: 2.2em;
    color: #ffffff;
    letter-spacing: -0.02em;
    line-height: 1.1;
    margin: 0 0 10px;
  }

  section h2 {
    font-family: 'Raleway', sans-serif;
    font-weight: 300;
    font-size: 1.1em;
    color: #ffffff;
    margin: 0 0 22px;
  }

  section h3 {
    font-family: 'Outfit', sans-serif;
    font-weight: 700;
    font-size: 0.6em;
    color: #ff6b1a;
    text-transform: uppercase;
    letter-spacing: 0.22em;
    margin: 0 0 10px;
  }

  section strong { color: #ff6b1a; font-weight: 500; }
  section em { color: #ffffff; font-style: normal; }
  section a { color: #ff6b1a; text-decoration: none; }
  section p { color: #ffffff; font-size: 0.85em; line-height: 1.65; }

  section ul, section ol { color: #ffffff; font-size: 0.82em; line-height: 1.85; padding-left: 22px; }
  section li { margin-bottom: 6px; color: #ffffff; }
  section li strong { color: #ffffff; font-weight: 500; }

  section table {
    border-collapse: collapse;
    width: 100%;
    font-size: 0.68em;
    margin-top: 16px;
    background: transparent;
  }
  section table thead { background: transparent; }
  section table thead tr {
    background: transparent;
    border-bottom: 2px solid #2a2a2a;
  }
  section table th {
    background: transparent !important;
    font-family: 'Outfit', sans-serif;
    font-weight: 700;
    font-size: 0.78em;
    text-transform: uppercase;
    letter-spacing: 0.14em;
    color: #ffffff !important;
    text-align: left;
    padding: 12px 16px 12px 0;
    border: none;
    border-bottom: 2px solid #2a2a2a;
  }
  section table tr {
    background: transparent !important;
    border: none;
  }
  section table td {
    background: transparent !important;
    color: #ffffff !important;
    font-weight: 300;
    padding: 12px 16px 12px 0;
    border: none;
    border-bottom: 1px solid #1a1a1a;
    vertical-align: top;
  }
  section table td strong {
    color: #ffffff !important;
    font-weight: 500;
  }
  section table tbody tr:nth-child(even) {
    background: transparent !important;
  }

  section code {
    background: #1a1a1a;
    color: #ff6b1a;
    padding: 3px 8px;
    border-radius: 4px;
    font-family: 'JetBrains Mono', 'Menlo', monospace;
    font-size: 0.88em;
  }

  section pre {
    background: #141414;
    border: 1px solid #2a2a2a;
    border-radius: 10px;
    padding: 20px 24px;
    font-size: 0.58em;
    line-height: 1.5;
    color: #ffffff;
    overflow: auto;
  }
  section pre code {
    background: transparent;
    color: #ffffff;
    padding: 0;
    font-size: 1em;
  }

  section blockquote {
    border-left: 3px solid #ff6b1a;
    padding: 6px 0 6px 20px;
    color: #ffffff;
    font-style: normal;
    font-size: 0.85em;
    margin: 18px 0;
    background: transparent;
  }

  section::after {
    font-family: 'Outfit', sans-serif;
    font-size: 0.55em;
    color: #ffffff;
  }

  footer {
    font-family: 'Outfit', sans-serif;
    font-size: 0.55em;
    color: #ffffff;
    font-weight: 400;
  }

  section.lead {
    display: flex !important;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    text-align: center;
  }
  section.lead h1 { font-size: 3em; }
  section.lead h2 { font-size: 1.25em; color: #ffffff; }
  section.lead h3 { font-size: 0.55em; }

  section .tag {
    display: inline-block;
    font-family: 'Outfit', sans-serif;
    font-weight: 700;
    font-size: 0.58em;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    padding: 5px 12px;
    border-radius: 5px;
  }
  section .tag-low { background: rgba(34, 197, 94, 0.12); color: #22c55e; border: 1px solid rgba(34, 197, 94, 0.35); }
  section .tag-vlow { background: rgba(59, 130, 246, 0.12); color: #60a5fa; border: 1px solid rgba(59, 130, 246, 0.35); }
  section .tag-med { background: rgba(245, 166, 35, 0.12); color: #fbbf24; border: 1px solid rgba(245, 166, 35, 0.35); }
  section .tag-high { background: rgba(239, 68, 68, 0.12); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.35); }

  /* Card component */
  section .card {
    background: #141414;
    border: 1px solid #2a2a2a;
    border-radius: 10px;
    padding: 22px 26px;
  }
  section .card-top {
    position: relative;
    overflow: hidden;
  }
  section .card-top::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 2px;
    background: linear-gradient(90deg, #ff6b1a, transparent);
  }

  /* Grid utility */
  section .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; width: 100%; }
  section .grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 16px; width: 100%; }
  section .row { display: flex; gap: 16px; width: 100%; }
  section .row > * { flex: 1; }

  /* Label / value helpers */
  section .eyebrow {
    font-family: 'Outfit', sans-serif;
    font-weight: 700;
    font-size: 0.6em;
    color: #ffffff;
    text-transform: uppercase;
    letter-spacing: 0.18em;
  }
  section .metric-num {
    font-family: 'Outfit', sans-serif;
    font-weight: 800;
    font-size: 2.2em;
    color: #ffffff;
    line-height: 1;
    margin-top: 8px;
  }
  section .metric-caption {
    font-size: 0.62em;
    color: #ffffff;
    margin-top: 6px;
  }
  section .card-num {
    font-family: 'Outfit', sans-serif;
    font-weight: 700;
    font-size: 1.8em;
    color: #ff6b1a;
    line-height: 1;
  }
  section .card-title {
    font-family: 'Outfit', sans-serif;
    font-weight: 600;
    font-size: 0.85em;
    color: #ffffff;
    margin-top: 8px;
  }
  section .card-desc {
    font-size: 0.68em;
    color: #ffffff;
    margin-top: 6px;
    line-height: 1.6;
  }
footer: 'Platform Engineering · CDA v1.0 · 2026-03-31'
---

<!-- _class: lead -->
<!-- _paginate: false -->
<!-- _footer: '' -->

### Claude Design Authority

# K8s Event Triage Platform

## AI-powered triage for Kubernetes · `kagent-triage`

<div style="margin-top: 60px; display: flex; gap: 32px; justify-content: center;">
  <div style="text-align: left;">
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.55em; color: #ffffff; text-transform:uppercase; letter-spacing:0.18em;">Owner</div>
    <div style="font-size:0.78em; color: #ffffff; margin-top:4px;">Platform Engineering</div>
  </div>
  <div style="text-align: left;">
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.55em; color: #ffffff; text-transform:uppercase; letter-spacing:0.18em;">Version</div>
    <div style="font-size:0.78em; color: #ffffff; margin-top:4px;">1.0 — Draft</div>
  </div>
  <div style="text-align: left;">
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.55em; color: #ffffff; text-transform:uppercase; letter-spacing:0.18em;">Date</div>
    <div style="font-size:0.78em; color: #ffffff; margin-top:4px;">2026-03-31</div>
  </div>
  <div style="text-align: left;">
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.55em; color: #ffffff; text-transform:uppercase; letter-spacing:0.18em;">Status</div>
    <div style="font-size:0.78em; color:var(--accent); margin-top:4px;">Pending Review</div>
  </div>
</div>

---

### Agenda

# What we'll cover today

<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin-top: 28px;">

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px 24px;">
    <div style="color: var(--accent); font-family:'Outfit'; font-weight:700; font-size:1.4em;">01</div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.8em; color:#fff; margin-top:4px;">Summary</div>
    <div style="font-size:0.65em; color: #ffffff; margin-top:4px;">What · Why · Who · Where</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px 24px;">
    <div style="color: var(--accent); font-family:'Outfit'; font-weight:700; font-size:1.4em;">02</div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.8em; color:#fff; margin-top:4px;">Threat Scenarios</div>
    <div style="font-size:0.65em; color: #ffffff; margin-top:4px;">11 risks · controls · residual</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px 24px;">
    <div style="color: var(--accent); font-family:'Outfit'; font-weight:700; font-size:1.4em;">03</div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.8em; color:#fff; margin-top:4px;">Black Box View</div>
    <div style="font-size:0.65em; color: #ffffff; margin-top:4px;">Boundaries · data flows</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px 24px;">
    <div style="color: var(--accent); font-family:'Outfit'; font-weight:700; font-size:1.4em;">04</div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.8em; color:#fff; margin-top:4px;">White Box View</div>
    <div style="font-size:0.65em; color: #ffffff; margin-top:4px;">Functional layers</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px 24px;">
    <div style="color: var(--accent); font-family:'Outfit'; font-weight:700; font-size:1.4em;">05</div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.8em; color:#fff; margin-top:4px;">RBAC Model</div>
    <div style="font-size:0.65em; color: #ffffff; margin-top:4px;">Least privilege end-to-end</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px 24px;">
    <div style="color: var(--accent); font-family:'Outfit'; font-weight:700; font-size:1.4em;">06</div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.8em; color:#fff; margin-top:4px;">Decision Requested</div>
    <div style="font-size:0.65em; color: #ffffff; margin-top:4px;">Approve rollout</div>
  </div>

</div>

---

### Section 01

# Summary

## What, why, who, where — at a glance

---

### What is it?

# AI triage for Kubernetes events

<div style="margin-top: 20px; font-size: 0.85em; color: var(--body); line-height: 1.7;">
An <strong>AI-powered platform</strong> that automatically detects, diagnoses, and reports on Kubernetes warning events across multiple AKS worker clusters — using namespace-scoped agents built on <strong>kagent (CNCF Sandbox)</strong>.
</div>

<div style="display: flex; gap: 14px; margin-top: 30px;">

  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px;">
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#ff6b1a" stroke-width="1.5"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.7em; color:#fff; margin-top:10px;">Detect</div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px; line-height:1.6;">Warning events across all AKS workers, in real time</div>
  </div>

  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px;">
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#ff6b1a" stroke-width="1.5"><path d="M12 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.7em; color:#fff; margin-top:10px;">Diagnose</div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px; line-height:1.6;">LLM root-cause analysis, namespace-scoped agents</div>
  </div>

  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px;">
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#ff6b1a" stroke-width="1.5"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.7em; color:#fff; margin-top:10px;">Report</div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px; line-height:1.6;">GitLab issues · Teams notifications</div>
  </div>

</div>

<div style="margin-top: 22px; font-size: 0.68em; color: #ffffff;">
Runs on a <strong style="color: #ffffff; font-weight:400;">management cluster</strong> orchestrating triage across <strong style="color: #ffffff; font-weight:400;">remote workers</strong> via workload identity and AKS-MCP.
</div>

---

### Why now?

# The numbers that matter

<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin-top: 22px;">

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px; position: relative; overflow: hidden;">
    <div style="position:absolute; top:0; left:0; right:0; height:2px; background:linear-gradient(90deg, var(--accent), transparent);"></div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.55em; color: #ffffff; text-transform:uppercase; letter-spacing:0.18em;">Investigation time</div>
    <div style="display:flex; align-items:baseline; gap:10px; margin-top:10px;">
      <div style="font-family:'Outfit'; font-weight:800; font-size:2.2em; color:#fff;">~60s</div>
      <div style="font-size:0.65em; color:#22c55e;">▼ from 30–60 min</div>
    </div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:4px;">Automated vs manual triage</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px; position: relative; overflow: hidden;">
    <div style="position:absolute; top:0; left:0; right:0; height:2px; background:linear-gradient(90deg, var(--accent), transparent);"></div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.55em; color: #ffffff; text-transform:uppercase; letter-spacing:0.18em;">MTTD impact</div>
    <div style="display:flex; align-items:baseline; gap:10px; margin-top:10px;">
      <div style="font-family:'Outfit'; font-weight:800; font-size:2.2em; color:#fff;">Event‑level</div>
    </div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:4px;">Catches issues before P1/P2</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px; position: relative; overflow: hidden;">
    <div style="position:absolute; top:0; left:0; right:0; height:2px; background:linear-gradient(90deg, var(--accent), transparent);"></div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.55em; color: #ffffff; text-transform:uppercase; letter-spacing:0.18em;">Scale cost</div>
    <div style="display:flex; align-items:baseline; gap:10px; margin-top:10px;">
      <div style="font-family:'Outfit'; font-weight:800; font-size:2.2em; color:#fff;">1 agent</div>
    </div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:4px;">Per namespace · no extra headcount</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px; position: relative; overflow: hidden;">
    <div style="position:absolute; top:0; left:0; right:0; height:2px; background:linear-gradient(90deg, var(--accent), transparent);"></div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.55em; color: #ffffff; text-transform:uppercase; letter-spacing:0.18em;">Output quality</div>
    <div style="display:flex; align-items:baseline; gap:10px; margin-top:10px;">
      <div style="font-family:'Outfit'; font-weight:800; font-size:2.2em; color:#fff;">Standard</div>
    </div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:4px;">Severity · RCA · remediation</div>
  </div>

</div>

---

### Stakeholders

# Who's involved

| Role | Team | Responsibility |
|------|------|----------------|
| **Platform Engineer** (Owner) | Platform Engineering | Design, deploy, operate |
| **Security Reviewer** | InfoSec | Approve threat model, RBAC |
| **Data Governance** | Data Office | Approve data flows, LLM privacy |
| **Service Owner** | Platform Engineering | Day-to-day operations |
| **Consumers** | SRE / Operations | Receive triage output |

---

### Deployment topology

# Where it runs

| Environment | Cluster / Service | Purpose |
|-------------|-------------------|---------|
| **Management plane** | AKS management cluster | kagent · Argo Events/Workflows · LiteLLM |
| **Worker clusters** | AKS worker clusters (N) | Event source + diagnostic reads |
| **Event transport** | Azure Event Hub (Standard) | Cross-cluster event bus |
| **Output: issues** | GitLab | Persistent triage record |
| **Output: notifs** | Microsoft Teams (Logic App) | Real-time channel |
| **AI inference** | Azure OpenAI / on-prem LLM | Diagnostic generation |

---

### Impact if blocked

# What happens if we don't ship

<ul style="margin-top: 20px;">
  <li><strong>P1/P2 escalations</strong> continue — warning events remain invisible until incidents</li>
  <li><strong>Reactive firefighting</strong> without structured diagnostic data</li>
  <li><strong>Triage quality varies</strong> by who's on-call and their platform knowledge</li>
  <li><strong>30–60 minute investigations</strong> remain the norm (vs. ~60s automated)</li>
  <li><strong>Manual namespace onboarding</strong> stays error-prone and doesn't scale</li>
</ul>

---

### Dependency map

# What we depend on

| Component | Role | Impact if down |
|-----------|------|----------------|
| **kagent** (v0.8.0+) | Core — agent framework | No triage |
| **Argo Workflows** (v3.6.4+) | Core — orchestration | No triage |
| **Argo Events** (v1.9+) | Core — event routing | Events not consumed |
| **Azure Event Hub** | Transport | Mgmt blind; local triage OK |
| **LiteLLM / LLM** | Core — AI inference | Degrades — raw GitLab issue |
| **GitLab API** | Output — issue store | Teams still fires |
| **Logic App** (Teams) | Output — notifications | GitLab still works |
| **External Secrets Operator** | Support — rotation | Manual rotation |

---

<!-- _class: lead -->

### Section 02

# Threat Scenarios

## 11 risk categories · all residual Low or Very Low

---

### Overview

# The assessment approach

<div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 14px; margin-top: 28px;">

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px;">
    <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#ff6b1a" stroke-width="1.4"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.75em; color:#fff; margin-top:12px;">Threat</div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:4px; line-height:1.6;">What could go wrong — concrete actor + action</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px;">
    <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#ff6b1a" stroke-width="1.4"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.75em; color:#fff; margin-top:12px;">Controls</div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:4px; line-height:1.6;">Preventive · detective · corrective mechanisms</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px;">
    <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#ff6b1a" stroke-width="1.4"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.75em; color:#fff; margin-top:12px;">Residual</div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:4px; line-height:1.6;">What's left after controls are applied</div>
  </div>

</div>

<div style="margin-top: 28px; font-size: 0.72em; color: #ffffff;">
All <strong>11 scenarios</strong> assessed against the CDA risk taxonomy. Result: <strong>Low or Very Low</strong> residual risk across the board.
</div>

---

### 2.1 · Internal Data Theft

# A platform admin exfiltrates triage data

<div style="margin-top: 18px;">
  <span class="tag tag-low">Residual · LOW</span>
</div>

<div style="display: flex; gap: 14px; margin-top: 20px;">
  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px;">
    <h3>Controls</h3>
    <div style="font-size:0.62em; color: #ffffff; line-height:1.8; margin-top:6px;">
      • RBAC: only <code>platform-team-admins</code> AD group<br>
      • Kyverno denies non-platform kagent CRD ops<br>
      • Azure AD + K8s audit logs → SIEM
    </div>
  </div>
  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px;">
    <h3>Why Low</h3>
    <div style="font-size:0.62em; color: #ffffff; line-height:1.8; margin-top:6px;">
      Data is operational metadata — pod names, event reasons, namespaces. <strong>No secrets, no PII.</strong> Same data visible via <code>kubectl get events</code>.
    </div>
  </div>
</div>

---

### 2.2 · External Data Theft

# An attacker breaches external exposure

<div style="margin-top: 18px;">
  <span class="tag tag-vlow">Residual · VERY LOW</span>
</div>

<div style="display: flex; gap: 14px; margin-top: 20px;">
  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px;">
    <h3>Controls</h3>
    <div style="font-size:0.62em; color: #ffffff; line-height:1.8; margin-top:6px;">
      • <strong>Zero external ingress</strong> — all ClusterIP<br>
      • Event Hub SAS (Send-only / Listen-only split)<br>
      • NetworkPolicy default-deny on kagent, argo-events<br>
      • Outbound: HTTPS + token auth only
    </div>
  </div>
  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px;">
    <h3>Why Very Low</h3>
    <div style="font-size:0.62em; color: #ffffff; line-height:1.8; margin-top:6px;">
      <strong>No external attack surface exists.</strong> Only external paths are Event Hub (SAS + TLS 1.2+) and outbound HTTPS with tokens.
    </div>
  </div>
</div>

---

### 2.3 · Access to Restricted Data

# Agent reaches beyond its assigned scope

<div style="margin-top: 18px;">
  <span class="tag tag-low">Residual · LOW</span>
</div>

<div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px; margin-top: 18px;">
  <h3>Layered controls</h3>
  <div style="font-size:0.65em; color: #ffffff; line-height:1.9; margin-top:8px;">
    • Triage agents <strong>read-only by default</strong> (get, list, watch)<br>
    • Namespace-scoped <strong>Role</strong> not ClusterRole<br>
    • Agent prompt: <code>CRITICAL: always use exact namespace "X"</code><br>
    • AKS-MCP UAMI scoped to <strong>specific clusters</strong> — not subscription-wide<br>
    • Remediation requires explicit <code>remediate=true</code> parameter
  </div>
</div>

<div style="margin-top:14px; font-size:0.7em; color: #ffffff;">
RBAC is the hard boundary. Prompt constraints are defence-in-depth, not the primary control.
</div>

---

### 2.4 · Enforced Exposure of Data

# Prompt injection forces LLM to leak

<div style="margin-top: 18px;">
  <span class="tag tag-low">Residual · LOW</span>
</div>

<div style="display: flex; gap: 14px; margin-top: 20px;">
  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px;">
    <h3>Attack surface</h3>
    <div style="font-size:0.62em; color: #ffffff; line-height:1.8; margin-top:6px;">
      Narrow — only K8s event message field is user-influenceable. Events carry standard K8s fields, no free-text.
    </div>
  </div>
  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 20px;">
    <h3>Mitigations</h3>
    <div style="font-size:0.62em; color: #ffffff; line-height:1.8; margin-top:6px;">
      • LLM output truncated to 4000 chars<br>
      • Prompts: never output secret values<br>
      • Destinations: authenticated internal channels only<br>
      • LiteLLM logs all prompts/completions
    </div>
  </div>
</div>

---

### 2.5 – 2.7 · Data lifecycle

# Privacy · retention · disposal

| # | Threat | Residual |
|---|--------|----------|
| 2.5 | Unlawful data processing | <span class="tag tag-vlow">VERY LOW</span> — No PII, ops metadata only. Azure OpenAI DPA in place. |
| 2.6 | Retention not compliant | <span class="tag tag-low">LOW</span> — Argo 30d · Loki 30d hot/90d cold · GitLab indefinite · dedup 24h TTL |
| 2.7 | Inadequate disposal | <span class="tag tag-low">LOW</span> — Automated TTL · Azure OpenAI 30d abuse log only · no on-prem persistence |

---

### 2.8 · External Denial of Service

# An attacker overwhelms the pipeline

<div style="margin-top: 18px;">
  <span class="tag tag-low">Residual · LOW</span>
</div>

<div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px; margin-top: 18px;">
  <h3>3-layer deduplication</h3>
  <div style="display:grid; grid-template-columns: 1fr 1fr 1fr; gap: 14px; margin-top: 12px;">
    <div style="border-left: 2px solid var(--accent); padding-left: 12px;">
      <div style="font-family:'Outfit'; font-weight:600; font-size:0.7em; color:#fff;">1 · Alloy</div>
      <div style="font-size:0.58em; color: #ffffff; margin-top:4px; line-height:1.6;">Drop <code>count&gt;1</code> events · 10/s rate limit</div>
    </div>
    <div style="border-left: 2px solid var(--accent); padding-left: 12px;">
      <div style="font-family:'Outfit'; font-weight:600; font-size:0.7em; color:#fff;">2 · Sensor</div>
      <div style="font-size:0.58em; color: #ffffff; margin-top:4px; line-height:1.6;">Rate limit 5/min per sensor</div>
    </div>
    <div style="border-left: 2px solid var(--accent); padding-left: 12px;">
      <div style="font-family:'Outfit'; font-weight:600; font-size:0.7em; color:#fff;">3 · Script</div>
      <div style="font-size:0.58em; color: #ffffff; margin-top:4px; line-height:1.6;">24h TTL keyed dedup in ConfigMap</div>
    </div>
  </div>
</div>

<div style="margin-top: 14px; font-size: 0.65em; color: #ffffff;">
Plus: LiteLLM <code>max_parallel_requests</code>, Argo <code>activeDeadlineSeconds: 900</code>, Event Hub throttling.
</div>

---

### 2.9 – 2.11 · Audit, internal DoS, exposure

# Remaining scenarios

| # | Threat | Key control | Risk |
|---|--------|-------------|------|
| **2.9** | Can't fulfil info requests | Overlapping audit: Argo 30d · KAgent logs · LiteLLM logs · GitLab permanent | <span class="tag tag-low">LOW</span> |
| **2.10** | Internal user disrupts pipeline | RBAC + Kyverno + GitOps PR review | <span class="tag tag-low">LOW</span> |
| **2.11** | Accidental exposure | GitLab ACL · Teams webhook as Secret · detect-secrets CI | <span class="tag tag-low">LOW</span> |

---

<!-- _class: lead -->

### Section 03

# Black Box View

## Boundaries · data flows · actors

---

### System boundary

# What goes in, what comes out

```
 INPUTS                                              OUTPUTS
 ──────                                              ───────
 ┌──────────────┐                                    ┌──────────────┐
 │ Worker K8s 1 │──Kafka/TLS──┐             ┌──────►│ GitLab Issues│
 └──────────────┘    (SAS)    │             │        └──────────────┘
                              ▼             │
 ┌──────────────┐       ┌──────────────┐    │        ┌──────────────┐
 │ Worker K8s 2 │──────►│ EventSource  │────┼──────►│ Teams        │
 └──────────────┘       │     ↓        │    │        │ (Logic App)  │
                        │  Workflow    │    │        └──────────────┘
 ┌──────────────┐       │   ┌─────┐    │    │
 │ Worker K8s N │──────►│   │Agent│    │    │        ┌──────────────┐
 └──────────────┘       │   │(LLM)│    │    └──────►│ Telegram     │
                        │   └─────┘    │             └──────────────┘
                        │      ↓       │
                        │   AKS-MCP    │
                        │ (UAMI x-clus)│
                        └──────────────┘
                      Management Cluster
```

---

### Data flows 1 – 5

# Ingress, orchestration, inference

| # | From | To | Data | Auth |
|---|------|-----|------|------|
| **1** | Worker (Alloy) | Event Hub | K8s warning metadata | SAS (Send) |
| **2** | Event Hub | EventSource | K8s warning metadata | SAS (Listen) |
| **3** | Sensor | Argo Workflow | Filtered event payload | In-cluster SA |
| **4** | Workflow | KAgent | A2A JSON-RPC + event | In-cluster network |
| **5** | KAgent | LiteLLM | Prompt (event + system) | API key |

---

### Data flows 6 – 10

# Diagnosis reads & outputs

| # | From | To | Data | Auth |
|---|------|-----|------|------|
| **6** | LiteLLM | LLM provider | Prompt | HTTPS + API key |
| **7** | KAgent (AKS-MCP) | Worker K8s API | kubectl get/describe/logs | UAMI · workload identity |
| **8** | Workflow | GitLab | Issue (title/desc/labels) | PAT (api, 1 project) |
| **9** | Workflow | Logic App | Triage JSON | Webhook SAS |
| **10** | Workflow | Telegram | Notification text | Bot token |

---

### Who accesses the system?

# Five actors, five access patterns

| Actor | Method | Accesses | Why |
|-------|--------|----------|-----|
| **Platform Engineers** | kubectl + Azure AD | kagent · argo-events · argo namespaces | Operate pipeline |
| **AI Agents (kagent)** | A2A in-cluster | KAgent · LiteLLM · worker K8s API | Diagnose events |
| **Argo Workflows** | K8s service account | Workflow exec · secret read | Orchestrate triage |
| **Alloy (workers)** | Kafka/TLS | Event Hub (write-only) | Forward events |
| **SRE / Ops** | GitLab UI · Teams | Triage issues + notifs | Act on output |

---

<!-- _class: lead -->

### Section 04

# White Box View

## Functional layers · service composition

---

### Functional layers

# A 4-tier architecture

```
┌─────────────────────────────────────────────────────────┐
│ USER         GitLab UI │ Teams │ Grafana Dashboards     │
├─────────────────────────────────────────────────────────┤
│ ACCESS       Azure AD · Event Hub SAS · K8s SA          │
│              Kyverno · NetworkPolicy · Workload ID      │
├─────────────────────────────────────────────────────────┤
│ SERVICE      Argo Events · Argo Workflows · kagent Ctrl │
│              LiteLLM · AKS-MCP · Notification Services  │
├─────────────────────────────────────────────────────────┤
│ RESOURCE     Event Hub · etcd · LLM Provider            │
│              Key Vault · Loki · GitLab                  │
└─────────────────────────────────────────────────────────┘
│ HORIZONTAL   Logging · Monitoring · Secrets · GitOps    │
│              Audit Trail · Dedup · Pod Cleanup          │
└─────────────────────────────────────────────────────────┘
```

---

### Service layer

# The pipeline, piece by piece

<ul>
  <li><strong>Argo Events</strong> — EventSource, Sensors (ns-filtered, rate-limited), EventBus (NATS)</li>
  <li><strong>Argo Workflows</strong> — <code>kagent-triage</code> DAG: find → diagnose → notify</li>
  <li><strong>kagent Controller</strong> — Agent CRDs, A2A endpoint, namespace-scoped tool server, ModelConfig routing</li>
  <li><strong>LiteLLM</strong> — Gateway · rate limiting · token tracking · Prometheus metrics</li>
  <li><strong>AKS-MCP</strong> — UAMI-backed cross-cluster kubectl (read-only by default)</li>
  <li><strong>Notification Services</strong> — GitLab · Logic App · Telegram</li>
</ul>

---

### Access layer

# Defence in depth — 6 mechanisms

| Control | Purpose |
|---------|---------|
| **Azure AD RBAC** | Human access (platform-team-admins only) |
| **Event Hub SAS** | Per-direction least privilege — Send ≠ Listen |
| **K8s Service Accounts** | Workflow and agent identity |
| **Kyverno Admission** | CRD restriction — belt-and-braces enforcement |
| **NetworkPolicy** | Default-deny on kagent / argo-events namespaces |
| **Workload Identity** | Cross-cluster via FIC · per-cluster scope |

---

### Horizontal functions

# Cross-cutting concerns

<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin-top: 20px;">
  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 18px;">
    <h3>Logging</h3>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px;">All → Loki · 30d hot · 90d cold</div>
  </div>
  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 18px;">
    <h3>Monitoring</h3>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px;">Prometheus + PrometheusRules (LLM errors, token anomalies)</div>
  </div>
  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 18px;">
    <h3>Secret mgmt</h3>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px;">ESO ← Azure Key Vault · 1h refresh</div>
  </div>
  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 18px;">
    <h3>GitOps</h3>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px;">All manifests in Git · PR review required</div>
  </div>
  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 18px;">
    <h3>Deduplication</h3>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px;">3-layer: Alloy · Sensor · Script 24h TTL</div>
  </div>
  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 18px;">
    <h3>Audit trail</h3>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px;">Argo history · KAgent logs · LiteLLM · GitLab</div>
  </div>
</div>

---

<!-- _class: lead -->

### Section 05

# RBAC Model

## Least privilege at every layer

---

### Management cluster — humans

# Who can do what

| Role | Identity | Scope | Permissions |
|------|----------|-------|-------------|
| **Platform Admin** | AD: `platform-team-admins` | kagent · argo-events · argo ns | `admin` ClusterRole |
| **Platform Admin** | AD: `platform-team-admins` | Cluster-wide (kagent CRDs) | `kagent-admin` all verbs |
| **Non-platform** | Any other AD user | kagent · argo-events | <span class="tag tag-high">DENIED</span> by Kyverno |

<div style="margin-top: 18px; font-size: 0.7em; color: #ffffff;">
Kyverno is the belt-and-braces — denies access even if RBAC is misconfigured.
</div>

---

### Management cluster — service accounts

# Machine identities

| SA | Namespace | Verbs | Purpose |
|----|-----------|-------|---------|
| `argo-events-sa` | argo-events | workflows: create/get/list/watch | Sensors trigger workflows |
| `argo-events-sa` | cluster | pods · logs · events: read | Diagnostics |
| `argo-events-sa` | cluster | configmaps: create/update | Dedup cache |
| `aks-mcp` | aks-mcp | all (local) | Self-diagnostics |

<div style="margin-top: 16px; font-size: 0.7em; color: #ffffff;">
Worker clusters: kagent tool-server SA is <strong>read-only</strong> (pods, logs, events, deployments, services).
</div>

---

### Cross-cluster access

# Workload Identity → Azure RBAC → Worker

```
Management Cluster              Azure AD             Worker Cluster
┌──────────────┐                ┌──────┐            ┌──────────────┐
│ kagent Agent │                │      │            │              │
│   ↓ A2A call │                │ UAMI │            │ K8s API      │
│ AKS-MCP pod  │── Workload ───►│Token │── RBAC ──►│ (read-only)  │
│ (SA:aks-mcp) │   Identity     │Issuer│ per-clus   │              │
│              │   FIC→SA       │      │            │              │
└──────────────┘                └──────┘            └──────────────┘
```

| Component | Detail |
|-----------|--------|
| **Identity** | Azure User Assigned Managed Identity (UAMI) |
| **Binding** | Federated Identity Credential → `aks-mcp` SA in `aks-mcp` ns |
| **Scope** | **Per-cluster** — not subscription-wide |
| **Ops** | Read-only default · writes require `remediate=true` |

---

### Why workload identity?

# Three concrete wins

<div style="display: flex; gap: 14px; margin-top: 24px;">

  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px;">
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#22c55e" stroke-width="1.5"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.72em; color:#fff; margin-top:12px;">No static creds</div>
    <div style="font-size:0.6em; color: #ffffff; margin-top:6px; line-height:1.6;">Tokens short-lived, auto-rotated by Azure AD</div>
  </div>

  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px;">
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#22c55e" stroke-width="1.5"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.72em; color:#fff; margin-top:12px;">Azure-enforced</div>
    <div style="font-size:0.6em; color: #ffffff; margin-top:6px; line-height:1.6;">Compromised pod can only reach assigned clusters</div>
  </div>

  <div style="flex: 1; background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 22px;">
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#22c55e" stroke-width="1.5"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.72em; color:#fff; margin-top:12px;">Full audit</div>
    <div style="font-size:0.6em; color: #ffffff; margin-top:6px; line-height:1.6;">Azure AD sign-ins + K8s audit logs</div>
  </div>

</div>

<div style="margin-top: 24px; font-size: 0.65em; color: #ffffff;">
Verify scope: <code>az role assignment list --assignee &lt;UAMI_CLIENT_ID&gt;</code>
</div>

---

### Agent-level RBAC

# K8s RBAC + prompt constraints

| Agent type | K8s RBAC | Prompt constraints | Tools |
|------------|----------|--------------------|-------|
| **Triage** (default) | Read-only | `CRITICAL: use namespace "X"` · never fetch secrets | get_pods · get_events · describe · get_logs |
| **Remediation** | Read + limited write | Explicit `remediate=true` · never delete CRDs · never restart all replicas | Above + patch · scale |

<div style="margin-top: 18px; font-size: 0.7em; color: #ffffff;">
<strong>RBAC is the boundary · prompts are supplementary.</strong>
</div>

---

<!-- _class: lead -->

### Section 06

# Decision Requested

## Approve `kagent-triage` for production rollout

---

### Next steps

# If approved today

<div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 14px; margin-top: 32px;">

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 24px; position: relative; overflow: hidden;">
    <div style="position:absolute; top:0; left:0; right:0; height:2px; background: var(--accent);"></div>
    <div style="color: var(--accent); font-family:'Outfit'; font-weight:700; font-size:1.8em;">01</div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.75em; color:#fff; margin-top:6px;">Engineering rollout</div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px; line-height:1.6;">Namespace-by-namespace deployment starting April 2026</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 24px; position: relative; overflow: hidden;">
    <div style="position:absolute; top:0; left:0; right:0; height:2px; background: var(--accent);"></div>
    <div style="color: var(--accent); font-family:'Outfit'; font-weight:700; font-size:1.8em;">02</div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.75em; color:#fff; margin-top:6px;">Worker bundle</div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px; line-height:1.6;">Deploy local kagent + sensors to worker clusters</div>
  </div>

  <div style="background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 24px; position: relative; overflow: hidden;">
    <div style="position:absolute; top:0; left:0; right:0; height:2px; background: var(--accent);"></div>
    <div style="color: var(--accent); font-family:'Outfit'; font-weight:700; font-size:1.8em;">03</div>
    <div style="font-family:'Outfit'; font-weight:600; font-size:0.75em; color:#fff; margin-top:6px;">SRE handoff</div>
    <div style="font-size:0.62em; color: #ffffff; margin-top:6px; line-height:1.6;">Runbooks + on-call training + ownership transfer</div>
  </div>

</div>

---

### Supporting documents

# Where to find the detail

| Document | Location |
|----------|----------|
| STRIDE Threat Model | `docs/SAD-THREAT-MODEL.md` |
| Compliance Checklist | `docs/SAD-COMPLIANCE-CHECKLIST.md` |
| Logging · Monitoring · Auth | `docs/SAD-LOGGING-MONITORING-AUTH.md` |
| LLM Governance | `docs/SAD-LOGGING-MONITORING-LLM.md` |
| Secret Rotation Runbook | `docs/SECRET-ROTATION-RUNBOOK.md` |
| Shared Cluster RBAC | `docs/SHARED-CLUSTER-RBAC.md` |
| Worker Cluster Bundle | `worker-cluster-bundle/README.md` |

---

<!-- _class: lead -->
<!-- _paginate: false -->
<!-- _footer: '' -->

### Thank You

# Questions?

<div style="margin-top: 40px; font-size: 0.75em; color: #ffffff;">
Platform Engineering Team<br>
Contact via <code>platform-team-admins</code> AD group
</div>
