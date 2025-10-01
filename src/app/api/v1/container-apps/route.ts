import { NextRequest, NextResponse } from 'next/server';
import { v4 as uuidv4 } from 'uuid';
import {
  validatePayload,
  ApiResponse,
} from '@/lib/schemas/containerAppPayload';

function log(level: 'info' | 'error' | 'warn', message: string, metadata?: Record<string, any>) {
  const timestamp = new Date().toISOString();
  const logEntry = {
    timestamp,
    level,
    message,
    ...metadata,
  };
  console.log(JSON.stringify(logEntry));
}

export async function POST(request: NextRequest): Promise<NextResponse<ApiResponse>> {
  const startTime = Date.now();
  let requestId: string | undefined;

  try {
    // Parse request body
    const body = await request.json();

    log('info', 'Received Container App request', {
      operation: body.operation,
      containerAppName: body.containerApp?.name,
    });

    // Validate payload using Zod schema
    const validation = validatePayload(body);

    if (!validation.success) {
      const errorRequestId = uuidv4();
      log('warn', 'Payload validation failed', {
        requestId: errorRequestId,
        errors: validation.errors,
      });

      return NextResponse.json(
        {
          requestId: errorRequestId,
          status: 'rejected',
          message: 'Payload validation failed',
          errors: validation.errors,
        } as ApiResponse,
        { status: 400 }
      );
    }

    const payload = validation.data!;
    requestId = payload.metadata.requestId;

    log('info', 'Payload validation successful', {
      requestId,
      operation: payload.operation,
      containerApp: payload.containerApp.name,
      resourceGroup: payload.containerApp.resourceGroup,
    });

    // Get Argo Events webhook URL from environment
    const webhookUrl =
      process.env.ARGO_WEBHOOK_URL ||
      'http://aca-webhook-svc.argo-events.svc.cluster.local:12000/container-apps';

    log('info', 'Forwarding to Argo Events webhook', {
      requestId,
      webhookUrl,
    });

    // Forward payload to Argo Events webhook
    const webhookResponse = await fetch(webhookUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });

    if (!webhookResponse.ok) {
      const errorText = await webhookResponse.text();
      log('error', 'Webhook communication failed', {
        requestId,
        webhookUrl,
        status: webhookResponse.status,
        statusText: webhookResponse.statusText,
        error: errorText,
      });

      return NextResponse.json(
        {
          requestId,
          status: 'error',
          message: `Failed to trigger workflow: ${webhookResponse.statusText}`,
          errors: [
            {
              field: 'webhook',
              message: errorText || 'Webhook communication failed',
            },
          ],
        } as ApiResponse,
        { status: 502 }
      );
    }

    log('info', 'Webhook request successful', {
      requestId,
      webhookStatus: webhookResponse.status,
    });

    // Generate workflow ID based on request metadata
    const workflowId = `${payload.operation}-${payload.containerApp.name}-${requestId.substring(0, 8)}`;

    // Calculate estimated completion time (5 minutes for create, 2 minutes for delete)
    const estimatedMinutes = payload.operation === 'create' ? 5 : 2;
    const estimatedCompletionTime = new Date(
      Date.now() + estimatedMinutes * 60 * 1000
    ).toISOString();

    const duration = Date.now() - startTime;
    log('info', 'Request processed successfully', {
      requestId,
      workflowId,
      operation: payload.operation,
      containerApp: payload.containerApp.name,
      duration,
      estimatedCompletionTime,
    });

    return NextResponse.json(
      {
        requestId,
        status: 'accepted',
        workflowId,
        message: `${payload.operation.toUpperCase()} operation initiated for Container App '${payload.containerApp.name}'`,
        estimatedCompletionTime,
      } as ApiResponse,
      { status: 202 }
    );
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : 'Unknown error occurred';
    const errorRequestId = requestId || uuidv4();

    log('error', 'Unhandled error in API request', {
      requestId: errorRequestId,
      error: errorMessage,
      stack: error instanceof Error ? error.stack : undefined,
    });

    return NextResponse.json(
      {
        requestId: errorRequestId,
        status: 'error',
        message: 'Internal server error',
        errors: [
          {
            field: 'server',
            message: errorMessage,
          },
        ],
      } as ApiResponse,
      { status: 500 }
    );
  }
}
