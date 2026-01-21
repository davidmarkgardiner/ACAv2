#!/bin/bash
#
# Send test K8s events to Azure Event Hub
# Simulates Fluent Bit sending events to test the Argo Events pipeline
#
# Prerequisites:
# - Azure CLI logged in
# - Event Hub namespace and hub created
# - jq installed
#
# Usage:
#   ./send-eventhub-test.sh                    # Send default CrashLoopBackOff event
#   ./send-eventhub-test.sh OOMKilled          # Send OOMKilled event
#   ./send-eventhub-test.sh BackOff            # Send BackOff event (should be filtered)
#   ./send-eventhub-test.sh --namespace test   # Send to specific namespace (should pass filter)
#   ./send-eventhub-test.sh --namespace kube-system  # Send to kube-system (should be filtered)
#

set -e

# Configuration - UPDATE THESE
EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE:-k8s-events-hub-fb}"
EVENTHUB_NAME="${EVENTHUB_NAME:-kube-events}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"

# Default values
EVENT_REASON="CrashLoopBackOff"
EVENT_NAMESPACE="default"
EVENT_POD_NAME="test-pod-$(date +%s)"
EVENT_MESSAGE=""
CLUSTER_NAME="kind-argo-workflow"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace|-n)
            EVENT_NAMESPACE="$2"
            shift 2
            ;;
        --pod|-p)
            EVENT_POD_NAME="$2"
            shift 2
            ;;
        --cluster|-c)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --message|-m)
            EVENT_MESSAGE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [REASON] [OPTIONS]"
            echo ""
            echo "REASON: Event reason (default: CrashLoopBackOff)"
            echo "  Critical (triggers workflow):"
            echo "    CrashLoopBackOff, OOMKilled, NodeNotReady, FailedMount, FailedScheduling, Evicted"
            echo "  Filtered (no workflow):"
            echo "    BackOff, Pulling, Created, Started, Scheduled"
            echo ""
            echo "OPTIONS:"
            echo "  --namespace, -n    K8s namespace (default: default)"
            echo "  --pod, -p          Pod name (default: test-pod-TIMESTAMP)"
            echo "  --cluster, -c      Cluster name (default: kind-argo-workflow)"
            echo "  --message, -m      Custom event message"
            echo ""
            echo "Examples:"
            echo "  $0                                    # CrashLoopBackOff in default namespace"
            echo "  $0 OOMKilled                          # OOMKilled event"
            echo "  $0 OOMKilled --namespace monitoring   # OOMKilled in monitoring namespace"
            echo "  $0 BackOff                            # BackOff (filtered, no workflow)"
            echo "  $0 CrashLoopBackOff -n kube-system    # kube-system (filtered, no workflow)"
            exit 0
            ;;
        *)
            # First positional argument is the event reason
            EVENT_REASON="$1"
            shift
            ;;
    esac
done

# Generate default message based on reason
if [[ -z "$EVENT_MESSAGE" ]]; then
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
            EVENT_MESSAGE="MountVolume.SetUp failed for volume \"config\" : configmap \"missing-config\" not found"
            ;;
        FailedScheduling)
            EVENT_MESSAGE="0/3 nodes are available: 3 Insufficient memory."
            ;;
        Evicted)
            EVENT_MESSAGE="The node was low on resource: ephemeral-storage. Threshold quantity: 1Gi"
            ;;
        BackOff)
            EVENT_MESSAGE="Back-off pulling image \"invalid-image:latest\""
            ;;
        ImagePullBackOff)
            EVENT_MESSAGE="Back-off pulling image \"invalid-image:latest\""
            ;;
        *)
            EVENT_MESSAGE="Test event for reason: ${EVENT_REASON}"
            ;;
    esac
fi

# Create the K8s event JSON (same structure as Fluent Bit sends)
K8S_EVENT=$(cat <<EOF
{
  "type": "Warning",
  "reason": "${EVENT_REASON}",
  "message": "${EVENT_MESSAGE}",
  "involvedObject": {
    "kind": "Pod",
    "name": "${EVENT_POD_NAME}",
    "namespace": "${EVENT_NAMESPACE}",
    "uid": "test-uid-$(uuidgen 2>/dev/null || echo "$(date +%s)")"
  },
  "source": {
    "component": "kubelet",
    "host": "test-node"
  },
  "firstTimestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "lastTimestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "count": 1,
  "cluster": "${CLUSTER_NAME}",
  "_fluentbit": {
    "cluster": "${CLUSTER_NAME}",
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  }
}
EOF
)

