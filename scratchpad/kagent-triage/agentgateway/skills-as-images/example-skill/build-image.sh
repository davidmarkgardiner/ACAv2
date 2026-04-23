#!/usr/bin/env bash
# Local build helper for testing a skill image before wiring up CI.
# For production, use the Gitea Actions / GitHub Actions workflow in the
# parent README.md.

set -euo pipefail

# ─── Edit these ─────────────────────────────────────────────────────────────
REGISTRY="gitea.internal.bank.com/platform"     # your registry + path prefix
SKILL_NAME="example-skill"                       # image name
TAG="${TAG:-dev}"                                # override: TAG=v1 ./build-image.sh
# ────────────────────────────────────────────────────────────────────────────

IMAGE="${REGISTRY}/${SKILL_NAME}:${TAG}"

echo "==> Building $IMAGE"
docker build -t "$IMAGE" .

echo "==> Image details"
docker images "$IMAGE" --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}'

echo "==> Inspecting contents"
# List everything in the image
docker run --rm --entrypoint "" "$IMAGE" 2>/dev/null || true
# Extract + list (works even without an entrypoint)
CID=$(docker create "$IMAGE")
docker export "$CID" | tar -tvf - | grep -v '^d' | head -20
docker rm "$CID" >/dev/null

echo
echo "==> To push:"
echo "    docker login ${REGISTRY%%/*}"
echo "    docker push $IMAGE"
echo
echo "==> To use in an Agent:"
echo "    spec:"
echo "      skills:"
echo "        refs:"
echo "          - $IMAGE"
