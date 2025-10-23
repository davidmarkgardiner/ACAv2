#!/bin/bash

# Build ZIP artifact for Azure Function App deployment to Container Apps

set -e  # Exit on error

# Configuration
ARTIFACT_NAME="function-app.zip"
SOURCE_DIR="."

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Building Function App ZIP Artifact ===${NC}"
echo ""

# Clean up old artifact if exists
if [ -f "$ARTIFACT_NAME" ]; then
    echo -e "${YELLOW}Removing existing artifact...${NC}"
    rm "$ARTIFACT_NAME"
fi

# Files to include in artifact
FILES_TO_INCLUDE=(
    "function_app.py"
    "host.json"
    "requirements.txt"
)

# Verify all required files exist
echo "Verifying required files..."
for file in "${FILES_TO_INCLUDE[@]}"; do
    if [ ! -f "$file" ]; then
        echo -e "${RED}Error: Required file not found: $file${NC}"
        exit 1
    fi
    echo "  ✓ $file"
done
echo ""

# Create ZIP artifact
echo "Creating ZIP artifact..."
zip -q "$ARTIFACT_NAME" "${FILES_TO_INCLUDE[@]}"

# Verify artifact created
if [ -f "$ARTIFACT_NAME" ]; then
    SIZE=$(ls -lh "$ARTIFACT_NAME" | awk '{print $5}')
    echo ""
    echo -e "${GREEN}✓ Artifact created successfully!${NC}"
    echo "  File: $ARTIFACT_NAME"
    echo "  Size: $SIZE"
    echo ""
    echo "Contents:"
    unzip -l "$ARTIFACT_NAME"
    echo ""
    echo -e "${GREEN}Ready for deployment!${NC}"
    echo "Run: ./deploy-artifact.sh"
else
    echo -e "${RED}Error: Failed to create artifact${NC}"
    exit 1
fi
