#!/usr/bin/env bash
# Build the Orca server image and optionally push it to a registry the
# OpenShell gateway can pull from. Usage:
#   ./build.sh                  # build locally
#   ./build.sh ghcr.io/you/orca-server:latest   # build and push
set -euo pipefail

ORCA_VERSION="${ORCA_VERSION:-v1.4.273}"
BASE_TAG="orca-server-base:dev"
FINAL_TAG="orca-server:dev"

command -v podman >/dev/null || { echo "podman not found" >&2; exit 1; }

echo ">> building ${BASE_TAG} (Orca ${ORCA_VERSION})"
podman build --build-arg "ORCA_VERSION=${ORCA_VERSION}" -t "${BASE_TAG}" .

if command -v openshell-build-image >/dev/null 2>&1; then
  echo ">> applying OpenShell image preparation -> ${FINAL_TAG}"
  openshell-build-image --runtime podman --from "${BASE_TAG}" \
    --copy-containerfile "${FINAL_TAG}"
  echo ">> audit with: podman run --rm --entrypoint /bin/sh ${FINAL_TAG} -c 'cat \$HOME/Containerfile'"
else
  echo ">> openshell-build-image not found; tagging the base image directly." >&2
  echo ">> sandbox create --from accepts it as-is, but install the tool for the" >&2
  echo ">> OpenShell-specific layer: https://github.com/openkaiden/openshell-build-image" >&2
  podman tag "${BASE_TAG}" "${FINAL_TAG}"
fi

if [ $# -gt 0 ]; then
  registry_ref="$1"
  echo ">> pushing ${registry_ref}"
  podman tag "${FINAL_TAG}" "${registry_ref}"
  podman push "${registry_ref}"
  echo ">> done. Use with: ORCA_SERVER_IMAGE=${registry_ref} ./server.sh up"
fi
