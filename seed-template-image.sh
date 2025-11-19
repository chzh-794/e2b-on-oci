#!/bin/bash
#
# Seed a template Docker image on the Nomad client node so the local
# Template Manager (ARTIFACTS_REGISTRY_PROVIDER=Local) can pull it during a build.
#
# Usage:
#   ./seed-template-image.sh --template-id <template> --build-id <uuid> \
#     [--client-host <ip>] [--bastion-host <ip>] [--ssh-user ubuntu] \
#     [--ssh-key ~/.ssh/id_rsa] [--context <dir> | --dockerfile <content>]
#
# The script copies the Docker build context to the remote client host,
# builds the image, and tags it as <template-id>:<build-id>.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/tmp/e2b-template-build"

TEMPLATE_ID=""
BUILD_ID=""
CLIENT_HOST="${CLIENT_POOL_PUBLIC:-}"
BASTION_HOST="${BASTION_HOST:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
DOCKER_CONTEXT=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --template-id <template> --build-id <uuid> [options]

Required arguments:
  --template-id     Template identifier returned by the API (alias or generated id)
  --build-id        Build UUID returned by the API when requesting a build

Optional arguments:
  --client-host     Client pool public IP (defaults to \$CLIENT_POOL_PUBLIC)
  --bastion-host    Bastion public IP (defaults to \$BASTION_HOST). If empty, connect directly.
  --ssh-user        SSH username (default: ${SSH_USER})
  --ssh-key         SSH private key (default: ${SSH_KEY})
  --context         Docker build context directory (required if not using --dockerfile)
  --dockerfile       Dockerfile content as string (required if not using --context)

Example:
  ./seed-template-image.sh --template-id base-poc --build-id 123e4567-e89b-12d3-a456-426614174000 \\
    --client-host 10.0.2.73 --bastion-host 192.0.2.10 \\
    --dockerfile "FROM ubuntu:22.04\\nRUN apt-get update && apt-get install -y python3"
  
  OR with a context directory:
  ./seed-template-image.sh --template-id base-poc --build-id 123e4567-e89b-12d3-a456-426614174000 \\
    --client-host 10.0.2.73 --context /path/to/docker/context
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template-id)
      TEMPLATE_ID="$2"
      shift 2
      ;;
    --build-id)
      BUILD_ID="$2"
      shift 2
      ;;
    --client-host)
      CLIENT_HOST="$2"
      shift 2
      ;;
    --bastion-host)
      BASTION_HOST="$2"
      shift 2
      ;;
    --ssh-user)
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="$2"
      shift 2
      ;;
    --context)
      DOCKER_CONTEXT="$2"
      shift 2
      ;;
    --dockerfile)
      DOCKERFILE="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "${TEMPLATE_ID}" || -z "${BUILD_ID}" ]]; then
  echo "Error: --template-id and --build-id are required." >&2
  usage
fi

if [[ -z "${CLIENT_HOST}" ]]; then
  echo "Error: --client-host not provided and \$CLIENT_POOL_PUBLIC unset." >&2
  usage
fi

if [[ -z "${DOCKER_CONTEXT}" && -z "${DOCKERFILE:-}" ]]; then
  echo "Error: Either --context or --dockerfile must be provided." >&2
  usage
fi

if [[ -n "${DOCKER_CONTEXT}" && -n "${DOCKERFILE:-}" ]]; then
  echo "Error: Cannot specify both --context and --dockerfile." >&2
  usage
fi

if [[ -n "${DOCKER_CONTEXT}" && ! -d "${DOCKER_CONTEXT}" ]]; then
  echo "Error: Docker context '${DOCKER_CONTEXT}' does not exist." >&2
  exit 1
fi

SSH_BASE_OPTS=(-i "${SSH_KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no)
if [[ -n "${BASTION_HOST}" ]]; then
  SSH_BASE_OPTS+=(-o "ProxyJump=${SSH_USER}@${BASTION_HOST}")
fi

REMOTE_PATH="${WORK_DIR}/${TEMPLATE_ID}/${BUILD_ID}"

echo "╔══════════════════════════════════════════════╗"
echo "║   Seeding template image on client host      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Template ID : ${TEMPLATE_ID}"
echo "Build ID    : ${BUILD_ID}"
echo "Client Host : ${CLIENT_HOST}"
if [[ -n "${BASTION_HOST}" ]]; then
  echo "Bastion     : ${BASTION_HOST}"
fi
if [[ -n "${DOCKERFILE:-}" ]]; then
  echo "Dockerfile  : (provided via --dockerfile)"
else
echo "Context     : ${DOCKER_CONTEXT}"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [1/3] Preparing Docker build context on client"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ssh "${SSH_BASE_OPTS[@]}" "${SSH_USER}@${CLIENT_HOST}" "rm -rf '${REMOTE_PATH}' && mkdir -p '${REMOTE_PATH}'"

if [[ -n "${DOCKERFILE:-}" ]]; then
  # Use provided Dockerfile content
  printf '%s' "${DOCKERFILE}" | ssh "${SSH_BASE_OPTS[@]}" "${SSH_USER}@${CLIENT_HOST}" "cat > '${REMOTE_PATH}/Dockerfile'"
else
  # Copy context directory
scp "${SSH_BASE_OPTS[@]}" -r "${DOCKER_CONTEXT}/." "${SSH_USER}@${CLIENT_HOST}:${REMOTE_PATH}/"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [2/3] Building Docker image on client"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ssh "${SSH_BASE_OPTS[@]}" "${SSH_USER}@${CLIENT_HOST}" <<EOF
set -euo pipefail
cd "${REMOTE_PATH}"
sudo docker build --pull --tag "${TEMPLATE_ID}:${BUILD_ID}" .
sudo docker image inspect "${TEMPLATE_ID}:${BUILD_ID}" >/dev/null
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [3/3] Verifying local registry state"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ssh "${SSH_BASE_OPTS[@]}" "${SSH_USER}@${CLIENT_HOST}" "sudo docker image ls '${TEMPLATE_ID}:${BUILD_ID}'"

echo ""
echo "✓ Template image '${TEMPLATE_ID}:${BUILD_ID}' is ready on ${CLIENT_HOST}"
echo "You can now trigger the Template Manager build:"
echo "  POST /templates/${TEMPLATE_ID}/builds/${BUILD_ID}"



