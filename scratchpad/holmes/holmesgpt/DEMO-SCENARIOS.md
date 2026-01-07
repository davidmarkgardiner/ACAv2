# Holmes + AKS-MCP Auto-Remediation Demo Scenarios

Interactive demos where you break something and Holmes/AKS-MCP **automatically diagnoses AND fixes it**.

## How Auto-Remediation Works

Holmes is configured with:
1. **MCP Integration**: Connected to AKS-MCP server for kubectl/helm/az CLI tools
2. **Built-in toolsets disabled**: Forces Holmes to use AKS-MCP for all operations
3. **llm_instructions**: Tells Holmes to EXECUTE fixes, not just diagnose
4. **Custom runbooks**: Step-by-step remediation guidance with fix commands

When you ask Holmes to investigate, it will:
1. **Diagnose** using `kubectl_get`, `kubectl_describe`, `kubectl_logs`
2. **Identify** the root cause
3. **EXECUTE** the fix using `kubectl_patch`, `kubectl_set`, `kubectl_rollout`
4. **Verify** the fix worked

## Prerequisites

- Holmes deployed with MCP enabled (`instance-updated.yaml`)
- AKS-MCP deployed and accessible
- LiteLLM gateway running

```bash
# Port-forward to Holmes
kubectl port-forward -n holmesgpt svc/holmesgpt-holmes 5050:80
```

---

## Scenario 1: OOMKilled Pod (Easy) - AUTO-FIX

**Break it:**
```bash
# Deploy a memory-hungry pod that will get OOMKilled
kubectl create namespace demo
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: memory-hog
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: memory-hog
  template:
    metadata:
      labels:
        app: memory-hog
    spec:
      containers:
      - name: stress
        image: polinux/stress
        command: ["stress"]
        args: ["--vm", "1", "--vm-bytes", "500M", "--vm-hang", "1"]
        resources:
          limits:
            memory: "128Mi"
          requests:
            memory: "64Mi"
EOF

# Wait for it to crash
kubectl get pods -n demo -w
# Should show OOMKilled or CrashLoopBackOff
```

**Ask Holmes to AUTO-FIX:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Pod keeps restarting - please fix it",
    "description": "The memory-hog pod in demo namespace keeps crashing with OOMKilled. Diagnose and fix the issue.",
    "subject": {"name": "memory-hog", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected Holmes Actions:**
1. `kubectl_get pods -n demo` - See OOMKilled status
2. `kubectl_describe pod memory-hog-xxx -n demo` - See memory limit 128Mi
3. `kubectl_logs memory-hog-xxx -n demo` - See stress trying to use 500M
4. **AUTO-FIX**: `kubectl_set resources deployment/memory-hog -n demo --limits=memory=1Gi`
5. `kubectl_rollout status deployment/memory-hog -n demo` - Verify fix

**Verify Auto-Remediation:**
```bash
# Check if Holmes increased the memory limit
kubectl get deployment memory-hog -n demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
# Should now show "1Gi" instead of "128Mi"

# Check pod is running
kubectl get pods -n demo
# Should show Running, not OOMKilled
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Scenario 2: ImagePullBackOff (Medium) - AUTO-FIX

**Break it:**
```bash
kubectl create namespace demo

# Deploy with a non-existent image tag
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad-image
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bad-image
  template:
    metadata:
      labels:
        app: bad-image
    spec:
      containers:
      - name: app
        image: nginx:this-tag-does-not-exist-12345
EOF

# Watch it fail
kubectl get pods -n demo -w
# Should show ImagePullBackOff
```

**Ask Holmes to AUTO-FIX:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Pod stuck in ImagePullBackOff - fix it",
    "description": "Deployment bad-image in demo namespace cannot start. Diagnose and fix the issue.",
    "subject": {"name": "bad-image", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected Holmes Actions:**
1. `kubectl_get pods -n demo` - See ImagePullBackOff
2. `kubectl_describe pod bad-image-xxx -n demo` - See image pull error
3. `kubectl_events -n demo` - See "manifest unknown" error
4. **AUTO-FIX**: `kubectl_set image deployment/bad-image -n demo app=nginx:latest`
5. `kubectl_rollout status deployment/bad-image -n demo` - Verify fix

**Verify Auto-Remediation:**
```bash
# Check if Holmes updated the image
kubectl get deployment bad-image -n demo -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should now show "nginx:latest"

# Check pod is running
kubectl get pods -n demo
# Should show Running, not ImagePullBackOff
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Scenario 3: Service Misconfiguration (Medium) - AUTO-FIX

**Break it:**
```bash
kubectl create namespace demo

# Deploy nginx with WRONG service selector
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: demo
spec:
  selector:
    app: wrong-label  # WRONG! Should be "web"
  ports:
  - port: 80
    targetPort: 80
EOF

# Test - this will fail/timeout
kubectl run curl --rm -it --image=curlimages/curl --restart=Never -n demo -- curl -s --max-time 5 http://web || echo "Connection failed as expected"
```

**Ask Holmes to AUTO-FIX:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Service not working - fix it",
    "description": "Cannot connect to web service in demo namespace, curl times out. Diagnose and fix.",
    "subject": {"name": "web", "namespace": "demo", "kind": "Service"},
    "context": {}
  }'
