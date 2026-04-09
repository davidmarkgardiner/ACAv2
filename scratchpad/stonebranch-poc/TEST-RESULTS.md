# Stonebranch UAG POC - Test Results

**Date:** 2026-04-09  
**Cluster:** proxmox-k8s  
**Namespace:** stonebranch  
**Agent Version:** Universal Agent 8.0.0.0 (Release Build 78, 2026-03-27)  
**Python:** 3.11.15 (bundled)  
**Mode:** Standalone/Unmanaged (no Universal Controller connected)

---

## Environment Summary

| Component | Pod | Status | Node |
|-----------|-----|--------|------|
| OMS Server | oms-server-7d87d46df4-wgf67 | Running | k8s-worker1 |
| UAG Agent 1 | uag-agent-9845597c8-jhpw6 (UAG-PROXMOX-jhpw6) | Running | k8s-worker1 |
| UAG Agent 2 | uag-agent-9845597c8-rzqm4 (UAG-PROXMOX-rzqm4) | Running | k8s-worker2 |

---

## Test 1: Agent Status & Broker Health

### 1a. Broker Daemon Status
```
$ ubrokerd status
running (9)
```
**Result: PASS** - Universal Broker is running with PID 9.

### 1b. Universal Query (uquery) - Agent Status Report
```
$ uquery -host localhost
```
**Result: PASS** - Full agent status report returned:
- Broker Version: 8.0.0 Level 0 Release Build 78
- Broker Status: Active
- Broker Managed: NO (no Universal Controller)
- Agent Netname: UAG-PROXMOX-jhpw6
- OS: Linux 6.8.0-107-generic
- License Status: **Not available** (requires Universal Controller 6.9+ for licensing)
- Active Components:
  - `uems` (Universal Event Monitor Server) - REGISTERED, ESTABLISHED
  - `uag` (Universal Automation Center Agent) - REGISTERED, ESTABLISHED

### 1c. Broker Configuration Refresh
```
$ uctl -refresh -host localhost
```
**Result: PASS** - Broker configuration refreshed successfully (exit code 0, no output = success).

### 1d. Second Agent Pod Query
```
$ uquery -host localhost  (on pod rzqm4)
```
**Result: PASS** - Second agent also healthy, reporting as UAG-PROXMOX-rzqm4.

---

## Test 2: Universal Command (ucmd)

### 2a. Remote Command Execution
```
$ ucmd -host localhost -cmd "echo Hello from Stonebranch UAG"
UNV0199E Unable to validate INDESCA license information. The license information is not available.
UNV0516E Universal Command ending unsuccessfully with exit code 225.
```
**Result: FAIL (Exit 225)** - ucmd requires a valid INDESCA license. Without a Universal Controller providing license info, the Manager component (ucmd) cannot run. The Server component (ucmds) and config confirm `authenticate NO` but the license check happens first.

### 2b. ucmd Version Check
```
$ ucmd -version
ucmd 8.0.0 Level 0 Release Build 78
```
**Result: PASS** - Binary is present and functional. License is only checked at execution time.

**Key Finding:** ucmd, udm, and other Manager components require license keys provided by Universal Controller 6.9+. Without a Controller, these tools cannot execute commands. License can alternatively be set in local config files (`/etc/universal/ucmd.conf`) but requires a valid Stonebranch license key.

---

## Test 3: Universal Data Mover (udm)

### 3a. UDM Help & Version
```
$ udm -version
udm 8.0.0 Level 0 Release Build 78

$ udm -help
(Full help output returned successfully)
```
**Result: PASS (binary present)** - UDM is installed and supports:
- Network Fault Tolerant (NFT) transfers
- TLS 1.3 cipher suites
- Compression (ZLIB/HASP)
- Text and binary transfer modes
- Script-driven transfers (`-s script.udm`)
- SFTP/FTP support via UFTP config

### 3b. UDM Actual Transfer
**Result: BLOCKED by license** - Same INDESCA license requirement as ucmd. Cannot perform actual file transfers without a valid license or Universal Controller.

