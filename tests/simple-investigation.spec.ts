import { test, expect } from '@playwright/test';

test('Simple Investigation', async ({ page }) => {
  const consoleMessages: string[] = [];
  const networkErrors: string[] = [];

  page.on('console', msg => {
    consoleMessages.push(`[${msg.type()}] ${msg.text()}`);
  });

  page.on('response', response => {
    if (!response.ok()) {
      networkErrors.push(`${response.status()} ${response.url()}`);
    }
  });

  console.log('🔍 Running simple investigation...');

  await page.goto('/', { waitUntil: 'networkidle' });

  // Check Firebase initialization
  const firebaseCheck = await page.evaluate(() => {
    try {
      // Check if any Firebase-related global variables exist
      const windowObj = window as any;
      return {
        hasFirebase: !!windowObj.firebase,
        hasFirebaseApp: !!windowObj.firebaseApp,
        hasGapi: !!windowObj.gapi,
        errorFound: false,
      };
    } catch (error) {
      return {
        hasFirebase: false,
        hasFirebaseApp: false,
        hasGapi: false,
        errorFound: true,
        error: String(error),
      };
    }
  });

  console.log('🔥 Firebase check:', JSON.stringify(firebaseCheck, null, 2));

  // Check DOM elements
  const domCheck = await page.evaluate(() => {
    return {
      hasLoginForm: !!document.querySelector('form'),
      hasEmailInput: !!document.querySelector('input[type="email"], input[placeholder*="email"], input[placeholder*="Email"]'),
      hasPasswordInput: !!document.querySelector('input[type="password"], input[placeholder*="password"], input[placeholder*="Password"]'),
      hasGoogleButton: !!document.querySelector('button:has-text("Google"), button:has-text("Continue with Google"), [class*="google"]'),
      bodyText: document.body?.textContent?.substring(0, 200) || '',
      hasMainElement: !!document.querySelector('main'),
      totalElements: document.querySelectorAll('*').length,
    };
  });

  console.log('🏗️  DOM check:', JSON.stringify(domCheck, null, 2));

  // Filter for important console messages
  const importantMessages = consoleMessages.filter(msg =>
    msg.includes('error') ||
    msg.includes('failed') ||
    msg.includes('404') ||
    msg.includes('Firebase') ||
    msg.includes('auth')
  );

  if (importantMessages.length > 0) {
    console.log('📝 Important console messages:');
    importantMessages.forEach(msg => console.log('  ', msg));
  }

  if (networkErrors.length > 0) {
    console.log('🌐 Network errors:');
    networkErrors.forEach(err => console.log('  ', err));
  }

  // Now check the /test-auth page
  console.log('\n🔍 Checking /test-auth page...');

  await page.goto('/test-auth', { waitUntil: 'networkidle' });

  const testAuthDom = await page.evaluate(() => {
    return {
      title: document.title,
      hasH1: !!document.querySelector('h1'),
      h1Text: document.querySelector('h1')?.textContent || '',
      hasLoginForm: !!document.querySelector('form'),
      totalButtons: document.querySelectorAll('button').length,
      bodyTextPreview: document.body?.textContent?.substring(0, 100) || '',
    };
  });

  console.log('📄 Test auth page check:', JSON.stringify(testAuthDom, null, 2));

  console.log('\n✅ Simple investigation complete!');
});