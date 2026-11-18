#!/usr/bin/env bash
# Smoke test of the bare cluster: Postgres, Kafka protocol (Kafgres), ingress/load balancer, k6.
set -euo pipefail
cd "$(dirname "$0")"
NS=bench

echo "== Postgres"
kubectl -n $NS exec deploy/kafgres -- psql -U postgres -tAc "SELECT version()" | cut -c1-40

echo "== Kafka protocol via service name (checks the advertised host)"
kubectl -n $NS exec deploy/kafgres -- psql -U postgres -tAc "SELECT kafgres_create_topic('smoke', 1)" >/dev/null 2>&1 || true
kubectl -n $NS delete pod rpk --ignore-not-found >/dev/null
kubectl -n $NS run rpk --rm -i --restart=Never --image=redpandadata/redpanda:v26.2.7 --command -- sh -c '
  B="-X brokers=kafgres.bench.svc.cluster.local:9092"
  echo "hello-$(date +%s)" | rpk topic produce smoke $B &&
  rpk topic consume smoke $B -n 1 -o start -f "consumed: %v\n"'

echo "== Load balancer + k6"
kubectl apply -k k8s/smoke >/dev/null
kubectl -n $NS rollout status deploy/whoami --timeout=120s
kubectl -n $NS create configmap k6-smoke --from-file=load/smoke.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS delete pod k6-smoke --ignore-not-found >/dev/null
kubectl -n $NS run k6-smoke --rm -i --restart=Never --image=grafana/k6:1.8.3 --overrides='{
  "spec": {"containers": [{"name": "k6-smoke", "image": "grafana/k6:1.8.3",
    "args": ["run", "--quiet", "/scripts/smoke.js"],
    "volumeMounts": [{"name": "s", "mountPath": "/scripts"}],
    "resources": {"limits": {"cpu": "1", "memory": "512Mi"}}}],
  "volumes": [{"name": "s", "configMap": {"name": "k6-smoke"}}]}}'
kubectl delete -k k8s/smoke >/dev/null
echo "smoke test passed"