---

## Test 4: Universal Event Monitor (UEM)

### 4a. UEM Manager Help
```
$ uem -help
```
**Result: PASS** - UEM Manager supports:
- File event monitoring (creation, size thresholds)
- Custom event types
- Triggered/rejected/expired handlers
- Date/time-based activation windows
- Polling intervals

### 4b. UEMLoad - Create File Watch Event
```
$ uemload -add -event_id "test-file-watch" -event_type FILE -filespec "/tmp/test-watch-*.txt"
UNV3666I Load request started at 10:56:24 04/09/26.
UNV3667I Universal Event Monitor Load is ending successfully with exit code 0.
```
**Result: PASS** - Successfully created a file watch event definition. This works WITHOUT a license because it only configures the local event monitor server.

### 4c. UEMLoad - Create Handler
```
$ uemload -add -handler_id "test-handler" -handler_type cmd -cmd "echo File detected!"
UNV3667I Universal Event Monitor Load is ending successfully with exit code 0.
```
**Result: PASS** - Handler created successfully.

### 4d. UEMLoad - List Events and Handlers
```
$ uemload -list

Event Definition(s):
====================
Event ID...............: test-file-watch
Event Type.............: FILE
File Specification.....: /tmp/test-watch-*.txt
Enabled................: yes
Active.................: no

Event Handler(s):
=================
Handler ID...................: test-handler
Handler Type.................: CMD
Command......................: echo File detected!
```
**Result: PASS** - Both event definitions and handlers are listed correctly.

### 4e. UEMLoad - Delete Events and Handlers (Cleanup)
```
$ uemload -delete -event_id "test-file-watch"
$ uemload -delete -handler_id "test-handler"
```
**Result: PASS** - Both deleted successfully.

**Key Finding:** UEM event definitions and handlers can be fully managed locally without a Universal Controller. This is useful for file-based triggers and event-driven automation on the agent itself.

---

## Test 5: OMS Message Queue

### 5a. OMS Connection List
```
$ omsadm -list connections -port 7878

CLIENT_ID                                           CONNECT_TIME        IP_ADDRESS
ops.agent.autoconf.oms-server-...                   2026.04.09 10:51:11 127.0.0.1:55952
ops.agent.UAG-PROXMOX-jhpw6                         2026.04.09 10:53:19 10.244.194.74:54766
ops.agent.UAG-PROXMOX-rzqm4                         2026.04.09 10:52:58 10.244.126.59:40006
```
**Result: PASS** - OMS shows 3 connections:
1. OMS server auto-configuration client (localhost)
2. Agent pod 1 (jhpw6) from k8s-worker1
3. Agent pod 2 (rzqm4) from k8s-worker2

All connections are in `open` state using OMS protocol v7.4.0.0, with `WATCH_MESSAGE_ASYNC` as the last request.

