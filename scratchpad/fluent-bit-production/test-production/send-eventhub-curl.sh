#!/bin/bash
#
# Send test K8s events to Azure Event Hub using curl
# No Python dependencies required - uses Azure REST API directly
#
# Prerequisites:
# - Azure CLI logged in (to get SAS token)
# - jq, curl installed
#
# Usage:
#   ./send-eventhub-curl.sh                    # Send default CrashLoopBackOff event
#   ./send-eventhub-curl.sh OOMKilled          # Send OOMKilled event
#   ./send-eventhub-curl.sh --namespace test   # Send to specific namespace
#

set -e

# Configuration - UPDATE THESE
EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE:-k8s-events-hub-fb}"
EVENTHUB_NAME="${EVENTHUB_NAME:-kube-events}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"

# Default values
EVENT_REASON="${1:-CrashLoopBackOff}"
EVENT_NAMESPACE="${2:-default}"
EVENT_POD_NAME="test-pod-$(date +%s)"
CLUSTER_NAME="kind-argo-workflow"

# Generate message based on reason
case $EVENT_REASON in
    CrashLoopBackOff)
        EVENT_MESSAGE="Back-off 5m0s restarting failed container test-container in pod ${EVENT_POD_NAME}"
        ;;
    OOMKilled)
        EVENT_MESSAGE="Container test-container was OOMKilled"
        ;;
    NodeNotReady)
        EVENT_MESSAGE="Node is NotReady"
        ;;
    FailedMount)
        EVENT_MESSAGE="MountVolume.SetUp failed for volume config: configmap missing-config not found"
        ;;
    FailedScheduling)
        EVENT_MESSAGE="0/3 nodes are available: 3 Insufficient memory."
        ;;
    Evicted)
        EVENT_MESSAGE="The node was low on resource: ephemeral-storage."
        ;;
    *)
        EVENT_MESSAGE="Test event for reason: ${EVENT_REASON}"
        ;;
esac

# Create K8s event JSON
K8S_EVENT=$(jq -n \
    --arg type "Warning" \
    --arg reason "$EVENT_REASON" \
    --arg message "$EVENT_MESSAGE" \
    --arg podName "$EVENT_POD_NAME" \
    --arg namespace "$EVENT_NAMESPACE" \
    --arg cluster "$CLUSTER_NAME" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{
        type: $type,
        reason: $reason,
        message: $message,
        involvedObject: {
            kind: "Pod",
            name: $podName,
            namespace: $namespace,
            uid: "test-uid-\($timestamp)"
        },
        source: {
            component: "kubelet",
            host: "test-node"
        },
        firstTimestamp: $timestamp,
        lastTimestamp: $timestamp,
        count: 1,
        cluster: $cluster
    }')

echo "=========================================="
echo "Sending Event to Azure Event Hub (curl)"
echo "=========================================="
echo ""
echo "Event Hub:  ${EVENTHUB_NAMESPACE}/${EVENTHUB_NAME}"
echo "Reason:     ${EVENT_REASON}"
echo "Namespace:  ${EVENT_NAMESPACE}"
echo "Pod:        ${EVENT_POD_NAME}"
echo ""

# Get resource group if not set
if [[ -z "$RESOURCE_GROUP" ]]; then
    RESOURCE_GROUP=$(az eventhubs namespace list --query "[?name=='${EVENTHUB_NAMESPACE}'].resourceGroup" -o tsv 2>/dev/null || true)
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "ERROR: Could not determine resource group"
    echo "Set RESOURCE_GROUP environment variable"
    exit 1
fi

# Get SAS key and generate token
echo "Getting SAS key..."
SAS_KEY_NAME="RootManageSharedAccessKey"
SAS_KEY=$(az eventhubs namespace authorization-rule keys list \
    --resource-group "$RESOURCE_GROUP" \
    --namespace-name "$EVENTHUB_NAMESPACE" \
    --name "$SAS_KEY_NAME" \
    --query primaryKey -o tsv)

if [[ -z "$SAS_KEY" ]]; then
    echo "ERROR: Could not get SAS key"
    exit 1
fi

# Generate SAS token (valid for 1 hour)
EVENTHUB_URI="https://${EVENTHUB_NAMESPACE}.servicebus.windows.net/${EVENTHUB_NAME}"
ENCODED_URI=$(printf '%s' "$EVENTHUB_URI" | jq -sRr @uri)
EXPIRY=$(( $(date +%s) + 3600 ))
STRING_TO_SIGN="${ENCODED_URI}\n${EXPIRY}"

# Generate signature
SIGNATURE=$(printf '%s' "$STRING_TO_SIGN" | openssl dgst -sha256 -hmac "$SAS_KEY" -binary | base64)
ENCODED_SIG=$(printf '%s' "$SIGNATURE" | jq -sRr @uri)

SAS_TOKEN="SharedAccessSignature sr=${ENCODED_URI}&sig=${ENCODED_SIG}&se=${EXPIRY}&skn=${SAS_KEY_NAME}"

# Send event via REST API
echo "Sending event..."

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "${EVENTHUB_URI}/messages?api-version=2014-01" \
    -H "Authorization: ${SAS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${K8S_EVENT}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

echo ""
if [[ "$HTTP_CODE" == "201" ]]; then
    echo "SUCCESS: Event sent (HTTP $HTTP_CODE)"
    echo ""
    echo "Event payload:"
    echo "$K8S_EVENT" | jq .
else
    echo "ERROR: Failed to send event (HTTP $HTTP_CODE)"
    echo "$BODY"
    exit 1
fi

echo ""
echo "=========================================="
echo "Verify with:"
echo "=========================================="
echo ""
echo "kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=20"
echo "kubectl get workflows -n argo-events -w"
