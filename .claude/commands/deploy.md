---
allowed-tools: Read, Write, MultiEdit, Bash
description: Prepare the Modern Business application for production deployment with comprehensive checks, optimizations, and deployment configurations
---

# /deploy - Deployment Preparation

Prepare the Modern Business application for production deployment with comprehensive checks, optimizations, and deployment configurations.

## Usage

```
/deploy [--platform=vercel|netlify|railway] [--env=staging|production] [--check-only]
```

## Examples

```
/deploy --platform=vercel --env=production
/deploy --platform=railway --env=staging
/deploy --check-only
```

## What this command does:

1. **Runs comprehensive checks** for production readiness

2. **Optimizes build configuration** for the target platform

3. **Validates environment variables** and secrets

4. **Tests database migrations** and connections

5. **Verifies payment integrations** (Stripe webhooks)

6. **Generates deployment configurations** for the chosen platform

7. **Creates deployment documentation** and rollback procedures

## Pre-Deployment Checklist:

### ✅ Code Quality Checks
```bash
# TypeScript compilation
npm run build

# Linting and formatting
npm run lint
npm run format

# Unit tests
npm run test

# E2E tests
npm run test:e2e
```

### ✅ Security Validation
```bash
# Environment variable validation
- PUBLIC_SUPABASE_URL ✓
- PUBLIC_SUPABASE_ANON_KEY ✓
- SUPABASE_SERVICE_ROLE_KEY ✓
- PUBLIC_STRIPE_PUBLISHABLE_KEY ✓
- STRIPE_SECRET_KEY ✓
- STRIPE_WEBHOOK_SECRET ✓

# Database RLS policies active ✓
# API endpoints protected ✓
# Sensitive data not in client bundle ✓
```

### ✅ Performance Optimization
```bash
# Bundle size analysis
npm run analyze

# Core Web Vitals check
npm run lighthouse

# Image optimization
npm run optimize-images

# CSS purging (Tailwind)
npm run build:css
```

## Platform-Specific Configurations:

### Vercel Deployment (--platform=vercel)

#### `vercel.json`
```json
{
  "framework": "astro",
  "buildCommand": "npm run build",
  "outputDirectory": "dist",
  "devCommand": "npm run dev",
  "installCommand": "npm install",
  "functions": {
    "src/pages/api/**/*.ts": {
      "runtime": "@vercel/node"
    }
  },
  "rewrites": [
    {
      "source": "/api/(.*)",
      "destination": "/api/$1"
    }
  ],
  "headers": [
    {
      "source": "/api/(.*)",
      "headers": [
        {
          "key": "Access-Control-Allow-Origin",
          "value": "*"
        },
        {
          "key": "Access-Control-Allow-Methods",
          "value": "GET, POST, PUT, DELETE, OPTIONS"
        }
      ]
    }
  ],
  "env": {
    "PUBLIC_SUPABASE_URL": "@public_supabase_url",
    "PUBLIC_SUPABASE_ANON_KEY": "@public_supabase_anon_key",
    "SUPABASE_SERVICE_ROLE_KEY": "@supabase_service_role_key",
    "PUBLIC_STRIPE_PUBLISHABLE_KEY": "@public_stripe_publishable_key",
    "STRIPE_SECRET_KEY": "@stripe_secret_key",
    "STRIPE_WEBHOOK_SECRET": "@stripe_webhook_secret"
  }
}
```

### Railway Deployment (--platform=railway)

#### `railway.toml`
```toml
[build]
builder = "nixpacks"
buildCommand = "npm run build"

[deploy]
startCommand = "npm start"
healthcheckPath = "/api/health"
healthcheckTimeout = 100
restartPolicyType = "on_failure"
restartPolicyMaxRetries = 10

[environments.production]
RAILWAY_STATIC_URL = "https://your-app.railway.app"

[environments.staging]
RAILWAY_STATIC_URL = "https://staging-your-app.railway.app"
```

#### `Dockerfile` (if needed)
```dockerfile
FROM node:18-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY . .
RUN npm run build

EXPOSE 3000

CMD ["npm", "start"]
```

### Netlify Deployment (--platform=netlify)

#### `netlify.toml`
```toml
[build]
  publish = "dist"
  command = "npm run build"

[build.environment]
  NODE_VERSION = "18"

[[redirects]]
  from = "/api/*"
  to = "/.netlify/functions/:splat"
  status = 200

[[headers]]
  for = "/api/*"
  [headers.values]
    Access-Control-Allow-Origin = "*"
    Access-Control-Allow-Headers = "Content-Type"
    Access-Control-Allow-Methods = "GET, POST, PUT, DELETE"

[functions]
  directory = "netlify/functions"
  node_bundler = "esbuild"
```

## Database Migration Strategy:

### Supabase Migration Checklist
```sql
-- Verify all tables have RLS enabled
SELECT schemaname, tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'public' AND rowsecurity = false;

-- Check RLS policies exist
SELECT schemaname, tablename, policyname, roles, cmd, qual
FROM pg_policies
WHERE schemaname = 'public';

-- Verify indexes for performance
SELECT indexname, tablename, indexdef
FROM pg_indexes
WHERE schemaname = 'public';

-- Test critical queries performance
EXPLAIN ANALYZE SELECT * FROM products WHERE is_active = true;
EXPLAIN ANALYZE SELECT * FROM class_schedules WHERE scheduled_date >= CURRENT_DATE;
```