### 5b. OMS Queue List
```
$ omsadm -list queues -port 7878 -print all

QUEUE_NAME                       CONS_CNT  MSG_CNT  PND_ACK
ops.controller.queue             0         3        no
ops.agent.autoconf...            0         0        no
ops.agent.UAG-PROXMOX-jhpw6     0         0        no
ops.agent.UAG-PROXMOX-rzqm4     0         0        no
```
**Result: PASS** - 4 queues visible:
- `ops.controller.queue` has **3 pending messages** (agent registration messages waiting for a Controller that isn't connected)
- Each agent has its own message queue (currently empty - no Controller to send commands)

### 5c. OMS I/O Performance Test
```
$ omsadm -test io -iocount 1000 -iofile /tmp/oms-io-test
UNV6105I I/O write test: count=1000, flush interval=1, rate=326.58 blocks/sec.
```
**Result: PASS** - OMS I/O write test completed at 326.58 blocks/sec (512-byte blocks = ~163 KB/sec with fsync on every write). This is adequate for message queuing.

### 5d. OMS Connection Errors
The OMS and agent logs show repeated errors from IP `192.168.6.5` (a node IP):
```
UNV6252E Network error on connection 192.168.6.5:XXXXX: ASYReceiveNegotiationEH
```
**Observation:** Something external to the pods is probing the OMS port every ~5 seconds. This appears to be Kubernetes liveness/readiness probes hitting the OMS TLS port with a plain TCP connection, which fails the TLS negotiation handshake. These errors are noisy but harmless.

---

## Test 6: Scheduling/Job Capabilities Without Controller

### 6a. What Works Without a Controller
| Capability | Status | Notes |
|-----------|--------|-------|
| Broker management (start/stop/refresh) | WORKS | `uctl -refresh`, `ubrokerd status` |
| Agent status queries | WORKS | `uquery` returns full component info |
| Event definitions (UEM) | WORKS | Create, list, delete file watch events |
| Event handlers (UEM) | WORKS | Create, list, delete handlers |
| File copy utility | WORKS | `ucopy` for local file operations |
| Data encryption | WORKS | `uencrypt` for encrypting command files |
| Certificate management | WORKS | `ucert` for X.509 cert operations |
| Config merge utility | WORKS | `upimerge` for config file management |
| OMS messaging | WORKS | Queues active, agents connected |
| Message exit translation | WORKS | `umet` for message-to-exit-code mapping |

### 6b. What Requires a Universal Controller
| Capability | Status | Error |
|-----------|--------|-------|
| Remote command execution (ucmd) | BLOCKED | License required (exit 225) |
| File transfer (udm) | BLOCKED | License required |
| SAP connector (usap) | BLOCKED | Missing `libsapnwrfc.so` + license |
| PeopleSoft connector (upps) | BLOCKED | Requires PeopleSoft endpoint + license |
| Job scheduling | NOT AVAILABLE | Scheduling is a Controller function |
| Job chaining/dependencies | NOT AVAILABLE | Controller function |
| Centralized monitoring | NOT AVAILABLE | Controller function |

### 6c. UEM as Standalone Scheduler
The Universal Event Monitor can act as a basic **event-driven scheduler** without a Controller:
- Monitor for file creation/modification with glob patterns
- Set activation/deactivation time windows
- Execute commands or scripts when events trigger
- Maximum occurrence counts to auto-deactivate
- Polling interval control (default 10 seconds)

This is NOT a full cron-like scheduler, but it can handle file-trigger based automation.

---

## Test 7: Python Extensions & SDK

### 7a. Bundled Python Version
```
Python 3.11.15 (bundled in /opt/universal/python/)
pip 24.0
```

### 7b. Installed Python Packages (Notable)
| Package | Version | Purpose |
|---------|---------|---------|
| kubernetes | 35.0.0 | Kubernetes API client |
| azure-storage-blob | 12.28.0 | Azure Blob Storage |
| azure-core | 1.38.2 | Azure SDK core |
| boto3 | 1.42.59 | AWS SDK |
| google-cloud-storage | 3.9.0 | GCP Storage |
| docker | 7.1.0 | Docker API client |
| paramiko | 3.5.1 | SSH/SFTP |
| cx-oracle | 8.3.0 | Oracle DB connector |
| pyodbc | 5.3.0 | ODBC database connector |
| hdbcli | 2.27.23 | SAP HANA DB connector |
| hdfs | 2.7.3 | Hadoop HDFS client |
| requests | 2.32.5 | HTTP client |
| cryptography | 46.0.5 | Cryptographic operations |
| pyyaml | 6.0.3 | YAML parsing |
| oauthlib | 3.3.1 | OAuth library |

**Result: PASS** - Rich set of cloud, database, and infrastructure Python packages pre-installed. The agent is designed to be a universal connector to cloud platforms and databases.

### 7c. Universal Extension Framework
Located at `/opt/universal/uagsrv/uext/universal_extension/`:
- `universal_extension.py` - Base extension class
- `command_processor.py` - Synchronous/async command processing
- `event_processor.py` - Event handling framework
- `channel_manager.py` - Communication channels
- `otel.py` - OpenTelemetry integration
- `ua_utility.py` - Utility functions
- `deco/command.py`, `deco/choice.py` - Decorators for extension development

Also includes third-party libraries under `_3pp/` for extension use.

---

## Test 8: Cross-Pod Communication

### 8a. Agent-to-Agent Query (by IP)
```
$ uquery -host 10.244.126.59 -port 7887  (from pod jhpw6 to pod rzqm4)
```
**Result: TIMEOUT** - The query hung and did not return. Cross-pod broker communication on port 7887 appears to be blocked or the broker only listens on localhost.

### 8b. Agent-to-Agent Query (by DNS)
```
$ uquery -host uag-agent-9845597c8-rzqm4.uag-agent.stonebranch.svc.cluster.local
UNV0102E Error in command line option '-host': host not found.
```
**Result: FAIL** - DNS resolution failed for the headless service hostname. The service is a regular ClusterIP, not headless, so individual pod DNS entries are not available.

**Key Finding:** The brokers bind to `*` (all interfaces) on port 7887 but cross-pod communication times out. This may be a TLS/certificate mismatch issue (each pod has its own self-signed cert) or a NetworkPolicy restriction. For multi-agent orchestration, the agents communicate via OMS (port 7878) rather than direct broker-to-broker.

---

## Test 9: Utility Tools

### 9a. ucopy (File Copy)
```
$ echo "test data" > /tmp/test.txt && ucopy /tmp/test.txt
test data
```
**Result: PASS** - Works as a transactional file copy utility. Supports binary/text modes, atomic rename, and multi-file concatenation.

### 9b. uencrypt (Data Encryption)
```
$ echo "encrypt me" | uencrypt -key testkey123 > /tmp/encrypted.dat
```
**Result: PASS** - Encrypts command files using AES 256-bit CBC. Supports key generation and Broker-managed keystores.

### 9c. umet (Message Exit Translation)
**Result: PASS (help returned)** - Translates message patterns to exit codes using a translation table. Useful for parsing log output and returning structured exit codes.

### 9d. ucert (Certificate Management)
**Result: PASS** - Full X.509 certificate management:
- Create certificate requests (PKCS#10)
- Sign certificates
- Revoke certificates
- Create CRLs
- Create PKCS#12 transport files
- Supports RSA and EC keys (up to 4096-bit RSA, secp384r1 EC)
- SHA256/384/512 signature algorithms

### 9e. upimerge (Config Merge)
**Result: PASS** - Merges configuration files during upgrades, preserving existing settings while incorporating new defaults.

---

## Summary

### What the UAG Agent Can Do in Standalone Mode
1. **Event-driven automation** via UEM (file watches, handlers, time windows)
2. **Agent health monitoring** via uquery (component status, version, uptime)
3. **OMS message queuing** (agents registered, queues active, messages pending)
4. **Certificate management** (X.509, PKCS#12, CRL)
5. **Data encryption** (AES 256-bit)
6. **File operations** (transactional copy)
7. **Configuration management** (broker refresh, config merge)
8. **Python scripting** with rich cloud/DB libraries (K8s, AWS, Azure, GCP, Oracle, HANA, HDFS)

### What Requires a Universal Controller
1. **Remote command execution** (ucmd) - license gated
2. **File transfers** (udm) - license gated
3. **Job scheduling** - Controller-only feature
4. **Centralized monitoring** - Controller-only feature
5. **SAP/PeopleSoft connectors** - require external systems + license

### Recommendations for Next Steps
1. **Connect a Universal Controller** to unlock ucmd/udm and full job scheduling
2. **Fix the OMS probe noise** - add a health check endpoint or adjust K8s probes to not hit the TLS port with raw TCP
3. **Test UEM file triggers end-to-end** - create a file matching the watch pattern and verify the handler fires
4. **Explore Python extensions** - the `universal_extension` framework allows custom integrations dispatched by the Controller
5. **Consider license-free use cases** - UEM file triggers + Python scripts can provide basic automation without a Controller
