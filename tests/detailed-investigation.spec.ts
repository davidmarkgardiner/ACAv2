import { test, expect } from '@playwright/test';

test('Detailed Investigation', async ({ page }) => {
  const consoleMessages: Array<{ type: string, text: string, location?: string }> = [];
  const networkResponses: Array<{ url: string, status: number, statusText: string }> = [];
  const failedRequests: Array<{ url: string, error: string }> = [];

  // Capture all console messages with more detail
  page.on('console', msg => {
    consoleMessages.push({
      type: msg.type(),
      text: msg.text(),
      location: msg.location().url
    });
  });

  // Monitor all network responses
  page.on('response', response => {
    networkResponses.push({
      url: response.url(),
      status: response.status(),
      statusText: response.statusText()
    });
  });

  // Monitor failed requests
  page.on('requestfailed', request => {
    failedRequests.push({
      url: request.url(),
      error: request.failure()?.errorText || 'Unknown error'
    });
  });

  console.log('🔍 Starting detailed investigation...');

  // Navigate to the main page
  await page.goto('/', { waitUntil: 'networkidle' });

  console.log('\n📊 ANALYSIS RESULTS:');

  // Check if React components are actually rendering
  const reactElements = await page.evaluate(() => {
    const elements = document.querySelectorAll('*');
    const reactElements = [];
    for (let i = 0; i < elements.length; i++) {
      const element = elements[i];
      if (element.hasAttribute('data-reactroot') ||
          element.className?.includes('react') ||
          (element as any)._reactInternalFiber ||
          (element as any).__reactInternalInstance) {
        reactElements.push(element.tagName);
      }
    }
    return reactElements;
  });

  console.log('⚛️  React elements detected:', reactElements.length);

  // Check if Firebase is initialized
  const firebaseStatus = await page.evaluate(() => {
    return {
      firebaseExists: typeof window !== 'undefined' && !!(window as any).firebase,
      authExists: typeof window !== 'undefined' && !!(window as any).firebase?.auth,
      firestoreExists: typeof window !== 'undefined' && !!(window as any).firebase?.firestore,
      // Alternative check for Firebase v9 modular SDK
      firebaseModular: typeof window !== 'undefined' && !!(window as any).firebaseApp,
    };
  });

  console.log('🔥 Firebase status:', JSON.stringify(firebaseStatus, null, 2));

  // Check environment variables (client-side accessible ones)
  const envVars = await page.evaluate(() => {
    if (typeof window !== 'undefined' && (window as any).process?.env) {
      const env = (window as any).process.env;
      return {
        hasApiKey: !!env.NEXT_PUBLIC_FIREBASE_API_KEY,
        hasAuthDomain: !!env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN,
        hasProjectId: !!env.NEXT_PUBLIC_FIREBASE_PROJECT_ID,
        apiKeyPrefix: env.NEXT_PUBLIC_FIREBASE_API_KEY?.substring(0, 10) + '...',
      };
    }
    return { message: 'Environment variables not accessible from client' };
  });

  console.log('🌍 Environment variables status:', JSON.stringify(envVars, null, 2));

  // Check for specific error patterns
  const errorPatterns = {
    firebaseErrors: consoleMessages.filter(msg =>
      msg.text.toLowerCase().includes('firebase') && msg.type === 'error'
    ),
    authErrors: consoleMessages.filter(msg =>
      msg.text.toLowerCase().includes('auth') && msg.type === 'error'
    ),
    moduleErrors: consoleMessages.filter(msg =>
      msg.text.toLowerCase().includes('module') && msg.type === 'error'
    ),
    networkErrors: consoleMessages.filter(msg =>
      (msg.text.toLowerCase().includes('failed to fetch') ||
       msg.text.toLowerCase().includes('network')) && msg.type === 'error'
    ),
  };

  console.log('\n❌ ERROR ANALYSIS:');
  Object.entries(errorPatterns).forEach(([category, errors]) => {
    if (errors.length > 0) {
      console.log(`${category}:`, errors.map(e => e.text));
    }
  });

  // Check for 404s specifically
  const notFoundResponses = networkResponses.filter(r => r.status === 404);
  if (notFoundResponses.length > 0) {
    console.log('\n🔍 404 ERRORS FOUND:');
    notFoundResponses.forEach(response => {
      console.log(`  - ${response.url} (${response.status} ${response.statusText})`);
    });
  }

  // Check for failed requests
  if (failedRequests.length > 0) {
    console.log('\n💥 FAILED REQUESTS:');
    failedRequests.forEach(req => {
      console.log(`  - ${req.url}: ${req.error}`);
    });
  }

  // Check DOM structure
  const domInfo = await page.evaluate(() => {
    return {
      bodyChildren: document.body?.children.length || 0,
      hasMain: !!document.querySelector('main'),
      hasLoginForm: !!document.querySelector('form'),
      hasButtons: document.querySelectorAll('button').length,
      hasInputs: document.querySelectorAll('input').length,
      nextJsRoot: !!document.querySelector('#__next'),
      bodyClasses: document.body?.className || '',
      headElements: document.head?.children.length || 0,
    };
  });

  console.log('\n🏗️  DOM STRUCTURE:');
  console.log(JSON.stringify(domInfo, null, 2));

  console.log('\n📝 ALL CONSOLE MESSAGES:');
  consoleMessages.forEach(msg => {
    console.log(`  [${msg.type.toUpperCase()}] ${msg.text}${msg.location ? ` (${msg.location})` : ''}`);
  });

  console.log('\n🌐 ALL NETWORK RESPONSES:');
  networkResponses.forEach(response => {
    const indicator = response.status >= 400 ? '❌' : response.status >= 300 ? '⚠️' : '✅';
    console.log(`  ${indicator} ${response.status} ${response.url}`);
  });

  console.log('\n✅ Investigation complete!');
});