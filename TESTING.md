# Testing Guide

This guide shows you how to test all components of the Azure Container Apps platform.

## Table of Contents

1. [Azure Function App Testing](#azure-function-app-testing)
2. [Next.js Application Testing](#nextjs-application-testing)
3. [Playwright E2E Testing](#playwright-e2e-testing)
4. [Infrastructure Testing](#infrastructure-testing)
5. [Performance Testing](#performance-testing)

---

## Azure Function App Testing

The Azure Function App is deployed to Azure Container Apps and provides HTTP endpoints.

### Prerequisites

- Deployed function app (see [function-app/README.md](function-app/README.md))
- `curl` or any HTTP client

### Available Endpoints

#### 1. Health Check Endpoint

Test application health and readiness:

```bash
# Basic health check
curl https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/health

# With response time measurement
curl -w "\nTotal time: %{time_total}s\n" \
  https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/health

# Pretty print JSON response
curl -s https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/health | jq .
```

**Expected Response:**
```json
{
  "status": "healthy",
  "timestamp": "2025-10-08T12:34:56.789012"
}
```

#### 2. Hello World Endpoint

Test the main HTTP-triggered function:

```bash
# Basic request (no parameters)
curl https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello

# With name parameter (query string)
curl "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=Test"

# With response time measurement (your example)
curl -w "%{time_total}\n" \
  "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=Test"

# POST request with JSON body
curl -X POST \
  https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello \
  -H "Content-Type: application/json" \
  -d '{"name": "Azure Container Apps"}'

# With detailed timing information
curl -w "\n\nResponse Time Breakdown:\n  DNS Lookup: %{time_namelookup}s\n  TCP Connect: %{time_connect}s\n  TLS Handshake: %{time_appconnect}s\n  Transfer Start: %{time_starttransfer}s\n  Total: %{time_total}s\n" \
  -s -o /dev/null \
  "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=Test"
```

**Expected Response:**
```json
{
  "message": "Hello, Test! This function scaled from zero to serve your request.",
  "timestamp": "2025-10-08T12:34:56.789012",
  "scaled_from_zero": true
}
```

### Testing Scale-to-Zero Behavior

The function app automatically scales to zero when idle. Test this behavior:

```bash
#!/bin/bash
# Save as: test-scale-to-zero.sh

FUNCTION_URL="https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=ScaleTest"

echo "Testing Scale-to-Zero behavior..."
echo "================================"
echo ""

# Test 1: Initial cold start
echo "1. Cold start test (should take 10-30 seconds):"
time curl -s "$FUNCTION_URL" | jq .
echo ""

# Test 2: Warm instance
echo "2. Warm instance test (should be fast):"
time curl -s "$FUNCTION_URL" | jq .
echo ""

# Test 3: Wait for scale down
echo "3. Waiting 3 minutes for scale-to-zero..."
sleep 180

# Test 4: Cold start again
echo "4. Cold start after scale-to-zero:"
time curl -s "$FUNCTION_URL" | jq .
```

Make it executable and run:
```bash
chmod +x test-scale-to-zero.sh
./test-scale-to-zero.sh
```

### Load Testing

Test concurrent request handling:

```bash
#!/bin/bash
# Simple load test - 100 requests, 10 concurrent
for i in {1..10}; do
  curl -s "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=Load$i" &
done
wait
echo "Load test complete"
```

Or use Apache Bench:
```bash
# Install ab (Apache Bench)
# macOS: brew install httpd (includes ab)
# Ubuntu: sudo apt-get install apache2-utils

# Run load test: 1000 requests, 50 concurrent
ab -n 1000 -c 50 \
  "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=LoadTest"
```

---

## Next.js Application Testing

The web application provides the user interface for the ACA platform.

### Start Development Server

```bash
# Install dependencies (first time only)
npm install

# Start dev server
npm run dev
```

The app will be available at: http://localhost:3002

### Manual Testing Checklist

- [ ] Home page loads (http://localhost:3002)
- [ ] Firebase authentication initializes
- [ ] Login form renders correctly
- [ ] Google Sign-In button appears
- [ ] Test auth page accessible (http://localhost:3002/test-auth)
- [ ] No console errors in browser DevTools
- [ ] No 404 network errors

### Environment Variables

Ensure `.env.local` exists with required Firebase credentials:

```bash
# Check if .env.local exists
ls -la .env.local

# View environment variables (without sensitive values)
grep -v "API_KEY\|SECRET" .env.local || echo "Create .env.local from .env.example"
```

### API Routes Testing

Test Next.js API endpoints:

```bash
# Example: If you have API routes in src/app/api/
curl http://localhost:3002/api/your-endpoint

# With JSON payload
curl -X POST http://localhost:3002/api/your-endpoint \
  -H "Content-Type: application/json" \
  -d '{"key": "value"}'
```

---

## Playwright E2E Testing

Automated browser testing with Playwright.

### Prerequisites

```bash
# Install Playwright browsers (first time only)
npx playwright install
```

### Run Tests

```bash
# Run all tests (headless mode)
npx playwright test

# Run with UI mode (interactive)
npx playwright test --ui

# Run specific test file
npx playwright test tests/simple-investigation.spec.ts

# Run in headed mode (see browser)
npx playwright test --headed

# Run with debug mode
npx playwright test --debug

# Generate and view test report
npx playwright show-report
```

### Available Test Suites

1. **Simple Investigation** (`tests/simple-investigation.spec.ts`)
   - Tests Firebase initialization
   - Validates DOM structure
   - Checks login form elements
   - Inspects /test-auth page

2. **Network Investigation** (`tests/network-investigation.spec.ts`)
   - Monitors network requests
   - Detects failed requests
   - Checks for 404 errors

3. **Detailed Investigation** (`tests/detailed-investigation.spec.ts`)
   - Comprehensive application analysis
   - Error detection and logging

4. **White Page Investigation** (`tests/white-page-investigation.spec.ts`)
   - Debugging blank page issues
   - Console message capture

### Test Configuration

Edit `playwright.config.ts` to customize:

```typescript
export default defineConfig({
  testDir: './tests',
  use: {
    baseURL: 'http://localhost:3002',  // Change port if needed
    trace: 'on-first-retry',
  },
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3002',
  },
});
```

### Writing Custom Tests

Create a new test file in `tests/`:

```typescript
import { test, expect } from '@playwright/test';

test('my custom test', async ({ page }) => {
  await page.goto('/');

  // Your test logic
  await expect(page.locator('h1')).toBeVisible();
});
```

---

## Infrastructure Testing

Validate deployed Azure resources.

### Check Container App Status

```bash
# Set variables (update with your values)
RESOURCE_GROUP="rg-funcapp-dev"
CONTAINER_APP="funcapp-ca-dev"

# Check if container app exists
az containerapp show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --query "{name:name,status:properties.runningStatus,replicas:properties.runningStatus}" \
  -o table

# Check replica count (for scale-to-zero testing)
az containerapp revision list \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --query "[0].properties.replicas" \
  -o tsv

# Monitor replicas in real-time
watch -n 5 "az containerapp show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.runningStatus' -o tsv"
```

### View Logs

```bash
# Stream live logs
az containerapp logs show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --follow

# Get last 50 log entries
az containerapp logs show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --tail 50

# Query logs in Log Analytics
az monitor log-analytics query \
  --workspace <workspace-id> \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == '$CONTAINER_APP' | top 50 by TimeGenerated desc"
```

### Validate Bicep Deployment

```bash
# Validate Bicep template before deployment
az deployment group validate \
  --resource-group $RESOURCE_GROUP \
  --template-file bicep/templates/function-app-deployment.bicep \
  --parameters bicep/parameters/function-app-dev.bicepparam

# Check deployment status
az deployment group list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{name:name, state:properties.provisioningState, timestamp:properties.timestamp}" \
  -o table

# View deployment outputs
az deployment group show \
  --name funcapp-deployment \
  --resource-group $RESOURCE_GROUP \
  --query properties.outputs \
  -o json
```

---

## Performance Testing

### Response Time Benchmarking

```bash
#!/bin/bash
# Save as: benchmark.sh

URL="https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=Benchmark"
REQUESTS=100

echo "Running $REQUESTS requests to measure performance..."
echo "URL: $URL"
echo ""

total_time=0

for i in $(seq 1 $REQUESTS); do
  response_time=$(curl -o /dev/null -s -w '%{time_total}' "$URL")
  total_time=$(echo "$total_time + $response_time" | bc)
  echo "Request $i: ${response_time}s"
done

avg_time=$(echo "scale=3; $total_time / $REQUESTS" | bc)
echo ""
echo "================================"
echo "Average response time: ${avg_time}s"
echo "Total requests: $REQUESTS"
```

### Cold Start vs Warm Start

```bash
#!/bin/bash
# Test cold start performance

URL="https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello"

echo "Measuring cold start (after 3min idle)..."
sleep 180
cold_start=$(curl -o /dev/null -s -w '%{time_total}' "$URL?name=ColdStart")

echo "Measuring warm start..."
warm_start=$(curl -o /dev/null -s -w '%{time_total}' "$URL?name=WarmStart")

echo ""
echo "Cold Start: ${cold_start}s"
echo "Warm Start: ${warm_start}s"
```

---

## Quick Reference

### All Test Commands

```bash
# Azure Function App
curl "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/health"
curl -w "%{time_total}\n" "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=Test"

# Next.js Dev Server
npm run dev
open http://localhost:3002

# Playwright Tests
npx playwright test
npx playwright test --ui

# Azure CLI
az containerapp show --name funcapp-ca-dev --resource-group rg-funcapp-dev
az containerapp logs show --name funcapp-ca-dev --resource-group rg-funcapp-dev --follow
```

### Environment Setup

```bash
# Install dependencies
npm install
npx playwright install

# Start local development
npm run dev

# Run tests
npx playwright test

# Deploy function app
cd function-app
./deploy.sh
```

---

## Troubleshooting

### Function App Not Responding

1. Check if container app is running:
   ```bash
   az containerapp show --name funcapp-ca-dev --resource-group rg-funcapp-dev
   ```

2. Check logs for errors:
   ```bash
   az containerapp logs show --name funcapp-ca-dev --resource-group rg-funcapp-dev --tail 100
   ```

3. Verify image exists in registry:
   ```bash
   az acr repository show --name <registry> --repository function-app
   ```

### Playwright Tests Failing

1. Ensure dev server is running:
   ```bash
   lsof -i :3002
   ```

2. Check for port conflicts:
   ```bash
   # Kill process on port 3002
   lsof -ti:3002 | xargs kill -9
   ```

3. Clear Next.js cache:
   ```bash
   rm -rf .next
   npm run dev
   ```

### Slow Response Times

1. Check if app scaled to zero (cold start):
   - First request after idle: 10-30s
   - Subsequent requests: <1s

2. Check network latency:
   ```bash
   ping funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io
   ```

3. Review Application Insights metrics in Azure Portal

---

## Additional Resources

- [Azure Functions Testing Guide](https://learn.microsoft.com/azure/azure-functions/functions-test-a-function)
- [Playwright Documentation](https://playwright.dev)
- [Next.js Testing](https://nextjs.org/docs/app/building-your-application/testing)
- [Azure Container Apps Monitoring](https://learn.microsoft.com/azure/container-apps/observability)
