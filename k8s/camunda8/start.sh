#!/usr/bin/env bash
# Starts Camunda 8 with N brokers (= N partitions) at once and deploys the process; returns when it accepts process starts.
# Zeebe fixes cluster size and partition count at start, so a running cluster is not scaled out like the other engines.
# Usage: [HISTORY=none] [ENGINE_CPU=3500m ENGINE_MEM=8Gi] k8s/camunda8/start.sh [N]   (none: no secondary storage, only the broker state;
#   ENGINE_CPU/ENGINE_MEM: resources per broker for special runs, default 1 CPU / 2Gi like every engine)
set -euo pipefail
cd "$(dirname "$0")"
N=${1:-1}
# none: no secondary storage; Operate/Tasklist/Identity need it and fail to start, so only the broker profile (engine + REST).
STORAGE=rdbms PROFILE=; [ "${HISTORY:-full}" = none ] && STORAGE=none PROFILE='\
            - {name: SPRING_PROFILES_ACTIVE, value: broker}'
CONTACTS=$(for i in $(seq 0 $((N-1))); do printf 'camunda8-%s.camunda8-headless.bench.svc.cluster.local:26502,' "$i"; done)
# Rewrite the 1-broker values in the manifest itself (kustomize output would split name/value onto separate lines).
sed -e "s/replicas: 1$/replicas: $N/" -e "s/{cpu: \"1\", memory: 2Gi}/{cpu: \"${ENGINE_CPU:-1}\", memory: ${ENGINE_MEM:-2Gi}}/" \
    -e "s/\(CAMUNDA_CLUSTER_SIZE, value: \)\"1\"/\1\"$N\"/" -e "s/\(CAMUNDA_CLUSTER_PARTITIONCOUNT, value: \)\"1\"/\1\"$N\"/" \
    -e "s/\(CAMUNDA_DATA_SECONDARYSTORAGE_TYPE, value: \)rdbms/\1$STORAGE/" \
    -e "s|^\(            - {name: CAMUNDA_CLUSTER_SIZE.*\)$|\1$PROFILE|" \
    -e "s/\(CAMUNDA_CLUSTER_INITIALCONTACTPOINTS, value: \)\"[^\"]*\"/\1\"${CONTACTS%,}\"/" camunda8.yaml | kubectl -n bench apply -f - >/dev/null
kubectl -n bench rollout status statefulset/camunda8 --timeout=600s >/dev/null
# Deploy through the load balancer; retry until Traefik routes to the new pods.
for _ in $(seq 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: camunda8.bench.local' -F "resources=@scenario-a.bpmn" -F "resources=@scenario-b.bpmn" -F "resources=@pricing.dmn" http://127.0.0.1:8081/v2/deployments) || true
  [ "$code" = 200 ] && exit 0
  sleep 1
done
echo "camunda8: deployment failed (last HTTP $code)" >&2
exit 1