```

**Expected Holmes Actions:**
1. `kubectl_get svc web -n demo -o yaml` - See selector `app: wrong-label`
2. `kubectl_get pods -n demo --show-labels` - See pods have `app: web`
3. `kubectl_get endpoints web -n demo` - See no endpoints
4. **AUTO-FIX**: `kubectl_patch svc web -n demo -p '{"spec":{"selector":{"app":"web"}}}'`
5. `kubectl_get endpoints web -n demo` - Verify endpoints populated

**Verify Auto-Remediation:**
```bash
# Check if Holmes fixed the selector
kubectl get svc web -n demo -o jsonpath='{.spec.selector.app}'
# Should now show "web" instead of "wrong-label"

# Check endpoints are populated
kubectl get endpoints web -n demo
# Should show pod IPs

# Test connectivity
kubectl run curl --rm -it --image=curlimages/curl --restart=Never -n demo -- curl -s http://web
# Should return nginx welcome page
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Scenario 4: CrashLoopBackOff - Missing ConfigMap (Hard) - AUTO-FIX

**Break it:**
```bash
kubectl create namespace demo

# Deploy app that requires a ConfigMap that doesn't exist
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-app
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: config-app
  template:
    metadata:
      labels:
        app: config-app
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "cat /config/settings.conf && sleep 3600"]
        volumeMounts:
        - name: config
          mountPath: /config
      volumes:
      - name: config
        configMap:
          name: app-settings  # This ConfigMap doesn't exist!
EOF

# Watch it fail
kubectl get pods -n demo -w
# Should show CreateContainerConfigError or similar
```

