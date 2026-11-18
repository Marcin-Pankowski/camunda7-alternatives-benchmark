#!/usr/bin/env bash
# Scenario A (or C with SCENARIO=c) for one engine: startup time, RAM, throughput + p95 per replica step and 10/25/50/100 VUs.
# Every replica count starts on a fresh, empty database. Results go to results/history-<HISTORY>[-<RUN_TAG>]/<engine>.jsonl.
# Scenario C results go to results/scenario-c-history-<HISTORY>[-<RUN_TAG>]/.
# Usage: [REPLICAS=1,2,3] [HISTORY=full] [RUN_TAG=iterfix] [SCENARIO=a|c] ./bench.sh cibseven   (normally called by scenario-a.sh, which also sets the Kafgres CPUs)
set -euo pipefail
cd "$(dirname "$0")"
ENGINE=$1 NS=bench REPLICAS=${REPLICAS:-1,2,3} HISTORY=${HISTORY:-full} SCENARIO=${SCENARIO:-a}
# RUN_TAG keeps a re-measurement (e.g. with patched images) apart from the main runs
DIR=results/$([ "$SCENARIO" = a ] || echo "scenario-$SCENARIO-")history-$HISTORY${RUN_TAG:+-$RUN_TAG}
OUT=$DIR/$1.jsonl
mkdir -p "$DIR"; : > "$OUT"
# ENGINE_CPU/ENGINE_MEM only take effect for engines with their own start.sh (Camunda 8)
[ -n "${ENGINE_CPU:-}${ENGINE_MEM:-}" ] && [ ! -x "k8s/$ENGINE/start.sh" ] && { echo "ENGINE_CPU/ENGINE_MEM work only for camunda8" >&2; exit 1; }
# ENGINE_TAG: run another local image tag than the manifest's 1.0.0 (e.g. 1.0.0-feel1196); not for engines with start.sh
[ -n "${ENGINE_TAG:-}" ] && [ -x "k8s/$ENGINE/start.sh" ] && { echo "ENGINE_TAG does not work for $ENGINE" >&2; exit 1; }
DB_CPU=$(kubectl -n $NS get deploy/kafgres -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}')
echo "{\"type\":\"config\",\"engine\":\"$ENGINE\",\"db_cpu\":\"$DB_CPU\",\"engine_cpu\":\"${ENGINE_CPU:-1}\",\"engine_mem\":\"${ENGINE_MEM:-2Gi}\",\"image_tag\":\"${ENGINE_TAG:-1.0.0}\",\"history\":\"$HISTORY\",\"scenario\":\"$SCENARIO\",\"run_tag\":\"${RUN_TAG:-}\",\"replicas\":[$REPLICAS]}" >> "$OUT"
elapsed() { echo "$(date +%s.%N) - $1" | bc | xargs printf %.1f; }
log() { echo "$(date +%T) $*" >&2; }

fresh_db() {
  kubectl delete -k "k8s/$ENGINE" --ignore-not-found --wait >/dev/null
  kubectl -n $NS rollout restart deploy/kafgres >/dev/null
  kubectl -n $NS rollout status deploy/kafgres --timeout=180s >/dev/null
}

top_col() {  # $1 app label, $2 column (2 = CPU in millicores, 3 = memory in MiB) of every pod, e.g. [612,598]
  kubectl -n $NS top pod -l app="$1" --no-headers | awk -v c="$2" '{gsub("Mi|m","",$c); printf "%s%s", (NR>1?",":"["), $c} END {print "]"}'
}
ram_mib() { top_col "$ENGINE" 3; }

run_k6() {  # $1 = VUs; prints the RESULT json
  kubectl -n $NS delete pod k6 --ignore-not-found >/dev/null
  kubectl -n $NS run k6 --rm -i --restart=Never --image=grafana/k6:1.8.3 --overrides="{
    \"spec\": {\"containers\": [{\"name\": \"k6\", \"image\": \"grafana/k6:1.8.3\",
      \"args\": [\"run\", \"--quiet\", \"-e\", \"ENGINE=$ENGINE\", \"-e\", \"VUS=$1\", \"/scripts/scenario-$SCENARIO.js\"],
      \"volumeMounts\": [{\"name\": \"s\", \"mountPath\": \"/scripts\"}],
      \"resources\": {\"requests\": {\"cpu\": \"250m\", \"memory\": \"256Mi\"}, \"limits\": {\"cpu\": \"2\", \"memory\": \"1Gi\"}}}],
    \"volumes\": [{\"name\": \"s\", \"configMap\": {\"name\": \"k6-scenario-$SCENARIO\"}}]}}" 2>/dev/null | sed -n 's/^RESULT //p'
}

# Remove the engine also on failure, so leftover pods never block the next engine.
trap 'kubectl delete -k "k8s/$ENGINE" --ignore-not-found >/dev/null' EXIT

# scenario C also needs the rule list the expected fees are computed from
K6_FILES=(--from-file=load/scenario-$SCENARIO.js); [ "$SCENARIO" = c ] && K6_FILES+=(--from-file=load/scenario-c-rules.json)
kubectl -n $NS create configmap k6-scenario-$SCENARIO "${K6_FILES[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

for R in ${REPLICAS//,/ }; do
  log "$ENGINE: fresh database, starting $R replica(s)"
  fresh_db
  t0=$(date +%s.%N)
  if [ -x "k8s/$ENGINE/start.sh" ]; then
    # Own start script (Camunda 8: cluster size is fixed at start), so all R pods start at once, no scale-out step.
    "k8s/$ENGINE/start.sh" $R
    echo "{\"type\":\"startup\",\"engine\":\"$ENGINE\",\"replicas\":$R,\"seconds\":$(elapsed "$t0")}" >> "$OUT"
  else
    # First replica alone (it creates the schema), then scale out: concurrent schema creation would race.
    kubectl kustomize "k8s/$ENGINE" | sed "s|image: bench-$ENGINE:1.0.0$|image: bench-$ENGINE:${ENGINE_TAG:-1.0.0}|" | kubectl apply -f - >/dev/null
    kubectl -n $NS rollout status deploy/"$ENGINE" --timeout=600s >/dev/null
    echo "{\"type\":\"startup\",\"engine\":\"$ENGINE\",\"replicas\":1,\"seconds\":$(elapsed "$t0")}" >> "$OUT"
    if [ $R -gt 1 ]; then
      t0=$(date +%s.%N)
      kubectl -n $NS scale deploy/"$ENGINE" --replicas=$R >/dev/null
      kubectl -n $NS rollout status deploy/"$ENGINE" --timeout=600s >/dev/null
      echo "{\"type\":\"scale_out\",\"engine\":\"$ENGINE\",\"replicas\":$R,\"seconds\":$(elapsed "$t0")}" >> "$OUT"
    fi
  fi
  sleep 60   # let metrics-server report the idle footprint
  echo "{\"type\":\"ram_idle\",\"engine\":\"$ENGINE\",\"replicas\":$R,\"mib\":$(ram_mib)}" >> "$OUT"

  for V in 10 25 50 100; do
    log "$ENGINE: $R replica(s), $V VUs"
    (sleep 90; echo "{\"type\":\"ram_load\",\"engine\":\"$ENGINE\",\"replicas\":$R,\"vus\":$V,\"mib\":$(ram_mib),\"cpu_m\":$(top_col "$ENGINE" 2),\"db_cpu_m\":$(top_col kafgres 2)}" >> "$OUT") &
    res=$(run_k6 $V)
    wait
    echo "{\"type\":\"load\",\"replicas\":$R,${res#\{}" >> "$OUT"
    log "  $res"
  done
done
log "done: $OUT"
