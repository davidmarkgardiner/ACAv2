---
allowed-tools: Read, Write, MultiEdit, Bash
description: Generate comprehensive E2E tests with Playwright for the Modern Business template, covering user flows and business-critical features
---

# /test - Generate Playwright Tests

Generate comprehensive E2E tests with Playwright for the Modern Business template, covering user flows and business-critical features.

## Usage

```
/test test-name [--type=retail|service|shared] [--flow=user|admin|payment] [--device=desktop|mobile]
```

## Examples

```
/test product-ordering --type=retail --flow=user --device=desktop
/test service-booking --type=service --flow=user --device=mobile
/test payment-processing --type=shared --flow=payment
```

## What this command does:

1. **Creates E2E test file** in `tests/e2e/[category]/`

2. **Generates user flow tests** for complete business scenarios

3. **Includes accessibility testing** with axe-playwright

4. **Adds mobile responsiveness** tests (if --device=mobile)

5. **Tests payment flows** with Stripe test cards (if --flow=payment)

6. **Implements error handling** tests for edge cases

7. **Covers authentication** flows and protected routes

## Test Template Structure:

```typescript
import { test, expect } from '@playwright/test'

test.describe('Test Name Flow', () => {
  test.beforeEach(async ({ page }) => {
    // Setup before each test
    await page.goto('/')
  })

  test('should complete main user flow', async ({ page }) => {
    // Test implementation
    await page.click('button:has-text("Start Flow")')
    await expect(page.locator('h1')).toContainText('Expected Result')
  })

  test('should handle error scenarios', async ({ page }) => {
    // Error case testing
  })

  test('should be accessible', async ({ page }) => {
    // Accessibility testing
    const accessibilityScanResults = await new AxeBuilder({ page }).analyze()
    expect(accessibilityScanResults.violations).toEqual([])
  })
})
```

## Business-Specific Test Flows:

### Coffee Shop Tests (--type=coffee)

#### **Order Flow Tests**
```typescript
test('complete coffee order flow', async ({ page }) => {
  // Browse menu
  await page.goto('/menu')
  await expect(page.locator('.product-grid')).toBeVisible()

  // Add item to cart
  await page.click('[data-testid="add-to-cart-latte"]')
  await page.selectOption('[data-testid="size-selector"]', 'large')
  await page.selectOption('[data-testid="milk-selector"]', 'oat')

  // View cart
  await page.click('[data-testid="cart-button"]')
  await expect(page.locator('[data-testid="cart-total"]')).toContainText('$5.99')

  // Checkout
  await page.click('[data-testid="checkout-button"]')
  await page.fill('[data-testid="customer-name"]', 'Test Customer')
  await page.fill('[data-testid="customer-email"]', 'test@example.com')

  // Payment
  await page.click('[data-testid="pay-button"]')
  // Test payment flow with Stripe test cards
})
```

#### **Loyalty Program Tests**
```typescript
test('loyalty points accumulation', async ({ page }) => {
  // Login as customer
  await page.goto('/auth/signin')
  await page.fill('[data-testid="email"]', 'customer@test.com')
  await page.fill('[data-testid="password"]', 'password123')
  await page.click('[data-testid="signin-button"]')

  // Check initial points
  await page.goto('/profile')
  const initialPoints = await page.textContent('[data-testid="loyalty-points"]')

  // Make purchase
  // ... order flow

  // Verify points were added
  await page.reload()
  const newPoints = await page.textContent('[data-testid="loyalty-points"]')
  expect(parseInt(newPoints)).toBeGreaterThan(parseInt(initialPoints))
})
```

### Yoga Studio Tests (--type=yoga)

#### **Class Booking Tests**
```typescript
test('book yoga class successfully', async ({ page }) => {
  // Login as member
  await page.goto('/auth/signin')
  await page.fill('[data-testid="email"]', 'member@test.com')
  await page.fill('[data-testid="password"]', 'password123')
  await page.click('[data-testid="signin-button"]')

  // Browse classes
  await page.goto('/classes')
  await expect(page.locator('.class-grid')).toBeVisible()

  // Select class
  await page.click('[data-testid="class-card-vinyasa-101"]')
  await expect(page.locator('h1')).toContainText('Vinyasa 101')

  // Book class
  await page.click('[data-testid="book-class-button"]')
  await page.selectOption('[data-testid="participants"]', '1')
  await page.click('[data-testid="confirm-booking"]')

  // Verify booking
  await expect(page.locator('[data-testid="booking-success"]')).toBeVisible()
  await expect(page.locator('[data-testid="booking-confirmation"]')).toContainText('Your class is booked')
})
```

