#!/usr/bin/env bash
set -e
IMAGE_NAME="nanoclaw-worker"
TAG="${1:-latest}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-container}"
cd "$(dirname "$0")"
VENDOR_DIR="$(pwd)/vendor"
OPENCODE_BUNDLE="${VENDOR_DIR}/opencode-ai-node_modules.tgz"
REFRESH_OPENCODE_BUNDLE="${REFRESH_OPENCODE_BUNDLE:-0}"

prepare_opencode_bundle() {
  mkdir -p "${VENDOR_DIR}"

  if [[ "${REFRESH_OPENCODE_BUNDLE}" != "1" && -f "${OPENCODE_BUNDLE}" ]]; then
    echo "Using cached OpenCode bundle: ${OPENCODE_BUNDLE}"
    return
  fi

  rm -f "${OPENCODE_BUNDLE}"

  local attempt
  for attempt in 1 2 3; do
    echo "Preparing OpenCode bundle (attempt ${attempt}/3)..."
    if ${CONTAINER_RUNTIME} run --rm \
      -e NODE_OPTIONS="--dns-result-order=ipv4first" \
      -v "${VENDOR_DIR}:/out" \
      node:22 sh -lc \
      "set -e;
       npm config set fetch-retries 5;
       npm config set fetch-retry-mintimeout 20000;
       npm config set fetch-retry-maxtimeout 120000;
       npm config set fetch-timeout 180000;
       npm view opencode-ai version >/dev/null;
       npm install -g --no-audit --no-fund --loglevel=warn opencode-ai;
       tar -C /usr/local/lib/node_modules -czf /out/opencode-ai-node_modules.tgz opencode-ai"; then
      echo "Prepared OpenCode bundle: ${OPENCODE_BUNDLE}"
      return
    fi
    sleep $((attempt * 2))
  done

  echo "Failed to prepare OpenCode bundle after 3 attempts" >&2
  exit 1
}

prepare_opencode_bundle
${CONTAINER_RUNTIME} build -t "${IMAGE_NAME}:${TAG}" .
echo "Built ${IMAGE_NAME}:${TAG}"
