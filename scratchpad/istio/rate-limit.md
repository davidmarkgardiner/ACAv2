## 1. **Istio Local Rate Limiting (Quickest Win)**

Apply an EnvoyFilter to rate limit requests to OpenAI at the sidecar level:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: openai-rate-limit
  namespace: your-namespace
spec:
  workloadSelector:
    labels:
      app: your-app
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_OUTBOUND
      listener:
        filterChain:
          filter:
            name: "envoy.filters.network.http_connection_manager"
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.local_ratelimit
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
          stat_prefix: http_local_rate_limiter
          token_bucket:
            max_tokens: 100  # adjust based on your OpenAI tier
            tokens_per_fill: 20
            fill_interval: 60s
          filter_enabled:
            runtime_key: local_rate_limit_enabled
            default_value:
              numerator: 100
              denominator: HUNDRED
          filter_enforced:
            runtime_key: local_rate_limit_enforced
            default_value:
              numerator: 100
              denominator: HUNDRED
          response_headers_to_add:
            - append: false
              header:
                key: x-local-rate-limit
                value: 'true'
```

## 2. **Circuit Breaker with DestinationRule**

Prevent cascading failures when OpenAI is rate limiting:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: openai-circuit-breaker
  namespace: your-namespace
spec:
  host: api.openai.com
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 10
      http:
        http1MaxPendingRequests: 5
        http2MaxRequests: 10
        maxRequestsPerConnection: 2
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
```

## 3. **VirtualService with Retry Logic**

Handle 429 responses gracefully:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: openai-vs
  namespace: your-namespace
spec:
  hosts:
  - api.openai.com
  http:
  - match:
    - uri:
        prefix: "/v1/"
    retries:
      attempts: 3
      perTryTimeout: 30s
      retryOn: "429,5xx,reset,refused-stream"
      retryRemoteLocalities: false
    timeout: 90s
    route:
    - destination:
        host: api.openai.com
```

## 4. **Application-Level Token Bucket (Most Control)**

If you need more sophisticated logic, implement a token bucket in your app with Redis:

```yaml
# ConfigMap for rate limit config
apiVersion: v1
kind: ConfigMap
metadata:
  name: openai-rate-limits
data:
  max_tokens_per_minute: "3500"  # TPM limit
  max_requests_per_minute: "100"  # RPM limit
```

Then in your app, check the bucket before making OpenAI calls and return 429 early if depleted.

## 5. **ServiceEntry for OpenAI**

Ensure you have proper ServiceEntry so Istio can apply policies:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: openai-api
  namespace: your-namespace
spec:
  hosts:
  - api.openai.com
  ports:
  - number: 443
    name: https
    protocol: HTTPS
  location: MESH_EXTERNAL
  resolution: DNS
```

## **My Recommendation**

Start with **#1 (EnvoyFilter rate limiting)** + **#2 (Circuit Breaker)** - this gives you immediate protection without app changes. The EnvoyFilter will queue requests when limits are approached, and the circuit breaker will fail fast when OpenAI is consistently returning errors.

Monitor with:
```bash
kubectl logs -l app=your-app -c istio-proxy | grep rate_limit
```
