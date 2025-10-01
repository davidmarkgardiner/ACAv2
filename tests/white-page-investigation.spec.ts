import { test, expect } from '@playwright/test';

test.describe('White Page Investigation', () => {
  test('Main page investigation', async ({ page }) => {
    // Capture console messages and errors
    const consoleMessages: string[] = [];
    const errorMessages: string[] = [];

    page.on('console', msg => {
      consoleMessages.push(`${msg.type()}: ${msg.text()}`);
      if (msg.type() === 'error') {
        errorMessages.push(msg.text());
      }
    });

    page.on('pageerror', error => {
      errorMessages.push(`Page Error: ${error.message}`);
    });

    page.on('requestfailed', request => {
      errorMessages.push(`Request Failed: ${request.url()} - ${request.failure()?.errorText}`);
    });

    console.log('🔍 Navigating to main page (http://localhost:3002)...');

    try {
      await page.goto('/', { waitUntil: 'networkidle' });

      // Take screenshot of main page
      await page.screenshot({
        path: 'main-page-screenshot.png',
        fullPage: true
      });

      console.log('📸 Screenshot taken: main-page-screenshot.png');

      // Check if page is completely white/empty
      const bodyContent = await page.locator('body').textContent();
      const hasVisibleContent = bodyContent && bodyContent.trim().length > 0;

      console.log('📄 Body content length:', bodyContent?.length || 0);
      console.log('📄 Body content preview:', bodyContent?.substring(0, 200) || 'EMPTY');

      // Check for React root element
      const reactRoot = await page.locator('#__next, #root, [data-reactroot]').count();
      console.log('⚛️  React root elements found:', reactRoot);

      // Check for any visible elements
      const visibleElements = await page.locator('*:visible').count();
      console.log('👁️  Visible elements count:', visibleElements);

      // Log console messages
      console.log('📝 Console messages:');
      consoleMessages.forEach(msg => console.log('  ', msg));

      if (errorMessages.length > 0) {
        console.log('❌ Error messages:');
        errorMessages.forEach(msg => console.log('  ', msg));
      }

      // Check document title
      const title = await page.title();
      console.log('📋 Page title:', title);

      // Check if there are any script tags
      const scriptCount = await page.locator('script').count();
      console.log('📜 Script tags count:', scriptCount);

      // Check for CSS files
      const linkCount = await page.locator('link[rel="stylesheet"]').count();
      console.log('🎨 CSS link tags count:', linkCount);

    } catch (error) {
      console.log('❌ Main page error:', error);
      errorMessages.push(`Navigation Error: ${error}`);
    }
  });

  test('Test auth page investigation', async ({ page }) => {
    // Capture console messages and errors
    const consoleMessages: string[] = [];
    const errorMessages: string[] = [];

    page.on('console', msg => {
      consoleMessages.push(`${msg.type()}: ${msg.text()}`);
      if (msg.type() === 'error') {
        errorMessages.push(msg.text());
      }
    });

    page.on('pageerror', error => {
      errorMessages.push(`Page Error: ${error.message}`);
    });

    page.on('requestfailed', request => {
      errorMessages.push(`Request Failed: ${request.url()} - ${request.failure()?.errorText}`);
    });

    console.log('🔍 Navigating to test auth page (http://localhost:3002/test-auth)...');

    try {
      await page.goto('/test-auth', { waitUntil: 'networkidle' });

      // Take screenshot of test auth page
      await page.screenshot({
        path: 'test-auth-page-screenshot.png',
        fullPage: true
      });

      console.log('📸 Screenshot taken: test-auth-page-screenshot.png');

      // Check if page is completely white/empty
      const bodyContent = await page.locator('body').textContent();
      const hasVisibleContent = bodyContent && bodyContent.trim().length > 0;

      console.log('📄 Body content length:', bodyContent?.length || 0);
      console.log('📄 Body content preview:', bodyContent?.substring(0, 200) || 'EMPTY');

      // Look for auth-related elements
      const loginForm = await page.locator('form, [data-testid*="login"], [class*="login"]').count();
      console.log('🔐 Login form elements found:', loginForm);

      const authButtons = await page.locator('button, [role="button"]').count();
      console.log('🔲 Button elements found:', authButtons);

      // Check for Firebase-related elements or errors
      const firebaseErrors = errorMessages.filter(msg =>
        msg.toLowerCase().includes('firebase') ||
        msg.toLowerCase().includes('auth') ||
        msg.toLowerCase().includes('google')
      );
      if (firebaseErrors.length > 0) {
        console.log('🔥 Firebase-related errors:');
        firebaseErrors.forEach(msg => console.log('  ', msg));
      }

      // Log console messages
      console.log('📝 Console messages:');
      consoleMessages.forEach(msg => console.log('  ', msg));

      if (errorMessages.length > 0) {
        console.log('❌ Error messages:');
        errorMessages.forEach(msg => console.log('  ', msg));
      }

    } catch (error) {
      console.log('❌ Test auth page error:', error);
      errorMessages.push(`Navigation Error: ${error}`);
    }
  });

  test('AuthProvider and Context Investigation', async ({ page }) => {
    console.log('🔍 Investigating AuthProvider and Context issues...');

    const consoleMessages: string[] = [];
    const errorMessages: string[] = [];

    page.on('console', msg => {
      consoleMessages.push(`${msg.type()}: ${msg.text()}`);
      if (msg.type() === 'error') {
        errorMessages.push(msg.text());
      }
    });

    page.on('pageerror', error => {
      errorMessages.push(`Page Error: ${error.message}`);
    });

    await page.goto('/', { waitUntil: 'networkidle' });

    // Check if React is loaded
    const reactLoaded = await page.evaluate(() => {
      return typeof window !== 'undefined' &&
             (window as any).React !== undefined ||
             document.querySelector('[data-reactroot]') !== null ||
             document.querySelector('#__next') !== null;
    });
    console.log('⚛️  React loaded:', reactLoaded);

    // Check if Firebase is loaded
    const firebaseLoaded = await page.evaluate(() => {
      return typeof window !== 'undefined' &&
             ((window as any).firebase !== undefined ||
              (window as any).FirebaseAuth !== undefined);
    });
    console.log('🔥 Firebase loaded:', firebaseLoaded);

    // Look for context-related errors
    const contextErrors = errorMessages.filter(msg =>
      msg.toLowerCase().includes('context') ||
      msg.toLowerCase().includes('provider') ||
      msg.toLowerCase().includes('hook')
    );
    if (contextErrors.length > 0) {
      console.log('🎣 Context/Provider related errors:');
      contextErrors.forEach(msg => console.log('  ', msg));
    }

    // Check for missing dependencies errors
    const depErrors = errorMessages.filter(msg =>
      msg.toLowerCase().includes('module not found') ||
      msg.toLowerCase().includes('cannot resolve') ||
      msg.toLowerCase().includes('failed to load')
    );
    if (depErrors.length > 0) {
      console.log('📦 Dependency related errors:');
      depErrors.forEach(msg => console.log('  ', msg));
    }

    console.log('📝 All console messages:');
    consoleMessages.forEach(msg => console.log('  ', msg));

    if (errorMessages.length > 0) {
      console.log('❌ All error messages:');
      errorMessages.forEach(msg => console.log('  ', msg));
    }
  });
});