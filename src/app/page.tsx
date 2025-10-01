export default function Home() {
  return (
    <main className="min-h-screen bg-gradient-to-br from-blue-50 to-indigo-100 dark:from-gray-900 dark:to-gray-800">
      <div className="container mx-auto px-4 py-8">
        <div className="text-center mb-8">
          <h1 className="text-4xl font-bold text-gray-900 dark:text-white mb-4">
            Azure Container Apps Platform
          </h1>
          <p className="text-lg text-gray-600 dark:text-gray-300">
            Self-service platform for provisioning and managing Azure Container Apps
          </p>
        </div>

        <div className="max-w-4xl mx-auto">
          <div className="bg-white dark:bg-gray-800 rounded-lg shadow-lg p-8">
            <h2 className="text-2xl font-semibold text-gray-900 dark:text-white mb-4">
              API Endpoint
            </h2>
            <div className="bg-gray-100 dark:bg-gray-900 rounded p-4 mb-4">
              <code className="text-sm text-gray-800 dark:text-gray-200">
                POST /api/v1/container-apps
              </code>
            </div>

            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
              Test with cURL:
            </h3>
            <div className="bg-gray-100 dark:bg-gray-900 rounded p-4 overflow-x-auto">
              <pre className="text-xs text-gray-800 dark:text-gray-200">
{`curl -X POST http://localhost:3000/api/v1/container-apps \\
  -H "Content-Type: application/json" \\
  -d '{
    "operation": "create",
    "metadata": {
      "requestId": "550e8400-e29b-41d4-a716-446655440000",
      "requestedBy": "admin@example.com",
      "team": "platform",
      "environment": "dev"
    },
    "containerApp": {
      "name": "test-app",
      "resourceGroup": "rg-test-dev",
      "location": "eastus",
      "image": {
        "registry": "mcr.microsoft.com",
        "repository": "azuredocs/containerapps-helloworld",
        "tag": "latest"
      },
      "resources": {
        "cpu": 0.25,
        "memory": "0.5Gi"
      },
      "scaling": {
        "minReplicas": 0,
        "maxReplicas": 5
      },
      "ingress": {
        "external": true,
        "targetPort": 80
      }
    }
  }'`}
              </pre>
            </div>

            <div className="mt-6">
              <div className="inline-flex items-center px-4 py-2 rounded-full bg-blue-100 text-blue-800 dark:bg-blue-800 dark:text-blue-100">
                <div className="w-2 h-2 bg-blue-500 rounded-full mr-2"></div>
                API ready for testing
              </div>
            </div>
          </div>
        </div>
      </div>
    </main>
  )
}
