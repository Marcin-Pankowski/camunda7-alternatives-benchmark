#!/usr/bin/env bash
# Create the local k3d cluster and load the locally built images. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
K3D=bin/k3d
[ -x $K3D ] || { mkdir -p bin; curl -fsSL -o $K3D https://github.com/k3d-io/k3d/releases/download/v5.9.0/k3d-darwin-arm64; chmod +x $K3D; }

$K3D cluster list bench >/dev/null 2>&1 || $K3D cluster create --config k3d.yaml --wait
kubectl config use-context k3d-bench >/dev/null

# Kafgres has no published image: build it from the git tag once, then copy it into the cluster.
docker image inspect kafgres-postgres:0.3.1 >/dev/null 2>&1 ||
  docker build -t kafgres-postgres:0.3.1 -f docker/Dockerfile https://github.com/RayElg/kafgres.git#0.3.1
$K3D image import -c bench kafgres-postgres:0.3.1

kubectl apply -k k8s/base
kubectl -n bench rollout status deploy/kafgres --timeout=180s
