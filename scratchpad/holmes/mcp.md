Below is a **practical, end-to-end setup guide for WSL** that covers **both**:

1. Installing **HolmesGPT CLI**
2. Running **HolmesGPT as an MCP server** so other clients can talk to the agent reliably

I’ll assume:

* **WSL2 (Ubuntu 20.04+ or 22.04)**
* You already have **Docker** available in WSL
* You have an **OpenAI / Azure OpenAI / Anthropic key** ready

---

# 1️⃣ Install HolmesGPT CLI on WSL

### Step 1: System dependencies

```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-venv git
```

---

### Step 2: Clone HolmesGPT

```bash
git clone https://github.com/holmesgpt/holmesgpt.git
cd holmesgpt
```

---

### Step 3: Create a virtual environment

```bash
python3 -m venv .venv
source .venv/bin/activate
```

---

### Step 4: Install HolmesGPT

```bash
pip install -U pip
pip install -e .
```

Verify:

```bash
holmes --help
```

You should see the CLI options (`ask`, `config`, etc.).

---

### Step 5: Configure LLM credentials

```bash
holmes config
```

This writes `~/.holmes/config.yaml`.

Example config:

```yaml
llm:
  provider: openai
  model: gpt-4.1
  api_key: sk-xxxx
```

Test it:

```bash
holmes ask "hello, what can you do?"
```

✅ At this point, the **CLI is fully working on WSL**

---

# 2️⃣ Install HolmesGPT as an MCP Server (Recommended)

MCP gives you **persistent sessions**, **structured responses**, and avoids flaky curl calls.

---

## Option A — Run HolmesGPT MCP Server Locally (WSL)

### Step 1: Install MCP dependencies

```bash
pip install mcp
```

---

### Step 2: Start HolmesGPT MCP server

From the HolmesGPT repo root:

```bash
python -m holmesgpt.mcp.server
```

By default this starts on:

```
stdio (for MCP clients)
```

Or explicitly over HTTP (if supported in your version):

```bash
HOLMES_MCP_TRANSPORT=http python -m holmesgpt.mcp.server
```

---

### Step 3: Verify MCP server is running

You should see logs like:

```
HolmesGPT MCP server started
```

---

## Option B — Run HolmesGPT MCP Server via Docker (More Stable)

This is **strongly recommended** if curl or Python sessions keep dying.

```bash
docker run -it \
  -e OPENAI_API_KEY=$OPENAI_API_KEY \
  -p 3333:3333 \
  ghcr.io/holmesgpt/holmesgpt:latest \
  mcp
```

Now HolmesGPT is available as a **persistent MCP endpoint**.

---

# 3️⃣ Connect to the MCP Server

## A) Connect from CLI (WSL)

```bash
holmes ask \
  --mcp localhost:3333 \
  "Why did my service restart last night?"
```

---

## B) Connect from IDE / Desktop Clients (Best UX)

HolmesGPT works with **any MCP-compatible client**:

### Supported clients

* **Claude Desktop**
* **Cursor**
* **VS Code MCP extensions**
* **Windsurf**

Example MCP config (`mcp.json`):

```json
{
  "servers": {
    "holmes": {
      "command": "python",
      "args": ["-m", "holmesgpt.mcp.server"]
    }
  }
}
```

Now HolmesGPT behaves like a **real chat agent**, not a flaky REST call.

---

# 4️⃣ Why MCP Is Better Than curl

| curl           | MCP               |
| -------------- | ----------------- |
| Stateless      | Stateful agent    |
| Timeouts       | Streaming + retry |
| Hard to format | Structured JSON   |
| One-shot       | Conversational    |

If you want **readable, structured data**, MCP is the correct choice.

---

# 5️⃣ Common WSL Gotchas

### Networking

If using Docker:

```bash
export HOLMES_HOST=0.0.0.0
```

### WSL file watching

Avoid running from `/mnt/c/...`
Use:

```bash
~/holmesgpt
```

---

# 6️⃣ Recommended Setup (TL;DR)

✅ **Best overall setup**

* HolmesGPT CLI → quick checks
* HolmesGPT MCP Server → real interaction
* MCP client (Cursor / Claude Desktop) → chat UX

```
WSL
 ├─ holmes CLI
 ├─ holmes MCP server (Docker)
 └─ IDE / MCP chat client
```

---

If you want, I can:

* Generate a **ready-to-use MCP config**
* Help you expose MCP to **Windows clients**
* Show **structured JSON output examples**
* Help wire HolmesGPT into **Grafana / Prometheus / logs**

Just tell me how you plan to use it.