echo "=========================================="
echo "Sending Event to Azure Event Hub"
echo "=========================================="
echo ""
echo "Event Hub:  ${EVENTHUB_NAMESPACE}/${EVENTHUB_NAME}"
echo "Reason:     ${EVENT_REASON}"
echo "Namespace:  ${EVENT_NAMESPACE}"
echo "Pod:        ${EVENT_POD_NAME}"
echo "Cluster:    ${CLUSTER_NAME}"
echo ""

# Check if this event would pass the filter
CRITICAL_REASONS="CrashLoopBackOff OOMKilled NodeNotReady FailedMount FailedScheduling Evicted"
SYSTEM_NAMESPACES="kube-system kube-public kube-node-lease cert-manager gatekeeper-system flux-system external-secrets azureserviceoperator-system"

WILL_TRIGGER="NO"
REASON_OK=false
NS_OK=true

for reason in $CRITICAL_REASONS; do
    if [[ "$EVENT_REASON" == "$reason" ]]; then
        REASON_OK=true
        break
    fi
done

for ns in $SYSTEM_NAMESPACES; do
    if [[ "$EVENT_NAMESPACE" == "$ns" ]]; then
        NS_OK=false
        break
    fi
done

if $REASON_OK && $NS_OK; then
    WILL_TRIGGER="YES"
    echo "Filter Check: PASS - Will trigger workflow"
else
    echo "Filter Check: FAIL - Will NOT trigger workflow"
    if ! $REASON_OK; then
        echo "  - Reason '${EVENT_REASON}' not in critical list"
    fi
    if ! $NS_OK; then
        echo "  - Namespace '${EVENT_NAMESPACE}' is in excluded list"
    fi
fi
echo ""

# Check if RESOURCE_GROUP is set
if [[ -z "$RESOURCE_GROUP" ]]; then
    # Try to get it from the Event Hub namespace
    RESOURCE_GROUP=$(az eventhubs namespace list --query "[?name=='${EVENTHUB_NAMESPACE}'].resourceGroup" -o tsv 2>/dev/null || true)
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "ERROR: Could not determine resource group for Event Hub namespace"
    echo "Please set RESOURCE_GROUP environment variable"
    exit 1
fi

echo "Resource Group: ${RESOURCE_GROUP}"
echo ""

# Get connection string
echo "Getting Event Hub connection string..."
CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
    --resource-group "$RESOURCE_GROUP" \
    --namespace-name "$EVENTHUB_NAMESPACE" \
    --name "RootManageSharedAccessKey" \
    --query primaryConnectionString -o tsv)

if [[ -z "$CONNECTION_STRING" ]]; then
    echo "ERROR: Could not get Event Hub connection string"
    exit 1
fi

# Send event using Azure CLI
echo "Sending event..."
echo ""

# Use Python to send the event (more reliable than az eventhubs event send)
python3 << PYTHON_SCRIPT
import json
import os
from azure.eventhub import EventHubProducerClient, EventData

connection_str = """${CONNECTION_STRING}"""
eventhub_name = "${EVENTHUB_NAME}"

# Create event data
event_json = '''${K8S_EVENT}'''
event_data = json.loads(event_json)

try:
    # Create producer
    producer = EventHubProducerClient.from_connection_string(
        conn_str=connection_str,
        eventhub_name=eventhub_name
    )

    with producer:
        # Create batch
        event_data_batch = producer.create_batch()
        event_data_batch.add(EventData(json.dumps(event_data)))

        # Send
        producer.send_batch(event_data_batch)
        print("SUCCESS: Event sent to Event Hub")
        print("")
        print("Event payload:")
        print(json.dumps(event_data, indent=2))

except ImportError:
    print("ERROR: azure-eventhub package not installed")
    print("Install with: pip install azure-eventhub")
    exit(1)
except Exception as e:
    print(f"ERROR: Failed to send event: {e}")
    exit(1)
PYTHON_SCRIPT

echo ""
echo "=========================================="
echo "Next Steps"
echo "=========================================="
echo ""
echo "1. Check EventSource logs:"
echo "   kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=20"
echo ""
echo "2. Check Sensor logs:"
echo "   kubectl logs -n argo-events -l sensor-name=eventhub-critical-events --tail=20"
echo ""
echo "3. Watch for workflows:"
echo "   kubectl get workflows -n argo-events -w"
echo ""
if [[ "$WILL_TRIGGER" == "YES" ]]; then
    echo "Expected: Workflow should be triggered (eh-critical-triage-*)"
else
    echo "Expected: No workflow triggered (event was filtered)"
fi
