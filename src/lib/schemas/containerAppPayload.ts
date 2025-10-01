// ============================================================================
// Container App Payload Schema - Validation using Zod
// ============================================================================

import { z } from 'zod';

// Image configuration
const ImageSchema = z.object({
  registry: z.string().min(1, 'Registry is required'),
  repository: z.string().min(1, 'Repository is required'),
  tag: z.string().min(1, 'Tag is required'),
});

// Resource allocation
const ResourcesSchema = z.object({
  cpu: z.number().min(0.25).max(4.0),
  memory: z.string().regex(/^\d+(\.\d+)?Gi$/, 'Memory must be in format: 0.5Gi, 1Gi, etc.'),
});

// Scaling rule
const ScalingRuleSchema = z.object({
  name: z.string().min(1),
  type: z.enum(['http', 'cpu', 'memory', 'custom']),
  metadata: z.record(z.string()).optional(),
});

// Scaling configuration
const ScalingSchema = z.object({
  minReplicas: z.number().int().min(0).max(30),
  maxReplicas: z.number().int().min(1).max(30),
  rules: z.array(ScalingRuleSchema).optional(),
});

// Ingress configuration
const IngressSchema = z.object({
  external: z.boolean(),
  targetPort: z.number().int().min(1).max(65535),
  transport: z.enum(['http', 'http2', 'tcp']).default('http'),
  allowInsecure: z.boolean().default(false),
});

// Secret reference
const SecretSchema = z.object({
  name: z.string().min(1),
  keyVaultReference: z.string().url().optional(),
  value: z.string().optional(),
});

// Environment variable
const EnvVarSchema = z.object({
  name: z.string().min(1),
  value: z.string().optional(),
  secretRef: z.string().optional(),
});

// Container App configuration
const ContainerAppSchema = z.object({
  name: z.string()
    .min(1)
    .max(32)
    .regex(/^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/, 'Name must be lowercase alphanumeric with hyphens'),
  resourceGroup: z.string()
    .min(1)
    .max(90)
    .regex(/^[a-zA-Z0-9_\-\.()]+$/, 'Invalid resource group name'),
  location: z.string().min(1).default('eastus'),
  image: ImageSchema,
  resources: ResourcesSchema.optional(),
  scaling: ScalingSchema.optional(),
  ingress: IngressSchema.optional(),
  secrets: z.array(SecretSchema).optional(),
  env: z.array(EnvVarSchema).optional(),
});

// VNet integration
const VnetIntegrationSchema = z.object({
  enabled: z.boolean(),
  subnetId: z.string().optional(),
});

// Environment configuration
const EnvironmentSchema = z.object({
  name: z.string().min(1).optional(),
  vnetIntegration: VnetIntegrationSchema.optional(),
  logAnalyticsWorkspace: z.string().optional(),
});

// Request metadata
const MetadataSchema = z.object({
  requestId: z.string().uuid(),
  requestedBy: z.string().email(),
  team: z.string().min(1),
  environment: z.enum(['dev', 'staging', 'prod']),
});

// Main payload schema
export const ContainerAppPayloadSchema = z.object({
  operation: z.enum(['create', 'update', 'delete', 'scale']),
  metadata: MetadataSchema,
  containerApp: ContainerAppSchema,
  environment: EnvironmentSchema.optional(),
});

export type ContainerAppPayload = z.infer<typeof ContainerAppPayloadSchema>;

// API Response types
export interface ApiResponse {
  requestId: string;
  status: 'accepted' | 'rejected' | 'error';
  workflowId?: string;
  message: string;
  estimatedCompletionTime?: string;
  errors?: Array<{
    field: string;
    message: string;
  }>;
}

// Validation helper
export function validatePayload(data: unknown): {
  success: boolean;
  data?: ContainerAppPayload;
  errors?: Array<{ field: string; message: string }>;
} {
  try {
    const result = ContainerAppPayloadSchema.safeParse(data);

    if (result.success) {
      return { success: true, data: result.data };
    } else {
      const errors = result.error.errors.map(err => ({
        field: err.path.join('.'),
        message: err.message,
      }));
      return { success: false, errors };
    }
  } catch (error) {
    return {
      success: false,
      errors: [{ field: 'unknown', message: 'Unexpected validation error' }],
    };
  }
}
