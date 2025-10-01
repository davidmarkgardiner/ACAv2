import { test, expect } from '@playwright/test';

test('Network Investigation', async ({ page }) => {
  const networkErrors: string[] = [];
  const requests: string[] = [];

  // Monitor network requests
  page.on('request', request => {
    requests.push(`REQUEST: ${request.method()} ${request.url()}`);
  });

  page.on('response', response => {
    if (!response.ok()) {
      networkErrors.push(`FAILED RESPONSE: ${response.status()} ${response.url()}`);
    }
  });

  page.on('requestfailed', request => {
    networkErrors.push(`FAILED REQUEST: ${request.url()} - ${request.failure()?.errorText}`);
  });

  console.log('🌐 Investigating network requests...');

  await page.goto('/', { waitUntil: 'networkidle' });

  console.log('📡 Network requests made:');
  requests.forEach(req => console.log('  ', req));

  if (networkErrors.length > 0) {
    console.log('❌ Network errors:');
    networkErrors.forEach(err => console.log('  ', err));
  }

  // Also check the /test-auth page
  console.log('\n🌐 Checking /test-auth page...');

  const testAuthRequests: string[] = [];
  const testAuthErrors: string[] = [];

  page.on('request', request => {
    testAuthRequests.push(`REQUEST: ${request.method()} ${request.url()}`);
  });

  page.on('response', response => {
    if (!response.ok()) {
      testAuthErrors.push(`FAILED RESPONSE: ${response.status()} ${response.url()}`);
    }
  });

  await page.goto('/test-auth', { waitUntil: 'networkidle' });

  console.log('📡 Test-auth network requests:');
  testAuthRequests.forEach(req => console.log('  ', req));

  if (testAuthErrors.length > 0) {
    console.log('❌ Test-auth network errors:');
    testAuthErrors.forEach(err => console.log('  ', err));
  }
});