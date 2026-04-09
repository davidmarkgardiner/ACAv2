# Stonebranch Universal Automation Center — Full Architecture

## Overview

This document describes the complete Stonebranch deployment when a Universal Controller (UC) license is available. The UC is the scheduling/orchestration brain that unlocks all agent capabilities.

## Component Stack

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Universal Controller (UC)                        │
│                                                                     │
│  ┌─────────────┐ ┌──────────────┐ ┌──────────────┐ ┌────────────┐ │
│  │ Scheduler    │ │ Job Engine   │ │ Calendar     │ │ Dashboard  │ │
│  │ (cron/event) │ │ (chains/deps)│ │ (biz days)   │ │ (web UI)   │ │
│  └─────────────┘ └──────────────┘ └──────────────┘ └────────────┘ │
│                                                                     │
│  Requires: License key, database (PostgreSQL/Oracle/MSSQL)          │
│  Image: stonebranch/universal-controller (not public — licensed)    │
│  Ports: 8080 (web UI), 8443 (HTTPS UI)                             │
└────────────────────────────┬────────────────────────────────────────┘
                             │ Connects to OMS on port 7878
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    OMS (Message Service)                             │
│                                                                     │
│  Message broker between Controller and Agents                       │
│  Image: stonebranch/universal-agent (same image, OMS mode)          │
│  Ports: 7878 (TLS), 7887 (UBroker)                                 │
│  Can run co-located with UC or standalone                           │
└────────────────────────────┬────────────────────────────────────────┘
                             │ Agents connect inbound on 7878
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    UAG Agents (Workers)                              │
│                                                                     │
│  Execute jobs dispatched by the Controller via OMS                  │
│  Image: stonebranch/universal-agent                                 │
│  Ports: 7887 (UBroker)                                              │
│  Deploy as Deployment on each worker cluster                        │
└─────────────────────────────────────────────────────────────────────┘
```

## What the Controller Unlocks

| Feature | Without UC (current POC) | With UC |
|---------|-------------------------|---------|
| Job scheduling (cron) | Not available | Full cron, intervals, calendars |
| Remote command execution | Blocked (license) | `ucmd` executes on any agent |
| File transfers | Blocked (license) | `udm` between any agents |
| Job chains / dependencies | Not available | DAG-style workflows |
| Business calendars | Not available | Holiday-aware scheduling |
| Retry / failure handling | Not available | Auto-retry, escalation, notification |
| Centralized dashboard | Not available | Web UI with real-time status |
| Audit trail | Not available | Full history of all executions |
| RBAC / multi-tenant | Not available | Role-based access control |
| SAP / PeopleSoft / Oracle | Blocked | Native connectors |
| REST API triggers | Not available | API to submit/monitor jobs |
| Email / webhook notifications | Not available | Alert on success/failure |
| SLA monitoring | Not available | Track job SLA compliance |
| Forecasting | Not available | Predict job runtimes |

## Production Deployment Architecture

### Management Cluster (AKS)

```
┌─────────────────────────────────────────────────────────────────┐
│  Management Cluster                                             │
│                                                                 │
│  ┌──────────────────────┐  ┌──────────────────────┐            │
│  │ Universal Controller │  │ PostgreSQL            │            │
│  │ (Deployment, 2 pods) │  │ (StatefulSet, HA)     │            │
│  │ Ports: 8080, 8443    │──│ Stores: jobs, history │            │
│  └──────────┬───────────┘  └──────────────────────┘            │
│             │                                                   │
│  ┌──────────▼───────────┐                                      │
│  │ OMS Server           │                                      │
│  │ (Deployment, 1 pod)  │                                      │
│  │ Port 7878 (TLS)      │                                      │
│  │                      │                                      │
│  │ Exposed via:         │                                      │
│  │  Istio Gateway       │                                      │
│  │  (TLS passthrough)   │                                      │
│  └──────────────────────┘                                      │
└─────────────────────────────────────────────────────────────────┘
        ▲                    ▲                    ▲
        │                    │                    │
   Worker 1              Worker 2             Worker N
   UAG ×3                UAG ×3               UAG ×3
```

### Worker Clusters (AKS)

Each worker cluster runs only UAG agents:

```yaml
# Per worker cluster:
- Namespace: stonebranch
- Deployment: uag-agent (2-5 replicas)
- No OMS, no Controller
- Outbound TCP to mgmt OMS on 7878
- No inbound ports required
```

## Kubernetes Manifests (When License Available)

### Universal Controller Deployment

```yaml
# NOTE: This is a template — actual image requires Stonebranch license
# The UC image is NOT on public Docker Hub
apiVersion: apps/v1
kind: Deployment
metadata:
  name: universal-controller
  namespace: stonebranch