### Migration Execution
```bash
# Apply pending migrations
npx supabase db push

# Generate new types
npx supabase gen types typescript --project-id YOUR_PROJECT_ID > src/types/database.ts

# Seed production data (if needed)
npx supabase db seed
```

## Stripe Webhook Configuration:

### Webhook Endpoints Setup
```typescript
// Required webhook events for coffee shop
const coffeeWebhookEvents = [
  'payment_intent.succeeded',
  'payment_intent.payment_failed',
  'charge.dispute.created'
]

// Required webhook events for yoga studio
const yogaWebhookEvents = [
  'customer.subscription.created',
  'customer.subscription.updated',
  'customer.subscription.deleted',
  'invoice.payment_succeeded',
  'invoice.payment_failed'
]

// Webhook endpoint URLs
const webhookEndpoints = {
  production: 'https://your-domain.com/api/webhooks/stripe',
  staging: 'https://staging-your-domain.com/api/webhooks/stripe'
}
```

### Webhook Testing
```bash
# Test webhook delivery
stripe listen --forward-to localhost:4321/api/webhooks/stripe

# Send test events
stripe trigger payment_intent.succeeded
stripe trigger customer.subscription.created
```

## Environment Configuration:

### Production Environment Variables
```bash
# Supabase
PUBLIC_SUPABASE_URL=https://your-project.supabase.co
PUBLIC_SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key

# Stripe
PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_live_your-publishable-key
STRIPE_SECRET_KEY=sk_live_your-secret-key
STRIPE_WEBHOOK_SECRET=whsec_your-webhook-secret

# Application
PUBLIC_APP_URL=https://your-domain.com
NODE_ENV=production
```

### Staging Environment Variables
```bash
# Supabase (staging project)
PUBLIC_SUPABASE_URL=https://staging-project.supabase.co
PUBLIC_SUPABASE_ANON_KEY=staging-anon-key
SUPABASE_SERVICE_ROLE_KEY=staging-service-role-key

# Stripe (test mode)
PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_test_your-test-key
STRIPE_SECRET_KEY=sk_test_your-test-key
STRIPE_WEBHOOK_SECRET=whsec_test-webhook-secret

# Application
PUBLIC_APP_URL=https://staging-your-domain.com
NODE_ENV=staging
```

## Performance Monitoring Setup:

### Monitoring Configuration
```typescript
// Monitor Core Web Vitals
export function initPerformanceMonitoring() {
  // Setup performance observers
  if (typeof window !== 'undefined') {
    import('web-vitals').then(({ getCLS, getFID, getFCP, getLCP, getTTFB }) => {
      getCLS(sendToAnalytics)
      getFID(sendToAnalytics)
      getFCP(sendToAnalytics)
      getLCP(sendToAnalytics)
      getTTFB(sendToAnalytics)
    })
  }
}

function sendToAnalytics(metric: any) {
  // Send to your analytics service
  console.log(metric)
}
```

## Rollback Strategy:

### Database Rollback
```sql
-- Create rollback scripts for each migration
-- rollback_001.sql
DROP TABLE IF EXISTS new_table CASCADE;
ALTER TABLE existing_table DROP COLUMN new_column;

-- Version tracking
INSERT INTO migration_history (version, rollback_script, created_at)
VALUES ('v1.2.0', 'rollback_001.sql', NOW());
```

### Application Rollback
```bash
# Git-based rollback
git revert HEAD~1
git push origin main

# Platform-specific rollback
vercel --prod rollback
railway rollback
netlify sites:rollback
```

## Health Check Endpoints:

### System Health Check
```typescript
// src/pages/api/health.ts
export const GET: APIRoute = async () => {
  const health = {
    status: 'healthy',
    timestamp: new Date().toISOString(),
    services: {
      database: await checkDatabase(),
      stripe: await checkStripe(),
      storage: await checkStorage()
    }
  }

  const isHealthy = Object.values(health.services).every(service => service.status === 'ok')

  return new Response(JSON.stringify(health), {
    status: isHealthy ? 200 : 503,
    headers: { 'Content-Type': 'application/json' }
  })
}
```

## Deployment Execution:

### Automated Deployment Script
```bash
#!/bin/bash
set -e

echo "🚀 Starting deployment preparation..."

# Run checks
npm run build
npm run test
npm run test:e2e

# Optimize assets
npm run optimize

# Deploy based on platform
case $PLATFORM in
  "vercel")
    npx vercel --prod
    ;;
  "railway")
    railway up --detach
    ;;
  "netlify")
    npx netlify deploy --prod --dir=dist
    ;;
esac

echo "✅ Deployment completed successfully!"
```

## Files Created:
- Platform-specific configuration files
- Deployment scripts and documentation
- Health check endpoints
- Performance monitoring setup
- Rollback procedures and scripts

## Success Criteria:
- All tests pass (unit, integration, E2E)
- Performance metrics meet targets (Core Web Vitals)
- Security scans show no vulnerabilities
- Database migrations execute successfully
- Stripe webhooks are configured and tested
- Environment variables are properly set
- Health checks respond correctly
- Rollback procedures are documented and tested