#!/bin/bash

# Simple pre-commit hook using detect-secrets on staged files
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}🔒 Running secret detection pre-commit hook...${NC}"

# Get staged files
staged_files=$(git diff --cached --name-only --diff-filter=ACM)

if [ -z "$staged_files" ]; then
    echo -e "${GREEN}✅ No staged files to check${NC}"
    exit 0
fi

# Create temp directory for detect-secrets
temp_dir=$(mktemp -d)
temp_baseline="$temp_dir/.secrets.baseline"

# Run detect-secrets scan on staged files
echo "$staged_files" | xargs python3 -m detect_secrets scan \
    --exclude-files '\.md$|\.txt$|\.log$|\.example$|\.template$|\.sample$' \
    --exclude-lines 'example|sample|test|fake|placeholder|your_|my_|<|>|\[|\]' \
    > "$temp_baseline" 2>/dev/null

# Check if secrets were found
secrets_count=$(cat "$temp_baseline" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    count = sum(len(files) for files in data.get('results', {}).values())
    print(count)
except:
    print(0)
")

# Cleanup
rm -rf "$temp_dir"

if [ "$secrets_count" -gt 0 ]; then
    echo -e "${RED}🚨 COMMIT BLOCKED: $secrets_count potential secret(s) detected!${NC}"
    echo "Run 'git commit --no-verify' to skip this check"
    echo "Or run './scripts/scan-secrets.sh' for detailed analysis"
    exit 1
else
    echo -e "${GREEN}✅ No secrets detected. Commit allowed.${NC}"
    exit 0
fi