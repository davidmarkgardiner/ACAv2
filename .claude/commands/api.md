---
allowed-tools: Read, Write, MultiEdit, Bash
description: Generate a new Astro API endpoint with TypeScript, Supabase integration, and proper error handling for the Modern Business template
---

# /api - Create API Endpoint

Generate a new Astro API endpoint with TypeScript, Supabase integration, and proper error handling for the Modern Business template.

## Usage

```
/api endpoint-name [--type=retail|service|shared] [--method=GET|POST|PUT|DELETE] [--auth]
```

## Examples

```
/api products --type=retail --method=GET
/api book-service --type=service --method=POST --auth
/api stripe-webhook --type=shared --method=POST
```

## What this command does:

1. **Creates API endpoint file** in `src/pages/api/[category]/`

2. **Generates TypeScript definitions** with proper request/response types

3. **Adds Supabase integration** with RLS-aware queries

4. **Includes authentication** (if --auth flag)

5. **Implements error handling** with standardized responses

6. **Adds input validation** with Zod schemas

7. **Includes business logic** specific to coffee shop or yoga studio

## API Endpoint Template Structure:

```typescript
import type { APIRoute } from 'astro'
import { createServerClient } from '@supabase/ssr'
import { z } from 'zod'

const requestSchema = z.object({
  // Request validation schema
})

export const POST: APIRoute = async ({ request, cookies }) => {
  try {
    // Parse and validate request
    const body = await request.json()
    const validatedData = requestSchema.parse(body)

    // Create Supabase client
    const supabase = createServerClient(/* config */)

    // Authentication (if required)
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    // Business logic here
    const result = await performBusinessLogic(supabase, user, validatedData)

    return new Response(JSON.stringify({ success: true, data: result }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    })
  } catch (error) {
    console.error('API Error:', error)
    return new Response(JSON.stringify({
      error: error instanceof Error ? error.message : 'Internal Server Error'
    }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    })
  }
}
```

## Business-Specific Endpoints:

### Coffee Shop APIs (--type=coffee)
- Product management (CRUD operations)
- Order processing and status updates
- Inventory tracking and alerts
- Loyalty points calculations
- POS system integration

### Yoga Studio APIs (--type=yoga)
- Class management and scheduling
- Booking system with capacity limits
- Member profile management
- Instructor schedule handling
- Package and subscription tracking

### Shared APIs (--type=shared)
- Authentication endpoints
- Payment processing (Stripe)
- File upload handling
- Admin dashboard data
- Analytics and reporting

## Security Features:
- **Input validation** with Zod schemas
- **Authentication checks** with Supabase Auth
- **Rate limiting** considerations
- **CORS headers** configuration
- **SQL injection prevention** through Supabase client

## Files Created:
- `src/pages/api/[category]/endpoint-name.ts`
- Type definitions in `src/types/api.ts` (updated)