#### **Membership Management Tests**
```typescript
test('upgrade membership plan', async ({ page }) => {
  // Login as member
  await authenticateUser(page, 'member@test.com')

  // Go to membership page
  await page.goto('/membership')
  await expect(page.locator('[data-testid="current-plan"]')).toContainText('Basic')

  // Upgrade to premium
  await page.click('[data-testid="upgrade-premium"]')
  await page.click('[data-testid="confirm-upgrade"]')

  // Handle payment
  await fillPaymentDetails(page)
  await page.click('[data-testid="pay-button"]')

  // Verify upgrade
  await expect(page.locator('[data-testid="upgrade-success"]')).toBeVisible()
})
```

### Shared Tests (--type=shared)

#### **Authentication Tests**
```typescript
test('user registration and login flow', async ({ page }) => {
  // Registration
  await page.goto('/auth/signup')
  await page.fill('[data-testid="first-name"]', 'Test')
  await page.fill('[data-testid="last-name"]', 'User')
  await page.fill('[data-testid="email"]', 'newuser@test.com')
  await page.fill('[data-testid="password"]', 'SecurePass123!')
  await page.click('[data-testid="signup-button"]')

  // Verify registration
  await expect(page.locator('[data-testid="signup-success"]')).toBeVisible()

  // Login
  await page.goto('/auth/signin')
  await page.fill('[data-testid="email"]', 'newuser@test.com')
  await page.fill('[data-testid="password"]', 'SecurePass123!')
  await page.click('[data-testid="signin-button"]')

  // Verify login
  await expect(page).toHaveURL('/dashboard')
  await expect(page.locator('[data-testid="user-name"]')).toContainText('Test User')
})
```

#### **Payment Processing Tests**
```typescript
test('stripe payment processing', async ({ page }) => {
  // Setup test payment
  await page.goto('/test-payment')

  // Fill payment form
  await page.fill('[data-testid="amount"]', '10.00')
  await page.selectOption('[data-testid="payment-type"]', 'test')

  // Use Stripe test card
  const stripeFrame = page.frameLocator('[data-testid="stripe-card-element"] iframe')
  await stripeFrame.fill('[name="cardnumber"]', '4242424242424242')
  await stripeFrame.fill('[name="exp-date"]', '12/34')
  await stripeFrame.fill('[name="cvc"]', '123')
  await stripeFrame.fill('[name="postal"]', '12345')

  // Submit payment
  await page.click('[data-testid="submit-payment"]')

  // Verify success
  await expect(page.locator('[data-testid="payment-success"]')).toBeVisible()
  await expect(page.locator('[data-testid="payment-amount"]')).toContainText('$10.00')
})
```

## Mobile Testing (--device=mobile):
```typescript
test.use({
  viewport: { width: 375, height: 667 }, // iPhone dimensions
  hasTouch: true
})

test('mobile navigation works correctly', async ({ page }) => {
  await page.goto('/')

  // Test mobile menu
  await page.click('[data-testid="mobile-menu-button"]')
  await expect(page.locator('[data-testid="mobile-menu"]')).toBeVisible()

  // Test touch interactions
  await page.tap('[data-testid="menu-item-classes"]')
  await expect(page).toHaveURL('/classes')
})
```

## Accessibility Testing:
```typescript
import AxeBuilder from '@axe-core/playwright'

test('page should be accessible', async ({ page }) => {
  await page.goto('/target-page')

  const accessibilityScanResults = await new AxeBuilder({ page })
    .include('#main-content')
    .exclude('.ads')
    .analyze()

  expect(accessibilityScanResults.violations).toEqual([])
})
```

## Performance Testing:
```typescript
test('page loads within performance budget', async ({ page }) => {
  await page.goto('/target-page')

  // Measure Core Web Vitals
  const metrics = await page.evaluate(() => {
    return new Promise((resolve) => {
      new PerformanceObserver((list) => {
        const entries = list.getEntries()
        resolve(entries)
      }).observe({ entryTypes: ['navigation', 'paint'] })
    })
  })

  // Assert performance thresholds
  expect(metrics.loadEventEnd - metrics.loadEventStart).toBeLessThan(2000)
})
```

## Files Created:
- `tests/e2e/[category]/test-name.spec.ts`
- Helper functions in `tests/helpers/` (if needed)
- Test data fixtures in `tests/fixtures/` (if needed)