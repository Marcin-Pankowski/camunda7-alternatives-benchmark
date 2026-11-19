#!/usr/bin/env bash
# Scenario A for several engines in a row: one smoke request each (counter must come back as 3), then bench.sh.
# Usage: [SMOKE_ONLY=1] ./scenario-a.sh [--db-cpu 4] [--replicas 1,2,3] [--history full|none] [--scenario a|b] cibseven operaton …
#   --db-cpu    CPUs for Kafgres (request = limit), default 4
#   --replicas  replica steps per engine, e.g. 1,2,3 or 1,2,4,8; default 1,2,3. Every engine pod gets 1 CPU.
#   --history   full (default): every change is recorded (history level full / Kogito process events / Camunda 8
#               secondary storage). none: only the runtime state is persisted. Results go to results/history-<value>/
#               (RUN_TAG=<tag> in the environment: results/history-<value>-<tag>/, for re-measurements).
#   --scenario  a (default): 3 tasks counter+1. b: one business rule task, 100-rule DMN table (COLLECT + SUM);
#               results in results/scenario-b-history-<value>/.
set -uo pipefail
cd "$(dirname "$0")"
LB=http://127.0.0.1:8081
C7_BODY='{"variables":{"counter":{"value":0,"type":"Integer"}},"withVariablesInReturn":true}'
DB_CPU=4 REPLICAS=1,2,3 HISTORY=full SCENARIO=a
while [[ ${1:-} == --* ]]; do
  case $1 in
    --db-cpu)   DB_CPU=$2; shift 2 ;;
    --replicas) REPLICAS=$2; shift 2 ;;
    --history)  HISTORY=$2; shift 2 ;;
    --scenario) SCENARIO=$2; shift 2 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done
[[ $DB_CPU =~ ^[0-9]+$ && $REPLICAS =~ ^[0-9]+(,[0-9]+)*$ && $HISTORY =~ ^(full|none)$ && $SCENARIO =~ ^(a|b)$ ]] \
  || { echo "--db-cpu needs a number, --replicas a list like 1,2,4, --history full or none, --scenario a or b"; exit 1; }
export REPLICAS HISTORY SCENARIO

# Numbers taken on battery or across a sleep are worthless.
pmset -g batt | grep -q "AC Power" || { echo "not on AC power - plug in the charger first"; exit 1; }

# The largest step must fit next to Kafgres: DB + max replicas x 1 CPU + k6 (250m) + cluster system pods.
MAX_R=$(tr , '\n' <<< "$REPLICAS" | sort -n | tail -1)
ALLOC=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}')
SYS=$(kubectl get pods -A --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.namespace} {.spec.containers[*].resources.requests.cpu}{"\n"}{end}' \
      | awk '$1!="bench" {for (i=2;i<=NF;i++) s+=($i~/m$/ ? $i/1000 : $i)} END {print s+0}')
awk -v a="$ALLOC" -v d="$DB_CPU" -v r="$MAX_R" -v e="${ENGINE_CPU:-1}" -v s="$SYS" 'BEGIN {a=(a~/m$/ ? a/1000 : a); e=(e~/m$/ ? e/1000 : e); r*=e; n=d+r+0.25+s
  printf "CPU budget: Kafgres %s + %s engine pods + k6 0.25 + system %s = %s of %s\n", d, r, s, n, a; exit !(n<=a)}' \
  || { echo "does not fit - lower --db-cpu or the largest replica step, or give Docker more CPUs"; exit 1; }
kubectl -n bench set resources deploy/kafgres --requests=cpu=$DB_CPU --limits=cpu=$DB_CPU >/dev/null

# Flowable stays at "activity" (process/activity instances + last variable values): its REST API reads the variables
# of an ended instance from history, so with "none" the reply has no counter (user decision 2026-11-16).
# Read by every engine deployment via envFrom (Camunda 8: k8s/camunda8/start.sh reads $HISTORY). Empty = app defaults (full).
NONE_VARS=(--from-literal=CAMUNDA_BPM_HISTORY_LEVEL=none --from-literal=OPERATON_BPM_HISTORY_LEVEL=none
  --from-literal=FLOWABLE_HISTORY_LEVEL=activity --from-literal=KOGITO_EVENTS_PROCESSINSTANCES_ENABLED=false
  --from-literal=KOGITO_EVENTS_PROCESSDEFINITIONS_ENABLED=false --from-literal=KOGITO_EVENTS_USERTASKS_ENABLED=false)
