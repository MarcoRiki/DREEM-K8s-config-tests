#!/usr/bin/env bash
# Builds the Karpenter Cluster API provider image from a pinned commit and pushes it to
# Harbor, next to the DREEM images (docker login harbor.ng.crownlabs.polito.it first). No
# image of the provider is published (its staging registry is empty). Pulls need no
# credentials: the project is public.
#
# Usage: ./build-image.sh [--commit=<sha>] [--registry=<host[:port]/path>] [--no-push]
#
# --registry=192.168.111.1:5000/localimages pushes to the local metal3-dev-env registry
# instead, which minikube also pulls from without credentials.
#
# The commit is pinned for reproducibility: main after v0.2.0, with the fixes the testbed
# needs (machine selection on create, MachineDeployment max-size check, create/delete
# batching), on Karpenter core v1.5.0 and Cluster API v1.10 types.

set -euo pipefail

COMMIT=9dc28cf
REGISTRY=harbor.ng.crownlabs.polito.it/marco-miracapillo
PUSH=true
for arg in "$@"; do
  case "$arg" in
    --commit=*)   COMMIT="${arg#--commit=}" ;;
    --registry=*) REGISTRY="${arg#--registry=}" ;;
    --no-push)    PUSH=false ;;
    -h|--help)    awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

IMAGE="$REGISTRY/karpenter-clusterapi-controller:$COMMIT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "cloning kubernetes-sigs/karpenter-provider-cluster-api at $COMMIT"
git clone -q https://github.com/kubernetes-sigs/karpenter-provider-cluster-api.git "$WORK/src"
git -C "$WORK/src" checkout -q "$COMMIT"

echo "building $IMAGE"
# Two upstream Dockerfile problems at this commit:
#  - the default builder (golang:1.24.2) is older than the go.mod requirement (go 1.25),
#    so the Go version is given explicitly;
#  - ARCH is declared before the first FROM, so it reaches the FROM lines (the amd64
#    distroless base) but not the go build, which compiles for the machine it runs on. On
#    an ARM machine (e.g. an Apple Silicon Mac) that gives an ARM binary in an amd64 image,
#    labelled arm64: it fails everywhere. --platform linux/amd64 runs the whole build as
#    amd64 (emulated on ARM) and labels the image correctly.
docker buildx build --load --platform linux/amd64 --build-arg ARCH=amd64 \
  --build-arg BUILDER_IMAGE=docker.io/library/golang:1.25 -t "$IMAGE" "$WORK/src"

# keep the CRDs of the same commit next to the manifests, so what is installed in the
# workload cluster always matches the controller
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERE/crds"
cp "$WORK/src/pkg/apis/crds/"*.yaml "$HERE/crds/"
echo "CRDs of $COMMIT copied to $HERE/crds/"

if $PUSH; then
  docker push "$IMAGE"
  echo "pushed $IMAGE"
fi
echo "export KARPENTER_IMAGE=$IMAGE"