**Ask Holmes to AUTO-FIX:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Pod cannot start - fix it",
    "description": "config-app deployment pods are stuck and cannot start. Diagnose and fix the issue.",
    "subject": {"name": "config-app", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected Holmes Actions:**
1. `kubectl_get pods -n demo` - See CreateContainerConfigError
2. `kubectl_describe pod config-app-xxx -n demo` - See ConfigMap not found
3. `kubectl_get configmap -n demo` - Confirm app-settings missing
4. **AUTO-FIX**: `kubectl_create configmap app-settings -n demo --from-literal=settings.conf="# Default config"`
5. `kubectl_rollout restart deployment/config-app -n demo` - Trigger new pod
6. `kubectl_rollout status deployment/config-app -n demo` - Verify running

**Verify Auto-Remediation:**
```bash
# Check if Holmes created the ConfigMap
kubectl get configmap app-settings -n demo
# Should exist

# Check pod is running
kubectl get pods -n demo
# Should show Running
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Scenario 5: Stuck Deployment - Rollback (Medium) - AUTO-FIX

**Break it:**
```bash
kubectl create namespace demo

# Deploy working version first
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: app
        image: nginx:1.21
EOF

# Wait for it to be ready
kubectl rollout status deployment/myapp -n demo

# Now deploy bad version
kubectl set image deployment/myapp -n demo app=nginx:nonexistent-bad-tag

# Watch it get stuck
kubectl rollout status deployment/myapp -n demo --timeout=30s || echo "Rollout stuck as expected"
```

**Ask Holmes to AUTO-FIX:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Deployment stuck during rollout - fix it",
    "description": "myapp deployment is stuck and not progressing. Rollback if needed.",
    "subject": {"name": "myapp", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected Holmes Actions:**
1. `kubectl_rollout status deployment/myapp -n demo` - See stuck
2. `kubectl_get pods -n demo` - See new pods in ImagePullBackOff
3. `kubectl_rollout history deployment/myapp -n demo` - See previous versions
4. **AUTO-FIX**: `kubectl_rollout undo deployment/myapp -n demo`
5. `kubectl_rollout status deployment/myapp -n demo` - Verify rollback complete

**Verify Auto-Remediation:**
```bash
# Check if Holmes rolled back
kubectl get deployment myapp -n demo -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show "nginx:1.21" (rolled back)

# Check deployment is healthy
kubectl rollout status deployment/myapp -n demo
# Should complete successfully
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Scenario 6: ResourceQuota Exceeded (Hard) - DIAGNOSIS ONLY

**Note:** This scenario requires human decision - Holmes will diagnose but suggest options.

**Break it:**
```bash
kubectl create namespace demo

# Create restrictive ResourceQuota
kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: demo-quota
  namespace: demo
spec:
  hard:
    pods: "2"
    requests.cpu: "500m"
    requests.memory: "512Mi"
EOF

# Try to deploy 5 replicas
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quota-test
  namespace: demo
spec:
  replicas: 5
  selector:
    matchLabels:
      app: quota-test
  template:
    metadata:
      labels:
        app: quota-test
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
EOF

# Check - only 2 pods will be created
kubectl get pods -n demo
kubectl get events -n demo --sort-by='.lastTimestamp' | tail -10
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Deployment not scaling",
    "description": "quota-test deployment should have 5 replicas but only 2 are running",
    "subject": {"name": "quota-test", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected Holmes Response:**
- Diagnoses ResourceQuota blocking new pods
- **Suggests options** (requires human decision):
  - Option 1: Increase quota `kubectl patch resourcequota demo-quota...`
  - Option 2: Reduce resource requests

**Manual Fix (choose one):**
```bash
# Option 1: Increase quota
kubectl patch resourcequota demo-quota -n demo -p '{"spec":{"hard":{"pods":"10","requests.cpu":"2"}}}'

# Option 2: Reduce resource requests
kubectl patch deployment quota-test -n demo -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","resources":{"requests":{"cpu":"50m","memory":"64Mi"}}}]}}}}'
```

**Cleanup:**
```bash
kubectl delete namespace demo
```

---

## Testing Holmes API

### Health check:
```bash
curl http://localhost:5050/healthz
# {"status":"healthy"}
```

### Check MCP tools available:
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "test",
    "title": "List available tools",
    "description": "What kubectl commands can you run?",
    "subject": {"name": "cluster", "namespace": "default"},
    "context": {}
  }'
```

### Stream response (for long investigations):
```bash
curl -N -X POST http://localhost:5050/api/stream/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "manual",
    "title": "Cluster health check - fix any issues",
    "description": "Check overall cluster health and automatically fix any issues found",
    "subject": {"name": "cluster", "namespace": "default"},
    "context": {}
  }'
```

---

## Scenario 7: Kyverno Policy Blocking (Medium) - DIAGNOSIS ONLY

**Note:** Policy violations require human decision on proper labels.

**Break it:**
```bash
kubectl create namespace demo

# Create a policy that requires labels
kubectl apply -f - <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-team-label
    match:
      any:
      - resources:
          kinds:
          - Deployment
          namespaces:
          - demo
    validate:
      message: "Deployment must have 'team' label"
      pattern:
        metadata:
          labels:
            team: "?*"
EOF

# Try to deploy without the required label - will be DENIED
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-label-app
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: no-label-app
  template:
    metadata:
      labels:
        app: no-label-app
    spec:
      containers:
      - name: nginx
        image: nginx:latest
EOF
# Error: admission webhook denied the request
```

**Ask Holmes:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "Deployment blocked by admission webhook",
    "description": "Cannot create deployment no-label-app in demo namespace",
    "subject": {"name": "no-label-app", "namespace": "demo", "kind": "Deployment"},
    "context": {}
  }'