[ "$HISTORY" = full ] && NONE_VARS=()
# ${a[@]+…}: bash 3.2 (macOS) treats an empty array as unbound under set -u
kubectl -n bench create configmap history ${NONE_VARS[@]+"${NONE_VARS[@]}"} --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "history: $HISTORY"

# Scenario B smoke input: age 65, amount 30000, FR, business hits several rules, fee 1254 (load/gen-pricing-dmn.py).
smoke_b() {  # $1 engine; sets path, body, expect
  case $1 in
    kogito-*) path=/ScenarioB; body='{"age":65,"amount":30000,"country":"FR","customerType":"business"}' ;;
    camunda8) path=/v2/process-instances
              body='{"processDefinitionId":"ScenarioB","variables":{"age":65,"amount":30000,"country":"FR","customerType":"business"},"awaitCompletion":true}' ;;
    flowable) path=/process-api/runtime/process-instances
              body='{"processDefinitionKey":"ScenarioB","returnVariables":true,"variables":[{"name":"age","type":"integer","value":65},{"name":"amount","type":"integer","value":30000},{"name":"country","type":"string","value":"FR"},{"name":"customerType","type":"string","value":"business"}]}' ;;
    *)        path=/engine-rest/process-definition/key/ScenarioB/start
              body='{"variables":{"age":{"value":65,"type":"Integer"},"amount":{"value":30000,"type":"Integer"},"country":{"value":"FR","type":"String"},"customerType":{"value":"business","type":"String"}},"withVariablesInReturn":true}' ;;
  esac
  expect='"fee"[^}]{0,60}:1254(\.0+)?[,}]'   # "fee":1254 or "name":"fee",…,"value":1254.0
}

smoke() {  # $1 engine
  local path body expect r
  case $1 in
    kogito-*) path=/ScenarioA; body='{"counter":0}'; expect='"counter":3' ;;
    camunda8) path=/v2/process-instances; expect='"counter":3'
              body='{"processDefinitionId":"ScenarioA","variables":{"counter":0},"awaitCompletion":true}' ;;
    flowable) path=/process-api/runtime/process-instances; expect='"value":3'
              body='{"processDefinitionKey":"ScenarioA","variables":[{"name":"counter","type":"integer","value":0}],"returnVariables":true}' ;;
    *)        path=/engine-rest/process-definition/key/ScenarioA/start; body=$C7_BODY; expect='"value":3' ;;
  esac
  [ "$SCENARIO" = b ] && smoke_b "$1"
  # Fresh database: CIB seven and Operaton share the ACT_* table names, so a leftover ScenarioA of the other engine would be started.
  kubectl -n bench rollout restart deploy/kafgres >/dev/null && kubectl -n bench rollout status deploy/kafgres --timeout=180s >/dev/null || return 1
  local start="kubectl kustomize k8s/$1 | sed 's|image: bench-$1:1.0.0\$|image: bench-$1:${ENGINE_TAG:-1.0.0}|' | kubectl apply -f - >/dev/null && kubectl -n bench rollout status deploy/$1 --timeout=300s >/dev/null"
  [ -x "k8s/$1/start.sh" ] && start="k8s/$1/start.sh 1"   # own start script (Camunda 8: StatefulSet + process deployment)
  if ! eval "$start"; then
    echo "$(date +%T) smoke $1: not ready after 300 s, last errors:"
    kubectl -n bench logs -l app="$1" --all-containers --tail=300 2>&1 | grep -E "ERROR|Caused by|Description:|required a bean" | tail -5 | cut -c1-300
    kubectl delete -k "k8s/$1" --wait >/dev/null   # a pod that never got ready must not keep its CPU for the next engine
    return 1
  fi
  # Traefik picks up a new ingress/endpoint a moment after the pod is ready ("404 page not found" / "no available server" until then).
  for _ in $(seq 30); do
    r=$(curl -s -H "Host: $1.bench.local" -H 'Content-Type: application/json' -d "$body" "$LB$path")
    [ "$r" != "no available server" ] && [ "$r" != "404 page not found" ] && break
    sleep 1
  done
  kubectl delete -k "k8s/$1" --wait >/dev/null
  echo "$(date +%T) smoke $1: ${r:0:200}"
  echo "$r" | grep -E "$expect" >/dev/null
}

for E in "$@"; do
  if ! smoke "$E"; then echo "SMOKE FAILED: $E"; continue; fi
  [ -n "${SMOKE_ONLY:-}" ] && continue   # SMOKE_ONLY=1: only check that every engine answers correctly
  caffeinate -i ./bench.sh "$E" 2>&1
done
