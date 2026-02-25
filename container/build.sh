#!/bin/bash
# Build the NanoClaw agent container image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="nanoclaw-agent"
TAG="${1:-latest}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-container}"

get_builder_status() {
  local output rc
  output="$(${CONTAINER_RUNTIME} builder status 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    if echo "${output}" | grep -qiE 'not found|no builder|does not exist'; then
      echo "MISSING"
    else
      echo "ERROR"
    fi
    return
  fi

  if echo "${output}" | grep -qE '(^|[[:space:]])RUNNING([[:space:]]|$)'; then
    echo "RUNNING"
    return
  fi

  if echo "${output}" | grep -qE '(^|[[:space:]])STOPPED([[:space:]]|$)'; then
    echo "STOPPED"
    return
  fi

  echo "UNKNOWN"
}

ensure_builder_healthy() {
  local status corrupt
  status="$(get_builder_status)"

  # Check for storage corruption in running builder
  if [[ "${status}" == "RUNNING" ]]; then
    corrupt=$(${CONTAINER_RUNTIME} logs buildkit 2>&1 | grep -c "structure needs cleaning" || true)
    if [[ "${corrupt}" -gt 0 ]]; then
      echo "WARNING: Buildkit storage corruption detected (${corrupt} occurrences)."
      echo "Destroying and recreating builder to recover..."
      ${CONTAINER_RUNTIME} stop buildkit 2>/dev/null || pkill -f buildkit 2>/dev/null || true
      sleep 2
      ${CONTAINER_RUNTIME} rm buildkit 2>/dev/null || true
      status="DESTROYED"
    fi
  fi

  if [[ "${status}" != "RUNNING" ]]; then
    echo "Builder not running (${status}). Attempting start..."
    ${CONTAINER_RUNTIME} builder start 2>/dev/null || true
    sleep 3
    status="$(get_builder_status)"
    if [[ "${status}" != "RUNNING" ]]; then
      echo "Builder failed to start. Trying full reset (rm + start)..."
      ${CONTAINER_RUNTIME} rm buildkit 2>/dev/null || true
      ${CONTAINER_RUNTIME} builder start 2>/dev/null || true
      sleep 3
      status="$(get_builder_status)"
      if [[ "${status}" != "RUNNING" ]]; then
        echo "Builder failed to start after reset." >&2
        exit 1
      fi
    fi
  fi
  echo "Builder healthy (${status})"
}

echo "Building NanoClaw agent container image..."
echo "Image: ${IMAGE_NAME}:${TAG}"

ensure_builder_healthy
${CONTAINER_RUNTIME} build -t "${IMAGE_NAME}:${TAG}" .

echo ""
echo "Build complete!"
echo "Image: ${IMAGE_NAME}:${TAG}"
echo ""
echo "Test with:"
echo "  echo '{\"prompt\":\"What is 2+2?\",\"groupFolder\":\"test\",\"chatJid\":\"test@g.us\",\"isMain\":false}' | ${CONTAINER_RUNTIME} run -i ${IMAGE_NAME}:${TAG}"
