#!/bin/bash
# Test Local LLM integration

echo "========================================"
echo "Testing Local Qwen LLM Integration"
echo "========================================"
echo ""

LOCAL_LLM_URL="${LOCAL_LLM_URL:-http://kubeai.kubeai.svc.cluster.local/openai/v1}"
MODEL="${LLM_MODEL:-qwen3-14b}"

echo "Testing connectivity to ${LOCAL_LLM_URL}..."

# Test 1: Models endpoint
HTTP_CODE=$(curl -s -o /tmp/models.json -w "%{http_code}" \
  --connect-timeout 10 \
  "${LOCAL_LLM_URL}/models" 2>/dev/null)

if [ "${HTTP_CODE}" -eq 200 ]; then
  MODEL_NAME=$(cat /tmp/models.json | jq -r '.data[0].id // empty')
  echo "✅ Local LLM reachable"
  echo "   Model: ${MODEL_NAME}"
else
  echo "❌ Local LLM not reachable (HTTP ${HTTP_CODE})"
  exit 1
fi

echo ""
echo "Testing chat completion..."

# Test 2: Chat completion
START_TIME=$(date +%s.%N)

HTTP_CODE=$(curl -s -o /tmp/chat.json -w "%{http_code}" \
  --connect-timeout 10 \
  --max-time 60 \
  -X POST "${LOCAL_LLM_URL}/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a Kubernetes expert.\"},
      {\"role\": \"user\", \"content\": \"What are 3 common causes of Pod CrashLoopBackOff?\"}
    ],
    \"max_tokens\": 500,
    \"temperature\": 0.3
  }" 2>/dev/null)

END_TIME=$(date +%s.%N)
DURATION=$(echo "${END_TIME} - ${START_TIME}" | bc 2>/dev/null || echo "N/A")

if [ "${HTTP_CODE}" -eq 200 ]; then
  echo "✅ Chat completion successful"
  
  TOKENS=$(cat /tmp/chat.json | jq -r '.usage.total_tokens // 0')
  CONTENT=$(cat /tmp/chat.json | jq -r '.choices[0].message.content // empty')
  
  echo "   Tokens used: ${TOKENS}"
  echo "   Duration: ${DURATION}s"
  echo ""
  echo "Response preview:"
  echo "${CONTENT:0:300}..."
  echo ""
  echo "========================================"
  echo "✅ Local LLM test PASSED"
  echo "========================================"
  exit 0
else
  echo "❌ Chat completion failed (HTTP ${HTTP_CODE})"
  cat /tmp/chat.json | jq . 2>/dev/null || cat /tmp/chat.json
  exit 1
fi
