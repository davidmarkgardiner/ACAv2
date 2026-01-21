#!/bin/bash
# Generate Event Hub format payload from raw K8s event
#
# Usage:
#   ./generate-payload.sh <raw-json-file>
#   ./generate-payload.sh test-payload-raw.json
#
# Or with inline JSON:
#   echo '{"cluster":"test","reason":"BackOff",...}' | ./generate-payload.sh
#

set -e

if [ -n "$1" ] && [ -f "$1" ]; then
    RAW_JSON=$(cat "$1")
else
    RAW_JSON=$(cat)
fi

# Base64 encode the raw JSON
ENCODED=$(echo -n "$RAW_JSON" | base64 | tr -d '\n')

# Create Event Hub format payload
cat << EOF
{
  "body": "$ENCODED",
  "id": "test-$(date +%s)",
  "partitionKey": "test"
}
EOF