spec:
  replicas: 1     # Start with 1, scale to 2 for HA
  selector:
    matchLabels:
      app: universal-controller
  template:
    metadata:
      labels:
        app: universal-controller
    spec:
      containers:
      - name: uc
        image: <stonebranch-registry>/universal-controller:<version>
        ports:
        - name: http
          containerPort: 8080
        - name: https
          containerPort: 8443
        env:
        # Database connection (PostgreSQL recommended)
        - name: UC_DB_TYPE
          value: "postgresql"
        - name: UC_DB_HOST
          valueFrom:
            secretKeyRef:
              name: uc-db-credentials
              key: host
        - name: UC_DB_PORT
          value: "5432"
        - name: UC_DB_NAME
          value: "universalcontroller"
        - name: UC_DB_USER
          valueFrom:
            secretKeyRef:
              name: uc-db-credentials
              key: username
        - name: UC_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: uc-db-credentials
              key: password
        # OMS connection
        - name: UC_OMS_SERVERS
          value: "7878@oms-server.stonebranch.svc.cluster.local"
        # License key
        - name: UC_LICENSE_KEY
          valueFrom:
            secretKeyRef:
              name: uc-license
              key: license-key
        resources:
          requests:
            cpu: 500m
            memory: 2Gi
          limits:
            cpu: "2"
            memory: 4Gi
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: universal-controller
  namespace: stonebranch
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  - name: https
    port: 8443
    targetPort: 8443
  selector:
    app: universal-controller
```

### PostgreSQL for Controller State

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: uc-postgresql
  namespace: stonebranch
spec:
  serviceName: uc-postgresql
  replicas: 1
  selector:
    matchLabels:
      app: uc-postgresql
  template:
    metadata:
      labels:
        app: uc-postgresql
    spec:
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: universalcontroller
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: uc-db-credentials
              key: username
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: uc-db-credentials
              key: password
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: longhorn   # or managed-premium on AKS
      resources:
        requests:
          storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: uc-postgresql
  namespace: stonebranch
spec:
  type: ClusterIP
  ports:
  - port: 5432
  selector:
    app: uc-postgresql
```

### Secrets Template

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: uc-db-credentials
  namespace: stonebranch
type: Opaque
stringData:
  host: "uc-postgresql.stonebranch.svc.cluster.local"
  username: "ucadmin"
  password: "<change-me>"
---
apiVersion: v1
kind: Secret
metadata:
  name: uc-license
  namespace: stonebranch
type: Opaque
stringData:
  license-key: "<obtain-from-stonebranch-or-colleague>"
```

## Integration with Existing Infrastructure

### Istio (AKS Add-on)

The UC web UI can be exposed via standard Istio HTTP Gateway:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: uc-gateway
  namespace: stonebranch
spec:
  selector:
    istio: aks-istio-ingressgateway-internal
  servers:
  - port:
      number: 443
      name: https-uc
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: uc-tls-cert
    hosts:
    - "uc.your-domain.com"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: uc-vs
  namespace: stonebranch
spec:
  hosts:
  - "uc.your-domain.com"
  gateways:
  - uc-gateway
  http:
  - route:
    - destination:
        host: universal-controller.stonebranch.svc.cluster.local
        port:
          number: 8443
```

OMS stays on TLS passthrough (see `06-istio-gateway.yaml`).

### Authentik SSO

The UC supports SAML/OIDC. If you use Authentik:

```
UC Settings → Authentication → SAML 2.0
  IdP Metadata URL: https://authentik.your-domain.com/...
  Entity ID: stonebranch-uc
  NameID: email
```

### Argo Workflows Integration

The UC REST API can trigger Argo Workflows and vice versa:

```
Argo Workflow step → curl UC REST API → UC schedules job on agent
UC job completes → webhook → Argo Events → trigger next workflow
```

## Deployment Checklist (When License Available)

- [ ] Obtain UC license key from colleague / Stonebranch
- [ ] Obtain UC container image (private registry — not Docker Hub)
- [ ] Deploy PostgreSQL on management cluster
- [ ] Deploy UC with license key and DB connection
- [ ] Verify UC web UI accessible
- [ ] Connect UC to existing OMS (already running)
- [ ] Verify agents register in UC dashboard
- [ ] Create first test job: run `echo "hello world"` on a worker agent
- [ ] Create first cron schedule: run test job every 5 minutes
- [ ] Test file transfer between agents on different clusters
- [ ] Configure Authentik SSO for UC web UI
- [ ] Document access for team

## Stonebranch Contacts / Resources

- **License requests**: Contact your Stonebranch account manager or internal colleague who holds the license
- **Docs**: https://stonebranchdocs.atlassian.net/
- **Docker Hub**: https://hub.docker.com/r/stonebranch/universal-agent (agents only — UC image is private)
- **Kubernetes Guide**: https://stonebranchdocs.atlassian.net/wiki/spaces/SD/pages/1953923073/Kubernetes+Start-Up+Guide
- **OpenShift Operator**: Available via Red Hat Marketplace (if using OpenShift)
