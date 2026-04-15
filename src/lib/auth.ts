// ============================================================================
// Authentication helper for API routes
// ============================================================================
// Verifies bearer tokens from incoming requests.
// Supports Firebase ID tokens (via Google's public keys) and
// a shared API key for service-to-service calls.
// ============================================================================

import { NextRequest } from 'next/server';

interface AuthResult {
  authenticated: boolean;
  userId?: string;
  error?: string;
}

/**
 * Verify the authentication token from an incoming request.
 *
 * Accepts:
 *  - Bearer token in the Authorization header (validated against
 *    Google/Firebase token info endpoint)
 *  - API key in the X-API-Key header (validated against the
 *    API_SECRET_KEY environment variable)
 *
 * Returns an AuthResult indicating success or failure.
 */
export async function verifyAuthToken(request: NextRequest): Promise<AuthResult> {
  // Check for API key authentication (service-to-service)
  const apiKey = request.headers.get('x-api-key');
  const expectedApiKey = process.env.API_SECRET_KEY;

  if (apiKey && expectedApiKey && apiKey === expectedApiKey) {
    return { authenticated: true, userId: 'service-account' };
  }

  // Check for Bearer token authentication
  const authHeader = request.headers.get('authorization');
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return { authenticated: false, error: 'Missing or malformed Authorization header' };
  }

  const token = authHeader.substring(7);
  if (!token) {
    return { authenticated: false, error: 'Empty bearer token' };
  }

  try {
    // Validate the token against Google's tokeninfo endpoint
    const response = await fetch(
      `https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(token)}`
    );

    if (!response.ok) {
      return { authenticated: false, error: 'Invalid or expired token' };
    }

    const tokenInfo = await response.json();

    // Verify the token audience matches our Firebase project
    const expectedProjectId = process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID;
    if (expectedProjectId && tokenInfo.aud !== expectedProjectId) {
      return { authenticated: false, error: 'Token audience mismatch' };
    }

    return {
      authenticated: true,
      userId: tokenInfo.sub,
    };
  } catch {
    return { authenticated: false, error: 'Token verification failed' };
  }
}
