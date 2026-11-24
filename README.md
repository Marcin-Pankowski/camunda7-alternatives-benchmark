# Camunda 7 Alternatives Benchmark

Speed comparison of **CIB seven, Operaton, Flowable, Kogito (5 variants) and Camunda 8** on Kubernetes, with a load
balancer in front: startup time, memory, throughput and scaling of the options that remain after the end of
Camunda 7 CE. The results are the basis for the video "Wie schnell sind BPMN-Engines?" ("How fast are BPMN
engines?") on the YouTube channel @BPMNtAInment.

Everything runs **locally on a MacBook (M1 Max)**. Load generator and engines share one machine, so the numbers are
**relative** (engine A versus engine B), not absolute production values.
Every engine runs with its **default settings**. Where we deviate, it is listed under [Disclosure](#disclosure).

The test protocols in [versuche/](versuche) are written in German.

## Setup

| Part | What |
|---|---|
| Kubernetes | k3d 5.9 (k3s 1.35) in Docker Desktop (8 CPU / 32 GB), one node |
| Load balancer | Traefik (part of k3s), one ingress per engine (`<engine>.bench.local`) |
| Database + Kafka | [Kafgres](https://github.com/RayElg/kafgres) 0.3.1 (Postgres 16 speaking the Kafka protocol), empty at every start, CPU via `--db-cpu` (default 4) / 2 GB |
| Load | k6 1.8.3 as a pod in the cluster (request 0.25 CPU, limit 2 CPU) |
| Engine pods | every engine **1 CPU / 2 GB per replica** (requests = limits) |

## Engines

All engines run the same process (scenario A, see below). The two Quarkus variants of CIB seven and Operaton were
added on 2026-11-23. `cibseven-quarkus` was measured on 2026-11-23 from 23:00 (A, B, A without history) in an
environment **10–15 % below the main runs**: the control run of Spring Boot `operaton` right before it reached 665/s
in A and 383/s in B (main runs 783/s and 423/s; Time Machine backup still running). Compare its numbers with the other
engines only with this in mind. `operaton-quarkus` was measured on 2026-11-24 from 11:10 in an environment close to
the main runs (control run Spring Boot `operaton`: A 732/s, B 448/s, i.e. 94 % and 106 %). Each app uses the Spring Boot or Quarkus version its
engine is built against. Package and Maven groupId: `de.piu.bpmn.benchmark`.

| ID | Engine | Packaging | Java | Persistence | The 3 tasks |
|---|---|---|---|---|---|
| `cibseven` | CIB seven 2.2.0 | own Spring Boot app (Boot 4.0.6), engine + REST, no webapps — [apps/cibseven](apps/cibseven) | 21 | Postgres (Kafgres), history `full` | JUEL expression `${counter + 1}` |
| `operaton` | Operaton 2.2.1 | own Spring Boot app (Boot 4.1.2), engine + REST, no webapps — [apps/operaton](apps/operaton) | 21 | Postgres (Kafgres), history `full` | JUEL expression |
| `cibseven-quarkus` | CIB seven 2.2.0 | own Quarkus app (Quarkus 3.27.0, JVM), engine + REST — [apps/cibseven-quarkus](apps/cibseven-quarkus) | 21 | Postgres (Kafgres), history `full` | JUEL expression |
| `operaton-quarkus` | Operaton 2.2.1 | own Quarkus app (Quarkus 3.40.1.1, JVM), engine + REST — [apps/operaton-quarkus](apps/operaton-quarkus) | 21 | Postgres (Kafgres), history `full` | JUEL expression |
| `flowable` | Flowable 8.0.0 | own Spring Boot app (Boot 4.0.2), engine + REST, no UI — [apps/flowable](apps/flowable) | 21 | Postgres (Kafgres), history `full` | JUEL expression |
| `kogito-jvm` | Kogito 10.2.0 | Quarkus 3.27.2, JVM — [apps/kogito](apps/kogito) | 21 | JDBC in Postgres (Kafgres) + process events to Kafka | Java script task |
| `kogito-jvm-kafka` | Kogito 10.2.0 | Quarkus 3.27.2, JVM — [apps/kogito-kafka](apps/kogito-kafka) | 21 | Kafka (topic `kogito.process` in Kafgres, 4 partitions) + process events to Kafka | Java script task |
| `kogito-sb` | Kogito 10.2.0 | Spring Boot 3.5.10 — [apps/kogito-sb](apps/kogito-sb) | 21 | JDBC in Postgres (Kafgres) + process events to Kafka | Java script task |
| `kogito-native` | Kogito 10.2.0 | Quarkus 3.27.2, GraalVM native image (Mandrel, JDK 21) — [apps/kogito](apps/kogito) | 21 (native) | JDBC in Postgres (Kafgres) + process events to Kafka | Java script task |
| `kogito-native-kafka` | Kogito 10.2.0 | Quarkus 3.27.2, GraalVM native image (Mandrel, JDK 21) — [apps/kogito-kafka](apps/kogito-kafka) | 21 (native) | Kafka (topic in Kafgres) + process events to Kafka | Java script task |
| `camunda8` | Camunda 8.10.9 | official image `camunda/camunda`, broker + gateway + REST — [k8s/camunda8](k8s/camunda8) | **25** | Zeebe log on the pod disk; history via RDBMS exporter in Postgres (Kafgres), `audit` level only (see [Disclosure](#disclosure)) | FEEL script task `=counter + 1` |

The JVM apps run on a plain `eclipse-temurin:21` JRE with JVM defaults
([apps/Dockerfile.springboot](apps/Dockerfile.springboot), `apps/kogito*/Dockerfile.jvm`), the native images on
`ubi9-quarkus-micro-image` ([apps/Dockerfile.native](apps/Dockerfile.native)).

## Scenario A

Start → task 1 → task 2 → task 3 → end. Every task increments `counter` by 1. The process is started via REST through
Traefik, and the response only comes back when the process has finished. A request counts only if `counter = 3`
comes back.

| Engine | Call |
|---|---|
| CIB seven, Operaton (Spring Boot and Quarkus) | `POST /engine-rest/process-definition/key/ScenarioA/start` with `withVariablesInReturn` |
| Flowable | `POST /process-api/runtime/process-instances` with `returnVariables` |
| Kogito (all) | `POST /ScenarioA` (generated by Kogito from the BPMN) |
| Camunda 8 | `POST /v2/process-instances` with `awaitCompletion` |

## Scenario B

Start → business rule task → end. The task evaluates a DMN decision table `Pricing` with **100 rules** and writes
the result into the variable `fee`. Inputs: `age`, `amount`, `country`, `customerType`, chosen at random for every
request.

- Hit policy **COLLECT with aggregation SUM**: every request is checked against all 100 rules, and the fees of all
  matching rules are added up.
- Rules 1–99 are random (fixed seed): ranges for age and amount, a country in 60 % of the rules, a customer type in
  50 %, fee = rule number. Rule 100 always matches (fee 1,000), so the sum is never empty. On average about 2 more
  rules match besides it.
- Generated by [load/gen-pricing-dmn.py](load/gen-pricing-dmn.py): one DMN file per engine and the same rules as
  `load/scenario-b-rules.json`. k6 uses it to compute the correct fee for every request. A request counts only if
  exactly this fee comes back.
- Calls as in scenario A, only with process `ScenarioB` and the four inputs.

Scenario B was called scenario C until 2026-11-19 (a planned scenario B was never built, see [Status](#status)).

## Getting started

Requirements: Docker Desktop (8 CPU, 32 GB), `kubectl`, Java 21 + Maven. `cluster.sh` downloads k3d into `bin/`.

```bash
./cluster.sh   # create the cluster, build/import the Kafgres image, start Kafgres
./smoke.sh     # smoke test: Postgres, Kafka protocol, load balancer across 2 pods, k6

# Build apps and images (example CIB seven; Operaton, Flowable, Kogito SB the same way)
(cd apps/cibseven && mvn -q package -DskipTests)
docker build -f apps/Dockerfile.springboot -t bench-cibseven:1.0.0 apps/cibseven
# Kogito Quarkus: native first (replaces target/), then JVM next to it
(cd apps/kogito && mvn -q clean package -DskipTests -Dquarkus.native.enabled=true -Dquarkus.native.container-build=true \
   && mvn -q package -DskipTests)
docker build -f apps/kogito/Dockerfile.jvm -t bench-kogito-jvm:1.0.0 apps/kogito
docker build -f apps/Dockerfile.native  -t bench-kogito-native:1.0.0 apps/kogito
# CIB seven / Operaton on Quarkus (JVM), same Dockerfile as Kogito JVM
(cd apps/operaton-quarkus && mvn -q package -DskipTests)
docker build -f apps/kogito/Dockerfile.jvm -t bench-operaton-quarkus:1.0.0 apps/operaton-quarkus
bin/k3d image import -c bench bench-cibseven:1.0.0 bench-kogito-jvm:1.0.0 bench-kogito-native:1.0.0   # etc.

SMOKE_ONLY=1 ./scenario-a.sh cibseven camunda8   # only check that the engines answer correctly
./scenario-a.sh cibseven operaton flowable kogito-jvm kogito-jvm-kafka kogito-sb kogito-native kogito-native-kafka camunda8
./scenario-a.sh --db-cpu 2 --replicas 1,2,4 cibseven   # other steps: CPUs for Kafgres, replica counts
./scenario-a.sh --history none cibseven   # without history, runtime state only (default: full)
RUN_TAG=iterfix ./scenario-a.sh kogito-jvm-kafka   # keep a re-measurement apart: results/history-full-iterfix/
./scenario-a.sh --scenario b cibseven   # scenario B (DMN table), results/scenario-b-history-full/
ENGINE_CPU=3500m ENGINE_MEM=8Gi RUN_TAG=c8max ./scenario-a.sh --replicas 1 camunda8   # special run: more resources per broker (Camunda 8 only)

bin/k3d cluster delete bench   # remove everything
```

The CIB seven app defaults to `feel-engine` 1.19.6 (see [Findings](#findings)). The main images were built with the
shipped version: `mvn package -Dfeel-engine.version=1.19.3`.

Ingress from outside: `curl -H 'Host: <engine>.bench.local' http://127.0.0.1:8081/`

## How `scenario-a.sh` works

```
./scenario-a.sh [--db-cpu 4] [--replicas 1,2,3] [--history full|none] [--scenario a|b] <engine …>
│   AC power only, aborts otherwise
│   checks first that Kafgres + largest step × 1 CPU + k6 + system fit into the cluster, aborts otherwise
│   sets the Kafgres CPUs (request = limit)
│   writes the ConfigMap `history` (for none: the engines' history switches, see Disclosure)
│
└─ for each engine, one after another:
   │
   ├─ 1. smoke call
   │     restart Kafgres (empty DB)
   │     → start the engine (1 pod; Camunda 8 via k8s/camunda8/start.sh)
   │        not ready after 300 s → show the error from the log, delete the pod, next engine
   │     → 1 process start through Traefik → does counter = 3 come back?
   │     → delete the engine
   │     (SMOKE_ONLY=1: stop here, next engine)
   │
   └─ 2. measurement (bench.sh, with caffeinate against sleep)
         for each replica step from --replicas (default 1, 2, 3):
         │  restart Kafgres (empty DB)
         │  start 1 pod ──────────────► startup time
         │  scale to N pods ──────────► scale-out time
         │    (Camunda 8: all N brokers at once, only one startup time)
         │  60 s idle ────────────────► idle RAM
         │
         └─ for 10, 25, 50, 100 VUs:
               k6 pod: 60 s warm-up + 60 s measurement ─► throughput, p50/p95/p99
               after 90 s ──────────────────────────────► RAM and CPU under load (engine pods + Kafgres)
         → everything into results/history-<full|none>/<engine>.jsonl
         → delete the engine (also on abort)
```

A request travels through the cluster like this:

```
 k6 (VUs) ──POST──► Traefik ──► engine pod 1 … N ──SQL / Kafka──► Kafgres
          ◄─counter = 3──        1 CPU / 2 GB each                 --db-cpu (4) / 2 GB
```

## Disclosure

These points belong to every publication of the numbers:

**Test environment**
- Everything on one MacBook (M1 Max), Docker Desktop with 8 CPU / 32 GB, one Kubernetes node. Numbers are relative.
- Load generator, load balancer, database and engines share the same 8 CPUs. Default: Kafgres 4 CPU, replicas 1/2/3
  with 1 CPU each, so at 3 replicas 7 CPUs are reserved. Traefik (no limit), k6 and k3s share the rest. Values of the
  largest step therefore show the limit of the machine rather than that of the engine.
  Every `results/history-<full|none>/<engine>.jsonl` starts with a `config` line (DB CPUs, engine CPU, history,
  replica steps; history is only recorded from the run without history on).
- A first run with Kafgres on 2 CPU showed the database as the limit for CIB seven and Operaton: Kafgres ran full
  (2 of 2 CPU), the engine pods were only half busy; no gain from 2 replicas on (about 730–950/s).
- Measured on AC power only, with `caffeinate` against sleep, without other Docker containers.
- Every series starts with an empty database. 60 s warm-up before 60 s measurement, because 15 s was not enough for
  freshly started JVMs (the first run at 10 VUs was clearly too low).

**Differences between the engines**
- **History: the goal is a complete trail (`full`); Camunda 8 cannot do that.** Measured per process instance:

  | What is recorded | CIB seven, Operaton (`full`) | Flowable (`full`) | Kogito (process events) | Camunda 8 (RDBMS exporter) |
  |---|---|---|---|---|
  | Process start/end | 1 row `act_hi_procinst` | 1 row | 2 status events | row in `PROCESS_INSTANCE` |
  | Nodes passed | 5 rows `act_hi_actinst` | 9 rows (incl. sequence flows) | 10 node events (enter/exit) | rows in `FLOW_NODE_INSTANCE` (not counted) |
  | **Every variable change on its own** | **4 rows `act_hi_detail`** | **4 rows `act_hi_detail`** | **4 variable events** (`counter` 0, 1, 2, 3) | **no** |
  | Storage path | SQL, synchronous in the same transaction | SQL, synchronous | Kafka (Kafgres), topic `kogito-processinstances-events`; Quarkus: the response waits for Kafka's acknowledgement (see deviations), Spring Boot: not verified | SQL, **asynchronous** via the exporter |

  The Kogito numbers were counted with `kogito-native-kafka`, the others with one smoke call each.

- **Second run without history (`--history none`):** only what the engine needs to execute is stored. The switches
  come as environment variables from the ConfigMap `history` (`envFrom`); the images stay the same:

  | Engine | Setting for `none` | Verified: what is in Kafgres after 5 instances |
  |---|---|---|
  | CIB seven, Operaton | `history-level: none` | 0 rows in `act_hi_*` |
  | Flowable | `history-level: activity` (**not** none) | 5 process, 45 activity, 5 variable rows (final state), 0 in `act_hi_detail` |
  | Kogito (all 5) | process events off (`kogito.events.processinstances/processdefinitions/usertasks.enabled=false`) | 0 process events; 1 process definition event at startup (the `processdefinitions.enabled` switch has no effect, not verified why) |
  | Camunda 8 | no secondary storage (`CAMUNDA_DATA_SECONDARYSTORAGE_TYPE=none`), profile `broker` only | 0 tables |

  - Flowable stays at `activity` because its REST API reads the variables of a finished instance from the history:
    with `none` the process completes, but the response contains no `counter`, so the `counter = 3` check would be
    impossible. `activity` is the lowest level that works.
  - Camunda 8 only starts without secondary storage when Operate/Tasklist/Identity are off (they need it and abort the
    startup). With `full` these webapps run in the same pod, with `none` they don't.
  - Kogito Quarkus keeps the blocking send (`errors.propagate`); without events it has nothing to do.
  - The Kafka persistence of the Kafka variants stays, it is the runtime state.

  **Camunda 8 in detail:**
  - The actual state lives in the Zeebe log (event sourcing, RocksDB snapshots) on the pod disk. Every variable change
    does become a record of its own there, but the log is compacted after export and snapshot and is not a queryable
    history.
  - The queryable history (Operate/REST search) is written to Postgres by the RDBMS exporter. The table `VARIABLE` has
    `VAR_KEY` as its primary key: a variable is inserted once and overwritten on every change (`INSERT`, then
    `UPDATE`). At the end only the last value is left (`counter = 3`). There is no table with every single change
    (like `act_hi_detail`); this matches the `audit` level of the C7 engines.
  - The exporter works asynchronously: the response to `awaitCompletion` does not wait until the history is in
    Postgres.
  - Only an additional Elasticsearch/OpenSearch exporter storing the raw Zeebe records could keep every change. This
    setup has none (no search engine in the cluster); not tested.
  - Consequence: Camunda 8 writes less history per instance than the other engines, which gives it an advantage in
    throughput.
- **Runtime persistence is not the audit trail:** Kogito's JDBC or Kafka persistence (`kogito.process`) only stores
  the state of running instances and removes it at the end, like the `ACT_RU_*` tables of the C7 engines.
- **Work per instance:** Kogito sends its audit trail as Kafka messages, the C7 engines and Flowable as SQL into
  Postgres. Similar content, but differently expensive work; the comparison shows engine plus storage path, not the
  engine alone.
- **Task type:** CIB seven, Operaton and Flowable use JUEL expressions, Kogito Java script tasks, Camunda 8 FEEL
  script tasks. All are executed by the engine itself, without external workers.
- **Java:** all engines Java 21, **Camunda 8 Java 25** (official image, unchanged, incl. compact object headers).
  CIB seven 2.2 officially supports Java 21 at most.
  Camunda 8 runs natively on arm64, not emulated (verified 2026-11-19): the tag `camunda/camunda:8.10.9` is a
  multi-arch image (amd64 + arm64), the arm64 variant is the one present locally. In the cluster (node `arm64`) a pod
  with this image reports `uname -m` = `aarch64` and `OpenJDK 64-Bit Server VM, 25.0.5+-minimos-r0`; the `java`
  binary is an AArch64 ELF.
- **Packaging:** CIB seven, Operaton and Flowable as own slim Spring Boot apps (engine + REST, no webapps), Camunda 8
  as the official all-in-one image (incl. Operate/Tasklist backend).
- **Scaling:** the other engines scale through stateless copies behind Traefik. Camunda 8 scales through brokers and
  partitions (N brokers = N partitions, replication factor 1), all brokers start at the same time.
- **Kafka persistence:** only Kogito on Quarkus (the addon does not exist for Spring Boot). Kafgres speaks the Kafka
  protocol but is not Apache Kafka.
- **CIB seven and Operaton write their history twice:** at the end of the process the engine (default strategy `end`
  of the history cleanup) sets the removal time in 15 history tables with `UPDATE … set REMOVAL_TIME_`. Each of the
  11 history rows per instance is therefore inserted and changed again right away. Flowable and Kogito don't have
  this step. Measured with `pg_stat_user_tables` (INSERTs = UPDATEs per table); default behaviour, not changed.

**Deviations from the default settings**
- All engines: the database points to Kafgres instead of the built-in default DB.
- REST APIs without authentication. For Camunda 8 explicitly switched off
  (`CAMUNDA_SECURITY_AUTHENTICATION_UNPROTECTEDAPI=true`, authorizations off).
- History level `full` for CIB seven, Operaton and Flowable, set explicitly. For CIB seven and Operaton this is also
  the default of the Spring Boot starter (the engine itself would use `audit`), for Flowable it is a deviation
  (default `audit`). Reason: Kogito also records every variable change with its process events.
- Kogito: JDBC or Kafka persistence switched on (default would be in-memory only), plus the addon for process events
  to Kafka (`kie-addons-quarkus-events-process` or `kie-addons-springboot-events-process-kafka`). An init container
  creates the topics in Kafgres.
- Kogito Quarkus (JDBC): tables via Quarkus' own Flyway instead of `kie.flyway` (its classpath scan does not work in a
  native image), the same for JVM and native. Flyway pinned to 11.11.2 (the version Quarkus 3.27.2 is built
  against), otherwise the native build fails.
- Kogito Spring Boot: Spring Boot's own Flyway auto-configuration off, Kogito creates the tables itself.
- Kogito Quarkus: Kafka producer with `acks=all` and `enable.idempotence=true` (default of the Kafka client and of
  Kogito Spring Boot) instead of the SmallRye default `acks=1` without idempotence. With `acks=1` Kafgres never
  answered some write requests under load (`REQUEST_TIMED_OUT`, with Kafgres almost idle); the producer retried
  endlessly. This alone did not fix the failures, see next point.
- Kogito Quarkus: `kogito.events.processinstances.errors.propagate=true`, i.e. the process events are sent blocking
  and the REST response waits until Kafka has acknowledged them. The default is fire-and-forget: under sustained load
  Kafgres accepted the events more slowly than Kogito produced them, the waiting messages piled up without limit in
  the heap (heap histogram: 39,000 → 291,000 messages in 40 s, heap 494 of 494 MB), followed by nothing but full GCs,
  hangs of up to 60 s and errors. No pod restarts, no OOMKilled. With the setting the memory stayed stable, at the
  cost of the wait for Kafgres on every request. This matches the C7 engines and Flowable, which write their history
  synchronously before responding. Kogito SB ran stable without this setting (how it sends is not verified).
- CIB seven / Operaton on Quarkus: the Quarkus extensions bring neither the REST API nor auto-deployment. Our apps add
  the vendors' plain JAX-RS resources (`*-engine-rest-core`) on RESTEasy Classic under `/engine-rest`
  ([RestApplication](apps/operaton-quarkus/src/main/java/de/piu/bpmn/benchmark/RestApplication.java)) and deploy the
  models at startup with duplicate filtering
  ([ProcessDeployer](apps/operaton-quarkus/src/main/java/de/piu/bpmn/benchmark/ProcessDeployer.java)), as the Spring
  Boot starter does. Engine settings are the extension defaults, which match the Spring Boot starter (history `full`,
  schema update on, UUID ids). JVM mode only: neither vendor documents native image support.

**Scenario B (DMN table)**
- One table, three dialects. CIB seven, Operaton, Kogito and Camunda 8 get FEEL with ranges like `[18..40]`. Flowable
  does not know these ranges, so its table has 6 instead of 4 columns (`>= 18` and `<= 40` separately). The matches
  are the same.
- CIB seven and Operaton also require a history time to live for the decision (`camunda:historyTimeToLive="P1D"`),
  otherwise they reject the deployment (`ENGINE-12018`). With full history they write every decision with its inputs
  and outputs into the history.
- Kogito: `fee` is an Integer variable. With `BigDecimal` or `Object` the code generation of the persistence fails.
- Kogito JVM Kafka and Native Kafka run with the iterator fix (see "Kogito Kafka with iterator fix").
- All images were rebuilt for scenario B. They now contain both scenarios, the Kogito and Flowable images also their
  DMN engine. The images measured for scenario A are kept locally as `:1.0.0-a`. A new run of scenario A with
  `:1.0.0` therefore does not measure exactly the same images (Kogito JVM: 15–20 MiB more idle RAM).
- After renaming scenario C to B (2026-11-19) all images were rebuilt again; they differ from the measured ones in
  the process ID (`ScenarioB` instead of `ScenarioC`) and, for the two Kafka variants, in a startup workaround
  (`KafkaStreamsListenerWarmup`, see Findings). The measured images are kept locally as `:1.0.0-scenc`.

## Results scenario A (full history)

Test protocol with setup, background and findings: [versuche/2026-11-15-mit-history.md](versuche/2026-11-15-mit-history.md).

Run of 2026-11-15/16: Kafgres 4 CPU, every engine pod 1 CPU / 2 GB, replicas 1/2/3, per step 60 s measurement after
60 s warm-up. Kogito Quarkus (4 variants) re-measured on 2026-11-16 with blocking event sending (see Findings). Raw
data in `results/history-full/<engine>.jsonl`. ⚠ = step not usable (share of correct responses below 99 % or p95
above 2 s). Local cluster, the values are only comparable with each other.

**1 replica** – throughput/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 806 · 54 | 816 · 73 | 699 · 133 | 650 · 297 |
| Operaton | 782 · 58 | 764 · 77 | 665 · 158 | 582 · 332 |
| Flowable | 631 · 58 | 595 · 90 | 418 · 280 | 384 · 613 |
| Kogito SB | 743 · 76 | 750 · 86 | 712 · 140 | 651 · 300 |
| Kogito JVM | 77 · 145 | 326 · 121 | 352 · 201 | 338 · 407 |
| Kogito JVM Kafka | 66 · 182 | 253 · 132 | 483 · 128 | 23 · 5,925 ⚠ |
| Kogito Native | 79 · 136 | 253 · 126 | 256 · 234 | 253 · 460 |
| Kogito Native Kafka | 64 · 176 | 206 · 191 | 349 · 182 | 1,374 · 224 ⚠ 10 % ok |
| Camunda 8 | 244 · 86 | 275 · 118 | 291 · 199 | 2,153 · 96 ⚠ 3 % ok |

**2 replicas** – throughput/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 1,532 · 14 | 1,641 · 37 | 1,567 · 63 | 1,361 · 190 |
| Operaton | 1,441 · 19 | 1,419 · 49 | 1,464 · 77 | 1,225 · 255 |
| Flowable | 1,301 · 35 | 1,100 · 76 | 966 · 177 | 817 · 461 |
| Kogito SB | 1,152 · 41 | 1,108 · 74 | 1,053 · 154 | 1,028 · 290 |
| Kogito JVM | 78 · 144 | 197 · 142 | 382 · 205 | 423 · 586 |
| Kogito JVM Kafka | 70 · 161 | 169 · 168 | 403 · 156 | 577 · 218 |
| Kogito Native | 71 · 163 | 185 · 150 | 357 · 225 | 555 · 309 |
| Kogito Native Kafka | 74 · 146 | 170 · 171 | 415 · 156 | 617 · 237 |
| Camunda 8 | 410 · 74 | 509 · 94 | 505 · 198 | 516 · 267 |

**3 replicas** – throughput/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 1,630 · 9 | 1,628 · 25 | 1,518 · 55 | 1,434 · 168 |
| Operaton | 1,608 · 9 | 1,630 · 26 | 1,494 · 54 | 1,458 · 165 |
| Flowable | 1,904 · 12 | 1,810 · 49 | 1,554 · 120 | 1,415 · 305 |
| Kogito SB | 1,284 · 39 | 1,886 · 57 | 2,210 · 73 | 1,348 · 425 |
| Kogito JVM | 68 · 188 | 185 · 168 | 414 · 136 | 634 · 338 |
| Kogito JVM Kafka | 64 · 181 | 139 · 221 | 254 · 245 | 428 · 301 |
| Kogito Native | 77 · 148 | 208 · 131 | 374 · 169 | 522 · 406 |
| Kogito Native Kafka | 70 · 160 | 160 · 178 | 298 · 200 | 546 · 235 |
| Camunda 8 | 551 · 52 | 687 · 81 | 751 · 148 | 768 · 252 |

**Startup, scale-out, RAM** (per pod)

| Engine | Start 1st pod | Scale-out +1 pod | Idle RAM | RAM under load (max) |
|---|---:|---:|---:|---:|
| CIB seven | 9.9–10.1 s | 9.0 s | 248–256 MiB | 439 MiB |
| Operaton | 9.7–10.7 s | 8.9–10.0 s | 247–268 MiB | 443 MiB |
| Flowable | 8.7–8.8 s | 7.8–7.9 s | 189–211 MiB | 339 MiB |
| Kogito SB | 11.1–12.2 s | 10.1–11.0 s | 225–231 MiB | 595 MiB |
| Kogito JVM | 5.1–6.0 s | 5.0–6.2 s | 146–156 MiB | 308 MiB |
| Kogito JVM Kafka | 4.1–5.2 s | 3.9–4.1 s | 151–158 MiB | 1,499 MiB |
| Kogito Native | 2.0–3.0 s | 1.9–3.0 s | 19–22 MiB | 132 MiB |
| Kogito Native Kafka | 2.0–3.0 s | 2.0 s | 27–31 MiB | 1,172 MiB |
| Camunda 8 | 21.9–33.6 s | – (all brokers at once) | 484–496 MiB | 1,970 MiB |

Start = until the first pod is ready, scale-out = until one more pod is ready (measured per replica step).
Camunda 8 starts all brokers at once; the startup values apply to 1/2/3 brokers. RAM from `kubectl top`.

## Results scenario A without history

Test protocol with setup, verification and findings: [versuche/2026-11-16-ohne-history.md](versuche/2026-11-16-ohne-history.md).

Run of 2026-11-16 with `--history none`, otherwise as above (Kafgres 4 CPU, replicas 1/2/3, 60 s warm-up + 60 s
measurement). Only the runtime state is stored, settings see Disclosure. Raw data in
`results/history-none/<engine>.jsonl`. ⚠ as above.

¹ Flowable with `history-level: activity`, not none (see Disclosure).
² Camunda 8 without secondary storage and without webapps (profile `broker`); with history, Operate/Tasklist ran in the pod too.

**1 replica** – throughput/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 1,661 · 37 | 1,686 · 54 | 1,647 · 88 | 1,663 · 111 |
| Operaton | 1,369 · 70 | 1,481 · 80 | 1,364 · 93 | 1,299 · 184 |
| Flowable ¹ | 674 · 49 | 599 · 89 | 532 · 202 | 495 · 499 |
| Kogito SB | 925 · 70 | 908 · 84 | 891 · 103 | 758 · 287 |
| Kogito JVM | 1,620 · 60 | 1,781 · 72 | 1,863 · 81 | 1,804 · 96 |
| Kogito JVM Kafka | 470 · 28 | 582 · 3 ⚠ 3 % ok | 23 · 3,593 ⚠ | 47 · 3,504 ⚠ |
| Kogito Native | 977 · 69 | 1,372 · 80 | 1,351 · 90 | 1,263 · 112 |
| Kogito Native Kafka | 505 · 23 | 30 · 1,200 | 37 · 2,403 ⚠ | 49 · 3,304 ⚠ |
| Camunda 8 ² | 290 · 74 | 282 · 127 | 326 · 182 | 2,693 · 87 ⚠ 3 % ok |

**2 replicas** – throughput/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 2,607 · 16 | 2,754 · 41 | 3,137 · 52 | 3,438 · 74 |
| Operaton | 2,319 · 21 | 2,519 · 44 | 2,630 · 65 | 2,656 · 94 |
| Flowable ¹ | 1,163 · 38 | 1,170 · 65 | 1,180 · 124 | 1,101 · 309 |
| Kogito SB | 1,773 · 36 | 1,846 · 64 | 1,768 · 85 | 1,670 · 198 |
| Kogito JVM | 2,707 · 6 | 2,654 · 45 | 3,112 · 51 | 3,036 · 81 |
| Kogito JVM Kafka | 491 · 27 | 1,080 · 33 | 31 · 4,193 ⚠ | 33 · 8,577 ⚠ |
| Kogito Native | 2,409 · 10 | 2,747 · 49 | 3,035 · 65 | 3,090 · 86 |
| Kogito Native Kafka | 511 · 24 | 1,171 · 28 | 47 · 2,630 ⚠ | 52 · 2,905 ⚠ |
| Camunda 8 ² | 490 · 54 | 572 · 84 | 643 · 163 | 667 · 222 |

**3 replicas** – throughput/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 3,248 · 8 | 3,934 · 22 | 4,620 · 34 | 4,601 · 63 |
| Operaton | 2,989 · 8 | 3,319 · 25 | 3,668 · 48 | 3,522 · 75 |
| Flowable ¹ | 1,894 · 11 | 1,845 · 37 | 1,804 · 82 | 1,592 · 271 |
| Kogito SB | 2,653 · 8 | 2,596 · 37 | 2,732 · 65 | 2,326 · 161 |
| Kogito JVM | 3,332 · 5 | 3,768 · 18 | 3,741 · 44 | 4,612 · 55 |
| Kogito JVM Kafka | 410 · 34 | 806 · 48 | 1,218 · 73 | 32 · 7,847 ⚠ |
| Kogito Native | 3,827 · 6 | 4,552 · 19 | 4,531 · 41 | 4,737 · 63 |
| Kogito Native Kafka | 468 · 29 | 975 · 37 | 668 · 52 ⚠ 96 % ok | 42 · 5,263 ⚠ |
| Camunda 8 ² | 777 · 32 | 876 · 71 | 733 · 178 | 815 · 316 ⚠ 48 % ok |

**Startup, scale-out, RAM** (per pod)

| Engine | Start 1st pod | Scale-out +1 pod | Idle RAM | RAM under load (max) |
|---|---:|---:|---:|---:|
| CIB seven | 10.0–12.4 s | 10.0–12.1 s | 251–263 MiB | 427 MiB |
| Operaton | 11.3–11.9 s | 9.8–10.0 s | 249–263 MiB | 425 MiB |
| Flowable ¹ | 8.8–8.9 s | 8.0–8.9 s | 188–205 MiB | 337 MiB |
| Kogito SB | 11.2–12.2 s | 11.0 s | 213–219 MiB | 342 MiB |
| Kogito JVM | 4.1–5.1 s | 4.0–5.0 s | 147–154 MiB | 268 MiB |
| Kogito JVM Kafka | 4.1–6.1 s | 5.0–7.2 s | 147–151 MiB | 1,702 MiB |
| Kogito Native | 2.0 s | 1.9–3.0 s | 18–21 MiB | 197 MiB |
| Kogito Native Kafka | 2.0–3.0 s | 2.0 s | 26–29 MiB | 1,941 MiB |
| Camunda 8 ² | 14.8–16.0 s | – (all brokers at once) | 413–423 MiB | 2,011 MiB |

**With versus without history** – best valid throughput/s per replica step (across all VU steps)

| Engine | 1 replica | 2 replicas | 3 replicas |
|---|---:|---:|---:|
| CIB seven | 816 → **1,686** (×2.1) | 1,641 → **3,438** (×2.1) | 1,630 → **4,620** (×2.8) |
| Operaton | 782 → **1,481** (×1.9) | 1,464 → **2,656** (×1.8) | 1,630 → **3,668** (×2.3) |
| Flowable ¹ | 631 → **674** (×1.1) | 1,301 → **1,180** (×0.9) | 1,904 → **1,894** (×1.0) |
| Kogito SB | 750 → **925** (×1.2) | 1,152 → **1,846** (×1.6) | 2,210 → **2,732** (×1.2) |
| Kogito JVM | 352 → **1,863** (×5.3) | 423 → **3,112** (×7.4) | 634 → **4,612** (×7.3) |
| Kogito JVM Kafka | 483 → **470** (×1.0) | 577 → **1,080** (×1.9) | 428 → **1,218** (×2.8) |
| Kogito Native | 256 → **1,372** (×5.4) | 555 → **3,090** (×5.6) | 522 → **4,737** (×9.1) |
| Kogito Native Kafka | 349 → **505** (×1.4) | 617 → **1,171** (×1.9) | 546 → **975** (×1.8) |
| Camunda 8 ² | 291 → **326** (×1.1) | 516 → **667** (×1.3) | 768 → **876** (×1.1) |

The comparison takes the highest throughput of all VU steps without ⚠ per replica step; the two values may come from
different VU steps. Kogito Native Kafka at 1 replica × 25 VUs (30/s, p95 1.2 s) is formally valid, but already the
collapse.

## Kogito Kafka with iterator fix

Test protocol: [versuche/2026-11-16-iterator-fix.md](versuche/2026-11-16-iterator-fix.md).

Both Kafka variants with a corrected `KafkaProcessInstances` (RocksDB iterators closed, see Findings) fully
re-measured on 2026-11-16/17, with and without history, otherwise as the main runs. "As shipped" are the values from
the tables above (Kogito 10.2.0 unchanged). Raw data in `results/history-full-iterfix/` and
`results/history-none-iterfix/`. ⚠ as above.
Images: `bench-kogito-{jvm,native}-kafka:1.0.0` contain the fix since then (from `apps/kogito-kafka`), the shipped
version is kept locally as `:1.0.0-original`.

#### With history

**1 replica** – throughput/s · p95 ms

| Variant | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, as shipped | 66 · 182 | 253 · 132 | 483 · 128 | 23 · 5,925 ⚠ |
| Kogito JVM Kafka, with fix | 70 · 159 | 257 · 131 | 468 · 149 | 516 · 240 |
| Kogito Native Kafka, as shipped | 64 · 176 | 206 · 191 | 349 · 182 | 1,374 · 224 ⚠ 10 % ok |
| Kogito Native Kafka, with fix | 65 · 174 | 277 · 113 | 479 · 133 | 507 · 228 |

**2 replicas** – throughput/s · p95 ms

| Variant | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, as shipped | 70 · 161 | 169 · 168 | 403 · 156 | 577 · 218 |
| Kogito JVM Kafka, with fix | 71 · 167 | 180 · 153 | 429 · 143 | 642 · 200 |
| Kogito Native Kafka, as shipped | 74 · 146 | 170 · 171 | 415 · 156 | 617 · 237 |
| Kogito Native Kafka, with fix | 72 · 153 | 177 · 155 | 416 · 144 | 386 · 431 |

**3 replicas** – throughput/s · p95 ms

| Variant | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, as shipped | 64 · 181 | 139 · 221 | 254 · 245 | 428 · 301 |
| Kogito JVM Kafka, with fix | 70 · 156 | 167 · 166 | 316 · 176 | 585 · 208 |
| Kogito Native Kafka, as shipped | 70 · 160 | 160 · 178 | 298 · 200 | 546 · 235 |
| Kogito Native Kafka, with fix | 69 · 161 | 157 · 180 | 289 · 195 | 518 · 258 |

**RAM under load (max per pod)**

| Variant | 1 replica | 2 replicas | 3 replicas |
|---|---:|---:|---:|
| Kogito JVM Kafka, as shipped | 1,499 MiB | 1,229 MiB | 706 MiB |
| Kogito JVM Kafka, with fix | 325 MiB | 280 MiB | 267 MiB |
| Kogito Native Kafka, as shipped | 937 MiB | 1,172 MiB | 677 MiB |
| Kogito Native Kafka, with fix | 290 MiB | 144 MiB | 70 MiB |

#### Without history

**1 replica** – throughput/s · p95 ms

| Variant | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, as shipped | 470 · 28 | 582 · 3 ⚠ 3 % ok | 23 · 3,593 ⚠ | 47 · 3,504 ⚠ |
| Kogito JVM Kafka, with fix | 547 · 21 | 1,408 · 20 | 2,370 · 40 | 2,260 · 84 |
| Kogito Native Kafka, as shipped | 505 · 23 | 30 · 1,200 | 37 · 2,403 ⚠ | 49 · 3,304 ⚠ |
| Kogito Native Kafka, with fix | 528 · 23 | 1,376 · 23 | 1,628 · 68 | 1,609 · 98 |

**2 replicas** – throughput/s · p95 ms

| Variant | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, as shipped | 491 · 27 | 1,080 · 33 | 31 · 4,193 ⚠ | 33 · 8,577 ⚠ |
| Kogito JVM Kafka, with fix | 519 · 25 | 1,176 · 30 | 1,628 · 45 | 3,934 · 49 |
| Kogito Native Kafka, as shipped | 511 · 24 | 1,171 · 28 | 47 · 2,630 ⚠ | 52 · 2,905 ⚠ |
| Kogito Native Kafka, with fix | 518 · 25 | 1,215 · 29 | 2,040 · 38 | 2,947 · 58 |

**3 replicas** – throughput/s · p95 ms

| Variant | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, as shipped | 410 · 34 | 806 · 48 | 1,218 · 73 | 32 · 7,847 ⚠ |
| Kogito JVM Kafka, with fix | 450 · 31 | 910 · 39 | 1,427 · 53 | 2,556 · 60 |
| Kogito Native Kafka, as shipped | 468 · 29 | 975 · 37 | 668 · 52 ⚠ 96 % ok | 42 · 5,263 ⚠ |
| Kogito Native Kafka, with fix | 472 · 30 | 1,347 · 28 | 2,447 · 32 | 2,583 · 68 |

**RAM under load (max per pod)**

| Variant | 1 replica | 2 replicas | 3 replicas |
|---|---:|---:|---:|
| Kogito JVM Kafka, as shipped | 766 MiB | 1,454 MiB | 1,702 MiB |
| Kogito JVM Kafka, with fix | 324 MiB | 326 MiB | 321 MiB |
| Kogito Native Kafka, as shipped | 572 MiB | 1,350 MiB | 1,941 MiB |
| Kogito Native Kafka, with fix | 330 MiB | 311 MiB | 162 MiB |

With the fix no step is below 99 % correct, no p95 above 0.5 s, memory at most 330 MiB per pod (as shipped up to
1,941 MiB); 14 of 48 steps were not usable as shipped. With history, waiting for the event acknowledgement sets the
pace below 100 VUs, hence little difference. Without history, JVM Kafka with 1 pod becomes the fastest Kogito variant
(2,370/s versus 1,863/s with JDBC).

## Results scenario B (full history)

Test protocol: [versuche/2026-11-17-szenario-b-dmn.md](versuche/2026-11-17-szenario-b-dmn.md).

Run of 2026-11-17, setup as in scenario A: Kafgres 4 CPU, every engine pod 1 CPU / 2 GB, replicas 1/2/3, per step 60 s
measurement after 60 s warm-up. Raw data in `results/scenario-b-history-full/<engine>.jsonl`. ⚠ as above.
¹ with iterator fix; compared with their re-measurement, not with the shipped values.

**1 replica** – throughput/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 81 · 196 | 73 · 596 | 76 · 1,207 | 78 · 2,512 ⚠ |
| Operaton | 423 · 73 | 418 · 100 | 367 · 277 | 245 · 902 |
| Flowable | 345 · 80 | 290 · 178 | 227 · 487 | 233 · 1,002 |
| Kogito SB | 457 · 85 | 602 · 93 | 523 · 194 | 434 · 484 |
| Kogito JVM | 96 · 125 | 272 · 136 | 276 · 224 | 279 · 387 |
| Kogito Native | 93 · 120 | 220 · 173 | 246 · 251 | 248 · 452 |
| Kogito JVM Kafka ¹ | 80 · 144 | 328 · 96 | 581 · 102 | 562 · 217 |
| Kogito Native Kafka ¹ | 77 · 147 | 304 · 105 | 439 · 154 | 473 · 267 |
| Camunda 8 | 215 · 92 | 280 · 122 | 381 · 313 ⚠ | 1,787 · 103 ⚠ |

**2 replicas** – throughput/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 193 · 132 | 170 · 406 | 170 · 960 | 156 · 2,286 ⚠ |
| Operaton | 688 · 36 | 740 · 69 | 708 · 180 | 562 · 581 |
| Flowable | 746 · 60 | 636 · 99 | 499 · 340 | 504 · 735 |
| Kogito SB | 1,162 · 53 | 1,180 · 70 | 1,130 · 121 | 1,128 · 296 |
| Kogito JVM | 103 · 106 | 250 · 110 | 478 · 176 | 535 · 330 |
| Kogito Native | 100 · 109 | 237 · 116 | 443 · 174 | 472 · 396 |
| Kogito JVM Kafka ¹ | 89 · 123 | 219 · 127 | 537 · 112 | 492 · 330 |
| Kogito Native Kafka ¹ | 88 · 128 | 217 · 127 | 542 · 108 | 798 · 150 |
| Camunda 8 | 333 · 80 | 401 · 149 | 480 · 215 | 1,238 · 270 ⚠ |

**3 replicas** – throughput/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 263 · 103 | 245 · 380 | 246 · 866 | 255 · 1,724 |
| Operaton | 814 · 20 | 818 · 51 | 862 · 96 | 881 · 325 |
| Flowable | 1,144 · 29 | 1,006 · 84 | 803 · 271 | 704 · 667 |
| Kogito SB | 1,699 · 23 | 1,287 · 84 | 1,673 · 76 | 1,648 · 264 |
| Kogito JVM | 102 · 107 | 259 · 106 | 538 · 100 | 801 · 204 |
| Kogito Native | 103 · 106 | 260 · 104 | 527 · 104 | 761 · 218 |
| Kogito JVM Kafka ¹ | 85 · 132 | 192 · 154 | 369 · 156 | 594 · 213 |
| Kogito Native Kafka ¹ | 83 · 134 | 189 · 153 | 336 · 179 | 576 · 230 |
| Camunda 8 | 392 · 72 | 458 · 135 | 641 · 199 | 695 · 252 |

Camunda 8 at 3 replicas × 100 VUs: 99.8 % correct, just above the threshold.

**Best valid throughput per replica step, scenario A → B** (as above: highest value of all VU steps without ⚠)

| Engine | 1 replica | 2 replicas | 3 replicas |
|---|---:|---:|---:|
| CIB seven | 816 → **81** (×0.10) | 1,641 → **193** (×0.12) | 1,630 → **263** (×0.16) |
| Operaton | 782 → **423** (×0.54) | 1,464 → **740** (×0.51) | 1,630 → **881** (×0.54) |
| Flowable | 631 → **345** (×0.55) | 1,301 → **746** (×0.57) | 1,904 → **1,144** (×0.60) |
| Kogito SB | 750 → **602** (×0.80) | 1,152 → **1,180** (×1.02) | 2,210 → **1,699** (×0.77) |
| Kogito JVM | 352 → **279** (×0.79) | 423 → **535** (×1.26) | 634 → **801** (×1.26) |
| Kogito Native | 256 → **248** (×0.97) | 555 → **472** (×0.85) | 522 → **761** (×1.46) |
| Kogito JVM Kafka ¹ | 516 → **581** (×1.13) | 642 → **537** (×0.84) | 585 → **594** (×1.01) |
| Kogito Native Kafka ¹ | 507 → **473** (×0.93) | 416 → **798** (×1.92) | 518 → **576** (×1.11) |
| Camunda 8 | 291 → **280** (×0.96) | 516 → **480** (×0.93) | 768 → **695** (×0.91) |

**RAM per pod**, highest value under load, scenario A → B

| Engine | 1 replica | 2 replicas | 3 replicas | Idle, 1 replica |
|---|---:|---:|---:|---:|
| CIB seven | 439 → 506 MiB | 428 → 486 MiB | 393 → 467 MiB | 248 → 259 MiB |
| Operaton | 443 → 479 MiB | 432 → 456 MiB | 403 → 411 MiB | 268 → 265 MiB |
| Flowable | 339 → 366 MiB | 316 → 352 MiB | 328 → 358 MiB | 203 → 214 MiB |
| Kogito SB | 582 → 495 MiB | 595 → 619 MiB | 579 → 615 MiB | 230 → 251 MiB |
| Kogito JVM | 308 → 367 MiB | 293 → 328 MiB | 277 → 298 MiB | 153 → 169 MiB |
| Kogito Native | 132 → 131 MiB | 98 → 80 MiB | 76 → 75 MiB | 22 → 23 MiB |
| Kogito JVM Kafka ¹ | 325 → 379 MiB | 280 → 343 MiB | 267 → 301 MiB | 153 → 176 MiB |
| Kogito Native Kafka ¹ | 290 → 266 MiB | 144 → 131 MiB | 70 → 89 MiB | 30 → 33 MiB |
| Camunda 8 | 1,920 → 1,709 MiB | 1,846 → 1,785 MiB | 1,970 → 1,567 MiB | 484 → 499 MiB |

## Findings

What was found while building and measuring, including how we got there. "Not verified" means: assumption, not
measured.

**Database as the limit (CIB seven, Operaton)**
- Run with Kafgres on 2 CPU: from 2 replicas on, CIB seven and Operaton did not get beyond about 730–950/s.
  Diagnosis at 4 replicas × 50 VUs (`pg_stat_activity` twice per second, `kubectl top`, `pg_stat_user_tables`):
  Kafgres at 1,985–1,992m of 2,000m CPU, engine pods only at 330–500m of 1,000m. Wait events of the active
  connections: ≈ 62 % `LWLock: BufferContent` (contention on the same pages for INSERT/UPDATE on `ACT_HI_ACTINST` and
  `ACT_HI_DETAIL`), ≈ 20 % CPU, ≈ 12 % WAL at COMMIT, **0 real row locks**. No locking between the replicas, just too
  much write work for 2 cores.
- Cause of the write work: the removal time of the history cleanup (strategy `end`, default). At the end of the
  process `UPDATE … set REMOVAL_TIME_` in 15 history tables; each of the 11 history rows per instance is inserted and
  changed again right away (INSERTs = UPDATEs per table). Flowable writes more rows (15) but does not change them.
  Default kept; with `history-removal-time-strategy: start` the UPDATEs would disappear (not measured).
- With Kafgres on 4 CPU: CIB seven 806 → 1,532 → 1,630/s at 1/2/3 replicas (10 VUs), Operaton similar. Hardly any gain
  from 2 to 3 replicas; that the database is the limit again is not verified.
- Flowable scales almost linearly in the same run (631 → 1,301 → 1,904/s at 10 VUs) and leads at 3 replicas; at
  1 replica it is the slowest of the three. Kogito SB reaches the highest value of the run at 3 replicas × 50 VUs
  (2,210/s) and drops back to 1,348/s at 100 VUs (not verified why).

**Kogito Quarkus: failures under load**
- Symptoms: depending on the step 0 % correct responses, hangs of up to 60 s (timeout) or tens of thousands of fast
  errors per second; erratic, not growing with the load. All four Quarkus variants, not Kogito SB.
- First finding: the SmallRye producer ran with `acks=1` without idempotence (Kogito SB: `acks=all`, idempotent).
  Kafgres then never answered some write requests (`REQUEST_TIMED_OUT`, with Kafgres almost idle). Switched to
  `acks=all` + idempotence. **That was not enough:** the next full run showed the same failures (a short test with
  1 replica and two load steps had not revealed this).
- Actual cause (pod status, health, memory every 3 s, GC log, heap histogram with `jcmd`): no pod restarts, no
  OOMKilled, readiness always `UP`. But the heap (494 MB = 25 % of 2 GiB) filled up: 24 MB → 327 MB → 494 MB in about
  80 s, followed by one full GC after another (≈ 0.5 s each). Event messages waiting in the heap 38,856 → 291,143 in
  40 s, produced by Kogito's `ReactiveMessageEmitter`. The events all arrive in Kafgres (≈ 16 per instance), just more
  slowly than Kogito produces them; the fire-and-forget default buffers without limit.
- Remedy: `kogito.events.processinstances.errors.propagate=true` (blocking send). Test with 1 replica: Kogito JVM
  329/s, p95 96 ms, memory stable at ≈ 236 Mi; Kogito Native 272/s, stable at ≈ 70 Mi; 100 % correct each.
- Consequence in the full run: all four variants almost everywhere 100 % correct, but bound to the waiting time. At
  10 VUs all four only reach 64–79/s (p50 ≈ 130 ms per request), whether with 1, 2 or 3 replicas. Throughput grows
  with the VUs (up to ≈ 630/s), not with the replicas: the pods wait instead of computing. The values therefore mostly
  show how fast Kafgres acknowledges Kafka write requests, not the engine. Why an acknowledgement takes that long
  (e.g. a batching interval in Kafgres) is not verified; neither is whether the ≈ 16 events per instance are sent one
  after another.
- For comparison: in the very first run (different setup, fire-and-forget events) Kogito JVM reached about 1,800/s
  with 1 replica. That only worked because nobody waited for the events, and it did not hold under sustained load.
- **The two Kafka variants** keep growing even with blocking send: Kogito JVM Kafka up to 1,499 MiB per pod
  (1 replica, 50 VUs), then at 100 VUs a collapse to 23/s with p95 5.9 s; Kogito Native Kafka up to 1,172 MiB, at
  1 replica × 100 VUs only 10 % correct responses. With more replicas the load spreads and it suffices. A second
  memory hog, presumably the Kafka Streams persistence; not verified. The JDBC variants stay below 310 MiB (JVM) and
  132 MiB (native).

**Kogito Quarkus in the source code (Kogito 10.2.0, source JARs from Maven Central) and follow-up tests on 2026-11-16**
- Event sending (`AbstractMessagingEventPublisher`, `ReactiveMessagingEventPublisher`): the default is **one Kafka
  record per event, one after another**. With `errors.propagate=true`, `sendMessageAndAwait` waits for the
  acknowledgement of each of the ≈ 16 events of an instance before the next one goes out. On top, the Kafka client
  4.0 waits `linger.ms` = 5 ms before every send by default. 16 × (5 ms + acknowledgement) matches the fixed floor of
  ≈ 100–130 ms per request. Kogito knows `kogito.events.grouping=true` (`GroupingMessagingEventPublisher`): all events
  of a transaction as **one** record (`MultipleProcessInstanceDataEvent`, a different message format for consumers).
  The channel is explicitly declared with `@OnOverflow(UNBOUNDED_BUFFER)`, which explains the unbounded buffer with
  the fire-and-forget default.
  - Confirmed in Kafgres (`kafgres_producer_batches.appended_at`): the events of an instance arrive one by one about
    12 ms apart, 16 records per instance.
  - Follow-up test Kogito JVM, with history, 1 replica, `kogito.events.grouping=true` (as environment variable):
    1 record per instance, all responses correct, memory ≤ 258 MiB. Two runs:

    | VUs | without grouping (main run) | with grouping, run 1 | run 2 |
    |---:|---:|---:|---:|
    | 10 | 77/s · p50 ≈ 128 ms | 461/s · p50 17 ms | 511/s · p50 12 ms |
    | 25 | 326/s · p95 121 ms | 919/s · p95 56 ms | 680/s · p95 61 ms |
    | 50 | 352/s · p95 201 ms | 913/s · p95 88 ms | 652/s · p95 126 ms |

    The floor disappears, Kogito becomes 3 to 6 times as fast. The two runs scatter a lot at 25/50 VUs (not verified
    why; run 1 shortly before a Docker crash). **Not** adopted for the main runs because the message format changes.
- Kafka persistence (`KafkaProcessInstances`, `KafkaPersistenceUtils`):
  - The state lives in a **GlobalKTable** (`kogito-store`, RocksDB): every replica reads the whole topic
    `kogito.process` into its own store, with a single global thread. More replicas therefore don't share the work,
    each one does all of it.
  - Every write waits synchronously (`producer.send(...).get()`); two records per finished instance (tombstone +
    event list).
  - All instances of a process share **one** key `events-<process ID>` with the list of their wait states. It is read,
    changed and rewritten completely per instance: all on one partition, and concurrent requests overwrite each other.
  - **`clearEventTypes` and `waitingForEventType` open a RocksDB iterator via `prefixScan` and never close it.**
    `clearEventTypes` runs for every finished instance. Open RocksDB iterators hold native memory (outside the Java
    heap). **Proven as the cause of the collapse:** follow-up test Kogito JVM Kafka, with history, 1 replica, directly
    one after another with the original and with a corrected copy of the class
    (`apps/kogito-kafka/src/main/java/org/kie/kogito/persistence/kafka/KafkaProcessInstances.java`, iterators closed
    with try-with-resources; according to the class loading log the JVM loads the copy from the app JAR):

    | VUs | Original | RAM | with fix | RAM |
    |---:|---:|---:|---:|---:|
    | 10 | 68/s · p95 169 ms | 274 MiB | 66/s · p95 169 ms | 218 MiB |
    | 25 | 298/s · p95 106 ms | 873 MiB | 328/s · p95 94 ms | 239 MiB |
    | 50 | 489/s · p95 129 ms | 1,620 MiB | 581/s · p95 103 ms | 271 MiB |
    | 100 | **25/s · p95 5,603 ms ⚠**, 1 restart **OOMKilled** | 306 MiB | **571/s · p95 219 ms** | 322 MiB |

    The bug is also in the current `main` of `apache/incubator-kie` (kogito-runtimes moved there in 07/2026; file
    unchanged since 05/2025). Reported upstream on 2026-11-22: issue
    [incubator-kie-issues#2427](https://github.com/apache/incubator-kie-issues/issues/2427), fix in
    [apache/incubator-kie#7313](https://github.com/apache/incubator-kie/pull/7313). The main runs were measured with the original; full re-measurement with the fix in the section "Kogito
    Kafka with iterator fix" (works in the native image too: memory stays flat).
  - After deleting, `remove` waits in a loop with `Thread.sleep(100)` until the store shows the deletion.

**Without history**
- Without history, CIB seven and Operaton reach about twice the throughput and now also scale with the third replica
  (CIB seven 1,686 → 3,438 → 4,620/s). With history both were at about 1,600/s from 2 replicas on. So the history write
  work in Kafgres was the limit, not the engine. Without history CIB seven is consistently 15–25 % ahead of Operaton;
  with history both were level. Why is not verified.
- Kogito JVM and Native with JDBC become 5 to 9 times as fast (up to 4,612 and 4,737/s with 3 replicas) and scale
  cleanly. With history they were slowed down by waiting for Kafgres' Kafka acknowledgement (≈ 130 ms per request, see
  above), not by the engine.
- Kogito JVM Kafka and Native Kafka collapse even without events: at 1 replica already from 25 VUs, at 3 replicas from
  50–100 VUs (23–52/s, p95 2.4–8.6 s). Memory up to 1.7 and 1.9 GiB per pod, then it suddenly drops to ≈ 250 MiB
  (presumably a pod restart, not verified). So the problem lies in the Kafka persistence itself, not in the event
  sending. Cause since proven: the unclosed RocksDB iterator in Kogito (OOMKilled), see above; with the fix up to
  2,370/s with 1 pod.
- Kogito SB gains 20–60 %, Camunda 8 10–30 %, Flowable with `activity` nothing (it still writes 11 history rows per
  instance, only the 4 change details disappear).
- Camunda 8 has only 48 % correct responses at 3 brokers × 100 VUs (with history: 100 %). Cause not verified.

**Camunda 8**
- 1 broker at 100 VUs: 97 % of the responses are fast errors (2,153 responses/s, 3 % of them correct). Presumably
  Zeebe's built-in overload protection (backpressure); not verified. From 2 brokers on 100 % correct.
- RAM under load 1.6–1.97 GiB of 2 GiB per broker, so close to the limit.
- Short test on 2026-11-17, scenario A with history, **1 broker with all free resources**: 3.5 CPU / 8 GiB instead of
  1 CPU / 2 GiB, Kafgres still 4 CPU, Zeebe settings at default
  (`ENGINE_CPU=3500m ENGINE_MEM=8Gi RUN_TAG=c8max ./scenario-a.sh --replicas 1 camunda8`, raw data
  `results/history-full-c8max/`):

  | VUs | 1 CPU / 2 GiB (main run) | 3.5 CPU / 8 GiB | RAM |
  |---:|---:|---:|---:|
  | 10 | 245/s · p95 86 ms | 537/s · p95 24 ms | 2,210 MiB |
  | 25 | 275/s · p95 118 ms | 554/s · p95 52 ms | 1,670 MiB |
  | 50 | 291/s · p95 199 ms | 554/s · p95 101 ms | 3,536 MiB |
  | 100 | ⚠ 3.5 % correct | ⚠ 5.5 % correct (5,940 responses/s) | 5,344 MiB |

  3.5 times the CPU brings about twice the throughput, then a fixed limit at ≈ 554/s: more VUs only lengthen the
  waiting time (p50 18 → 44 → 89 ms). At 100 VUs the collapse remains, so it is not caused by the 1-CPU limit.
  Presumed limit: the single partition (a broker processes its partition sequentially) or the overload protection;
  not verified, nor how much of the 3.5 CPU Zeebe actually used. Startup time 11.6 s instead of ≈ 22 s.
- Same short test with **3 brokers sharing the 3.5 CPU equally** (1,166m / 8 GiB each, `RUN_TAG=c8max3`, raw data
  `results/history-full-c8max3/`), this time with CPU load from `kubectl top` (one value after 90 s per step):

  | VUs | 3 × 1 CPU / 2 GiB (main run) | 3 × 1,166m / 8 GiB | CPU per broker | Kafgres CPU |
  |---:|---:|---:|---:|---:|
  | 10 | 551/s · p95 52 ms | 500/s · p95 56 ms | 1,021–1,044m | 132m |
  | 25 | 687/s · p95 81 ms | 710/s · p95 77 ms | 1,111–1,115m | 238m |
  | 50 | 751/s · p95 148 ms | 722/s · p95 167 ms | 1,137–1,156m | 198m |
  | 100 | 768/s · p95 252 ms | 719/s · p95 251 ms | 1,131–1,155m | 248m |

  From 25 VUs on all three brokers run at 95–99 % of their CPU limit, Kafgres uses at most 248m of 4,000m: the limit
  is the CPU of the brokers, not the database. Still, the 17 % more CPU per broker bring no higher throughput than in
  the main run (≈ 720/s versus ≈ 750/s, within the scatter; why, not verified). All steps 100 % correct, also at
  100 VUs. With the same 3.5 CPU, 3 brokers therefore deliver ≈ 30 % more than 1 broker (≈ 720 versus ≈ 554/s) and
  don't collapse at 100 VUs. Partition replication is 1, every broker only processes its own partition.

**Scenario B: DMN table with 100 rules**
- All 9 engines compute correctly: in every step without ⚠, 100 % of the requests returned exactly the fee that k6
  computes from the same rules (only exception Camunda 8 with 3 brokers × 100 VUs: 99.8 %).
- **CIB seven drops to a tenth** (816 → 81/s at 1 replica) and stays fixed at ≈ 78/s at 1 replica, no matter how many
  VUs; the p95 grows along (up to 2.5 s). Operaton, also a Camunda 7 fork with the same DMN file, reaches 423/s.
  Diagnosis on 2026-11-17 (1 replica, 25 VUs): engine pod at 999m of 1,000m CPU, Kafgres only 252m, so no database
  bottleneck. Profile with Java Flight Recorder (623 samples in 40 s): 64 % of the CPU time in
  `org.camunda.feel.FeelEngine.rootContext` → `BuiltinFunctions.<init>`. The FEEL engine rebuilds its whole table of
  built-in functions for every cell test (up to 400 per request). CIB seven 2.2.0 ships `feel-engine 1.19.3`,
  Operaton 2.2.1 `feel-engine 1.22.1`.
- Source comparison (source JARs from Maven Central): in 1.19.3 the root context is a method,
  `private def rootContext(): EvalContext = EvalContext.create(… new BuiltinFunctions(clock, valueMapper) …)`, and
  `evaluate` calls it on every evaluation. In 1.22.1 it is a field, `private val rootContext`, built once when the
  engine is created and then reused. That is the only difference in `FeelEngine.scala`. The fix is in **1.19.4** and
  later (patch update of the same line) and in 1.20.1 and later; 1.20.0 still has the old code.
- **Counter-measurement proves it** (2026-11-17, scenario B, 1 replica, otherwise unchanged): CIB seven with
  `feel-engine` 1.19.6 instead of 1.19.3, otherwise the same image (`bench-cibseven:1.0.0-feel1196`, overridden in
  `apps/cibseven/pom.xml` via `dependencyManagement`; call `ENGINE_TAG=1.0.0-feel1196 RUN_TAG=feel1196
  ./scenario-a.sh --replicas 1 --scenario b cibseven`, raw data `results/scenario-b-history-full-feel1196/`):

  | VUs | FEEL 1.19.3 (shipped) | FEEL 1.19.6 | Operaton (FEEL 1.22.1) | CPU engine · Kafgres (1.19.6) |
  |---:|---:|---:|---:|---:|
  | 10 | 81/s · p95 196 ms | **442/s** · p95 52 ms | 423/s · p95 73 ms | 992m · 1,125m |
  | 25 | 73/s · p95 596 ms | **422/s** · p95 101 ms | 418/s · p95 100 ms | 991m · 1,575m |
  | 50 | 76/s · p95 1,207 ms | **390/s** · p95 244 ms | 367/s · p95 277 ms | 999m · 1,583m |
  | 100 | 78/s · p95 2,512 ms ⚠ | **358/s** · p95 538 ms | 245/s · p95 902 ms | 991m · 1,469m |

  With the patch update CIB seven becomes 4.6 to 5.8 times as fast and is level with Operaton, at 100 VUs even ahead.
  All responses correct. The engine pod stays at its 1-CPU limit, but now doing rule work instead of building function
  tables. The collapse in scenario B is therefore not a problem of CIB seven itself, but of the shipped FEEL version.
  The main tables above keep the shipped version (1.19.3); 2 and 3 replicas with 1.19.6 are not measured.
- Operaton and Flowable lose about half (×0.5–0.6). What exactly causes it (evaluating the table, history of the
  decision) is not verified.
- **Kogito hardly loses or even gets faster**: Kogito JVM with 3 replicas 634 → 801/s, Native 522 → 761/s. With
  history, waiting for the event acknowledgement sets the pace for Kogito Quarkus (see above); scenario B has one node
  instead of three and therefore presumably fewer events per instance (not counted). At 10 VUs the known floor of
  ≈ 100/s remains, independent of the replicas.
- Kogito SB leads with 3 replicas (1,699/s), followed by Flowable with 1,144/s.
- Camunda 8 loses 4–9 %. Invalid steps already from 50 VUs with 1 broker (61 % correct) and at 2 brokers × 100 VUs
  (27 %); in scenario A only at 1 broker × 100 VUs. Whether it is backpressure again is not verified (k6 only stores
  correct/incorrect, not the HTTP status).
- Memory cost of the DMN engine: Kogito JVM 15–20 MiB more when idle, 20–60 MiB more under load; startup times
  practically the same (CIB seven and Operaton ≈ 2–3 s longer).

**Setup and measuring procedure**
- A run on battery power became invalid (Mac went to sleep). Since then the script aborts without AC power and uses
  `caffeinate`.
- 15 s warm-up was too short for freshly started JVMs (first step too low), now 60 s.
- CIB seven and Operaton use the same `ACT_*` table names: without a fresh database the smoke call of CIB seven
  started Operaton's process. Since then every smoke call starts on an empty database.
- Kafgres reported ready via the local socket before it was reachable via TCP; creating the topics in the init
  container failed. Readiness now via TCP.
- Run without history, first smoke call: Flowable with `history-level: none` answered without variables
  (`"variables":[]`, but `ended: true`), because the REST API reads the variables of finished instances from the
  history. Solution: `activity`. Camunda 8 did not start with `SECONDARYSTORAGE_TYPE=none` (Spring error in the Operate
  JSON converter, missing `ObjectMapper`); with profile `broker` (no webapps) it runs and answers correctly.
- Counting error for Kafka records in Kafgres: `kafgres_log` and `kafgres_partitions.next_offset` stay empty or at 0
  in Kafgres 0.3.1, even when records arrive. Counting uses the high watermark from
  `kafgres_partition_offsets('<topic>')`. The first check "Kogito without history sends 0 events" used the wrong
  query and was repeated with the right one on 2026-11-16 (result see Disclosure).
- k6 without a CPU request automatically got 2 CPUs reserved and no longer fit into the cluster at 4 replicas; now a
  250m request.
- **Startup race in Kogito's Kafka persistence** (found 2026-11-19 after renaming scenario C to B): the rebuilt
  `kogito-jvm-kafka` image never became ready (3 of 3 starts): `IllegalStateException: Can only set StateListener
  before calling start(). Current state is: REBALANCING`, followed by `Error creating KafkaProcessInstances for
  process: ScenarioA`. The measured image with the old process ID `ScenarioC` started fine on the same cluster at the
  same time; `kogito-native-kafka` started with both. Cause (Kogito 10.2.0 and Quarkus 3.27.2 sources):
  `KafkaStreamsStateListener` is `@ApplicationScoped` and calls `streams.setStateListener(this)` when its bean is
  created. Quarkus starts Kafka Streams in its `StartupEvent` observer and only holds the lazy client proxy of that
  listener. If nothing has created the bean before, the first state change (REBALANCING) creates it, and
  `setStateListener` throws because the streams are already running. Whether a process creates the bean first depends
  on startup order and timing; why the process ID changes it is not verified. Fix in our app:
  [KafkaStreamsListenerWarmup](apps/kogito-kafka/src/main/java/de/piu/bpmn/benchmark/KafkaStreamsListenerWarmup.java)
  creates the listener bean in a `StartupEvent` observer with `@Priority(1)`, i.e. before Quarkus starts the streams.
  With it: 3 of 3 starts ready, smoke calls for A and B correct in both Kafka variants. Startup only, no effect on the
  measured path. The measured images of the Kafka variants did not contain this class.

**CIB seven / Operaton on Quarkus (built 2026-11-23)**
- Both vendors ship a Quarkus extension (`org.cibseven.bpm.quarkus:cibseven-bpm-quarkus-engine`,
  `org.operaton.bpm.quarkus:operaton-bpm-quarkus-engine`), officially tested only as an executable JAR with one
  embedded engine. Neither documentation mentions GraalVM native image; native was not tried.
- The extensions have no REST API. The plain JAX-RS resources work on RESTEasy Classic once their jar is in the Jandex
  index (`quarkus.index-dependency`). Indexing turns every `@Path` class into a CDI bean, and the sub-resources
  (`HistoryRestServiceImpl` etc., created with `new` by the root resources) have constructors CDI cannot satisfy: build
  error `Unsatisfied dependency for type java.lang.String`. Fix: `quarkus.arc.exclude-types=…rest.impl.**`. The
  engine lookup uses the vendors' `ContainerManagedProcessEngineProvider` (registered via `META-INF/services`), which
  works because the extensions register the engine with the `RuntimeContainerDelegate`.
- Running the JAR from the project folder fails at startup: `ModelValidationException: Unable to parse schema` for the
  DMN model, loaded from `jar:file:…/Youtube&Website&Vorträge/…`. The `&` and `ä` in the path break the schema URL.
  In the container (`/app`) and from a path without special characters it starts. Not looked at further.
- History switch for `--history none`: `QUARKUS_CIBSEVEN_GENERIC_CONFIG_HISTORY` / `QUARKUS_OPERATON_GENERIC_CONFIG_HISTORY`
  (checked: `historyLevel` 0 in `act_ge_property`, 3 with the default).
- Check on 2026-11-23: smoke calls A and B (full) and A (none) correct for both; one k6 run each at 1 replica × 10 VUs
  without errors: A cibseven-quarkus 375/s, operaton-quarkus 356/s; B 134/s and 136/s. Single test runs, not part of the
  results.
- Control run on 2026-11-23, same day and same procedure (fresh Kafgres with 4 CPU, 1 replica, 10 VUs, k6 pod without
  limits), Spring Boot `operaton` (image `bench-operaton:1.0.0`): A 460/s (p50 11 ms), B 269/s (p50 32 ms). So the same
  day Spring Boot was 1.3× faster than Quarkus in A (460 vs 356/s) and 2.0× faster in B (269 vs 136/s). The gap compared
  with the main runs (A 783/s, B 423/s) was much larger. The same Spring Boot image measured 41 % (A) and 36 % (B)
  lower than in the main runs; the cause of this drift is not verified. A restart of Docker Desktop did not help
  (repeat at 19:00: A 436/s, B 275/s). During the runs the Mac had heavy load outside Docker (load average 82 → 19,
  LogiPluginService ≈ 160 % CPU, coreaudiod 70–110 %, camera service UVCAssistant); suspected cause, not verified.
  After Logi Options+ and other apps were closed (19:15, load average still ≈ 30) it got worse: A 376/s, B 201/s.
  The cluster looked normal: only Kafgres running, idle at 42m CPU, empty `emptyDir` database, no thermal warning on
  the Mac. Cause still open; the full run of `cibseven-quarkus` was not started.
  After a reboot of the Mac (22:45, Time Machine backup still running, Avast up to ≈ 90 % CPU, load average ≈ 22–32):
  A 665/s (p50 7 ms), B 383/s (p50 12 ms), i.e. 85 % and 91 % of the main runs. Clearly better, still below the
  main level; the host load is the likely cause (not verified).
- Full run `cibseven-quarkus` on 2026-11-23, 23:00–00:25 (environment 10–15 % below the main runs, see
  [Engines](#engines)), compared with the Spring Boot `cibseven` main runs. Best valid throughput per replica step;
  startup of the first replica; RAM per pod idle / max under load:

  | | Spring Boot 1 / 2 / 3 replicas | Quarkus 1 / 2 / 3 replicas |
  |---|---|---|
  | A, history full | 816 / 1,641 / 1,630/s | 673 / 1,379 / 1,799/s |
  | B, history full | 442/s (1 replica, `feel-engine` 1.19.6); 81 / 193 / 263/s with the shipped 1.19.3 | 470 / 938 / 1,150/s (1.19.6) |
  | A, history none | 1,686 / 3,438 / 4,620/s | 1,131 / 2,167 / 3,062/s |
  | Startup | 10–11 s | 5–6 s |
  | RAM idle / under load | ≈ 255 / up to 506 MiB | ≈ 215 / up to 439 MiB |

  All requests correct (ok_rate 1). Within the environment gap, A and B with full history are on par; at 3 replicas in
  A Quarkus is ahead (1,799 vs 1,630/s). Without history Quarkus stays 33–37 % behind, more than the environment gap
  explains (cause not verified; candidate: JTA transactions, which weigh more when there are fewer SQL statements per
  request). Quarkus starts about twice as fast and needs ≈ 40 MiB less RAM per pod. The single runs at 1 replica ×
  10 VUs earlier that day (375/s and 134/s) were far below these values, so they were mostly the environment.
  Cause of the Quarkus gap not verified
  (candidates: JTA transactions via Narayana in the extension vs. plain JDBC transactions in Spring Boot, RESTEasy
  Classic vs. Jersey).
- Full run `operaton-quarkus` on 2026-11-24, 11:10–12:36. Control run right before it, same procedure as above
  (Spring Boot `operaton`, 1 replica, 10 VUs): A 732/s (p50 6 ms), B 448/s (p50 10 ms), i.e. 94 % and 106 % of the
  main runs; the environment was close to the main level this time. Compared with the Spring Boot `operaton` main runs,
  same format as for CIB seven:

  | | Spring Boot 1 / 2 / 3 replicas | Quarkus 1 / 2 / 3 replicas |
  |---|---|---|
  | A, history full | 783 / 1,464 / 1,630/s | 598 / 1,120 / 1,462/s |
  | B, history full | 423 / 740 / 881/s | 410 / 801 / 1,181/s |
  | A, history none | 1,481 / 2,656 / 3,669/s | 1,080 / 2,164 / 3,059/s |
  | Startup | 10–13 s | 6 s |
  | RAM idle / under load | ≈ 260 / up to 479 MiB | ≈ 220 / up to 477 MiB |

  All requests correct (ok_rate 1). In A Quarkus is 24 % behind at 1 and 2 replicas and 10 % at 3; without history
  17–27 % behind. In B (DMN, more CPU work per request in the engine) Quarkus is on par at 1 replica and ahead at
  2 and 3 replicas (+8 %, +34 %). The same pattern as with CIB seven: the fewer SQL statements per request matter
  relative to the engine work, the more Quarkus falls behind; this fits a fixed overhead per request/transaction
  (candidates as above: JTA via Narayana, RESTEasy Classic; not verified). Quarkus starts about twice as fast and
  needs ≈ 40 MiB less RAM idle; under load the maximum is the same.

## Status

- [x] Step 1: cluster, Kafgres, ingress, k6 smoke test
- [x] Scenario A built: 9 engines, all answer the smoke call (`SMOKE_ONLY=1`) correctly with `counter = 3`
- [x] Scenario A measured, all 9 engines, Kafgres 4 CPU, replicas 1/2/3 (see results; the run with Kafgres 2 CPU and
      1/2/4 was discarded)
- [x] Scenario A measured without history (`--history none`, all 9 engines)
- [x] Kogito Kafka re-measured with the iterator fix (with and without history)
- [x] Scenario B (DMN table, 100 rules, COLLECT + SUM) measured, all 9 engines, full history
- [x] CIB seven counter-measured in scenario B with `feel-engine` 1.19.6 (1 replica): collapse fixed
- [x] CIB seven and Operaton on Quarkus (JVM) built and smoke-tested (A, B, history none)
- [x] `cibseven-quarkus` measured (A, B, A without history; environment 10–15 % below the main runs)
- [x] `operaton-quarkus` measured (A, B, A without history; environment 94–106 % of the main runs)
- [ ] Open in scenario B: cause of the Camunda 8 errors from 50 VUs
- [ ] Open in scenario A: waiting time of the Kafka acknowledgement for Kogito Quarkus
- [ ] Load spike with autoscaling
- [ ] Scenario C (KYC via Kafka with a user task)
- [ ] Hand the results over to the animation

## License

Apache License 2.0, see [LICENSE](LICENSE). `apps/kogito-kafka/src/main/java/org/kie/kogito/persistence/kafka/KafkaProcessInstances.java`
is a modified copy from Apache KIE (Kogito 10.2.0) and keeps its Apache license header.