```

**Expected Holmes Response:**
- Identifies Kyverno policy `require-team-label` blocking deployment
- Explains required `team` label
- Suggests adding label to deployment

**Manual Fix:**
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-label-app
  namespace: demo
  labels:
    team: platform  # Add required label
spec:
  replicas: 1
  selector:
    matchLabels:
      app: no-label-app
  template:
    metadata:
      labels:
        app: no-label-app
        team: platform
    spec:
      containers:
      - name: nginx
        image: nginx:latest
EOF
```

**Cleanup:**
```bash
kubectl delete clusterpolicy require-team-label
kubectl delete namespace demo
```

---

## Scenario 8: KRO Instance Stuck (Hard) - AUTO-FIX

**Break it:**
```bash
# Apply a ResourceGraphDefinition with a bad image
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: demo-app
spec:
  schema:
    apiVersion: v1alpha1
    kind: DemoApp
    spec:
      name: string | default=demo
      namespace: string | default=demo
    status:
      ready: \${deployment.status.availableReplicas}
  resources:
    - id: ns
      template:
        apiVersion: v1
        kind: Namespace
        metadata:
          name: \${schema.spec.namespace}
    - id: deployment
      template:
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: \${schema.spec.name}
          namespace: \${schema.spec.namespace}
        spec:
          replicas: 1
          selector:
            matchLabels:
              app: demo
          template:
            metadata:
              labels:
                app: demo
            spec:
              containers:
              - name: nginx
                image: nginx:nonexistent-tag-12345  # Bad image!
EOF

# Wait for RGD to be ready
sleep 5

# Create an instance
kubectl apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: DemoApp
metadata:
  name: my-demo
  namespace: kro
spec:
  name: demo
  namespace: demo
EOF

# Check status - deployment will be stuck
sleep 10
kubectl get pods -n demo
```

**Ask Holmes to AUTO-FIX:**
```bash
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "demo",
    "title": "KRO instance not ready - fix it",
    "description": "DemoApp my-demo in kro namespace is stuck. Fix the underlying issue.",
    "subject": {"name": "my-demo", "namespace": "kro", "kind": "DemoApp"},
    "context": {}
  }'
```

**Expected Holmes Actions:**
1. `kubectl_get demoapp my-demo -n kro` - See not ready
2. `kubectl_get pods -n demo` - See ImagePullBackOff
3. `kubectl_describe pod -n demo` - See image pull error
4. **AUTO-FIX**: `kubectl_set image deployment/demo -n demo nginx=nginx:latest`
5. `kubectl_rollout status deployment/demo -n demo` - Verify running

**Verify Auto-Remediation:**
```bash
# Check if Holmes fixed the image
kubectl get deployment demo -n demo -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show "nginx:latest"

# Check KRO instance status
kubectl get demoapp my-demo -n kro
# Should show ready
```

**Cleanup:**
```bash
kubectl delete demoapp my-demo -n kro
kubectl delete resourcegraphdefinition demo-app
kubectl delete namespace demo
```

---

## Auto-Remediation Summary

| Scenario | Auto-Fix? | Holmes Action |
|----------|-----------|---------------|
| OOMKilled | ✅ Yes | `kubectl set resources --limits=memory=1Gi` |
| ImagePullBackOff | ✅ Yes | `kubectl set image ... nginx:latest` |
| Service Selector | ✅ Yes | `kubectl patch svc -p '{"spec":{"selector":...}}'` |
| Missing ConfigMap | ✅ Yes | `kubectl create configmap ...` |
| Stuck Rollout | ✅ Yes | `kubectl rollout undo` |
| ResourceQuota | ❌ No | Suggests options (human decides) |
| Kyverno Policy | ❌ No | Explains policy (human adds labels) |
| KRO Instance | ✅ Yes | Fixes underlying deployment issue |

**Key Phrases to Trigger Auto-Fix:**
- "fix it"
- "fix the issue"
- "diagnose and fix"
- "please fix"
- "automatically fix"
