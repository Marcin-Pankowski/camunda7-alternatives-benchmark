# Camunda 7 Alternatives Benchmark

Geschwindigkeitsvergleich von **CIB seven, Operaton, Flowable, Kogito (5 Varianten) und Camunda 8** in Kubernetes,
mit einem Load Balancer davor: Startzeit, Speicher, Durchsatz und Skalierung der Wege, die nach dem Ende von
Camunda 7 CE offenstehen. Die Ergebnisse sind die Grundlage für das Video „Wie schnell sind BPMN-Engines?“ auf dem
YouTube-Kanal @BPMNtAInment.

Alles läuft **lokal auf einem MacBook (M1 Max)**. Lastgenerator und Engines teilen sich eine Maschine, die Zahlen
sind deshalb **relativ** zu lesen (Engine A gegen Engine B), nicht als absolute Produktionswerte.
Gemessen wird mit den **Standard-Einstellungen** jeder Engine. Wo davon abgewichen wird, steht es unter
[Offenlegung](#offenlegung).

## Aufbau

| Teil | Was |
|---|---|
| Kubernetes | k3d 5.9 (k3s 1.35) in Docker Desktop (8 CPU / 32 GB), ein Knoten |
| Load Balancer | Traefik (in k3s enthalten), ein Ingress pro Engine (`<engine>.bench.local`) |
| Datenbank + Kafka | [Kafgres](https://github.com/RayElg/kafgres) 0.3.1 (Postgres 16 mit Kafka-Protokoll), bei jedem Start leer, CPU über `--db-cpu` (Standard 4) / 2 GB |
| Last | k6 1.8.3 als Pod im Cluster (Request 0,25 CPU, Limit 2 CPU) |
| Engine-Pods | jede Engine **1 CPU / 2 GB pro Replica** (Requests = Limits) |

## Engines

Alle neun Engines führen denselben Prozess aus (Szenario A, siehe unten). Jede App nutzt die Spring-Boot- bzw.
Quarkus-Version, gegen die ihre Engine gebaut ist. Package und Maven-groupId: `de.piu.bpmn.benchmark`.

| ID | Engine | Packaging | Java | Persistenz | Die 3 Tasks |
|---|---|---|---|---|---|
| `cibseven` | CIB seven 2.2.0 | eigene Spring-Boot-App (Boot 4.0.6), Engine + REST, ohne Webapps — [apps/cibseven](apps/cibseven) | 21 | Postgres (Kafgres), History `full` | JUEL-Expression `${counter + 1}` |
| `operaton` | Operaton 2.2.1 | eigene Spring-Boot-App (Boot 4.1.2), Engine + REST, ohne Webapps — [apps/operaton](apps/operaton) | 21 | Postgres (Kafgres), History `full` | JUEL-Expression |
| `flowable` | Flowable 8.0.0 | eigene Spring-Boot-App (Boot 4.0.2), Engine + REST, ohne UI — [apps/flowable](apps/flowable) | 21 | Postgres (Kafgres), History `full` | JUEL-Expression |
| `kogito-jvm` | Kogito 10.2.0 | Quarkus 3.27.2, JVM — [apps/kogito](apps/kogito) | 21 | JDBC in Postgres (Kafgres) + Prozess-Events nach Kafka | Java-Script-Task |
| `kogito-jvm-kafka` | Kogito 10.2.0 | Quarkus 3.27.2, JVM — [apps/kogito-kafka](apps/kogito-kafka) | 21 | Kafka (Topic `kogito.process` in Kafgres, 4 Partitionen) + Prozess-Events nach Kafka | Java-Script-Task |
| `kogito-sb` | Kogito 10.2.0 | Spring Boot 3.5.10 — [apps/kogito-sb](apps/kogito-sb) | 21 | JDBC in Postgres (Kafgres) + Prozess-Events nach Kafka | Java-Script-Task |
| `kogito-native` | Kogito 10.2.0 | Quarkus 3.27.2, GraalVM-Native-Image (Mandrel, JDK 21) — [apps/kogito](apps/kogito) | 21 (Native) | JDBC in Postgres (Kafgres) + Prozess-Events nach Kafka | Java-Script-Task |
| `kogito-native-kafka` | Kogito 10.2.0 | Quarkus 3.27.2, GraalVM-Native-Image (Mandrel, JDK 21) — [apps/kogito-kafka](apps/kogito-kafka) | 21 (Native) | Kafka (Topic in Kafgres) + Prozess-Events nach Kafka | Java-Script-Task |
| `camunda8` | Camunda 8.10.9 | offizielles Image `camunda/camunda`, Broker + Gateway + REST — [k8s/camunda8](k8s/camunda8) | **25** | Zeebe-Log auf der Pod-Platte; Historie per RDBMS-Exporter in Postgres (Kafgres), nur `audit`-Niveau (siehe [Offenlegung](#offenlegung)) | FEEL-Script-Task `=counter + 1` |

Die JVM-Apps laufen auf einem schlichten `eclipse-temurin:21` JRE mit JVM-Standardwerten
([apps/Dockerfile.springboot](apps/Dockerfile.springboot), `apps/kogito*/Dockerfile.jvm`), die Native-Images auf
`ubi9-quarkus-micro-image` ([apps/Dockerfile.native](apps/Dockerfile.native)).

## Szenario A

Start → Task 1 → Task 2 → Task 3 → Ende. Jeder Task erhöht `counter` um 1. Gestartet wird per REST über Traefik,
und die Antwort kommt erst, wenn der Prozess fertig ist. Eine Anfrage zählt nur, wenn `counter = 3` zurückkommt.

| Engine | Aufruf |
|---|---|
| CIB seven, Operaton | `POST /engine-rest/process-definition/key/ScenarioA/start` mit `withVariablesInReturn` |
| Flowable | `POST /process-api/runtime/process-instances` mit `returnVariables` |
| Kogito (alle) | `POST /ScenarioA` (von Kogito aus dem BPMN erzeugt) |
| Camunda 8 | `POST /v2/process-instances` mit `awaitCompletion` |

## Szenario C

Start → Business Rule Task → Ende. Der Task wertet eine DMN-Entscheidungstabelle `Pricing` mit **100 Regeln** aus
und schreibt das Ergebnis in die Variable `fee`. Eingaben: `age`, `amount`, `country`, `customerType`, bei jeder
Anfrage zufällig gewählt.

- Hit Policy **COLLECT mit Aggregation SUM**: Jede Anfrage wird gegen alle 100 Regeln geprüft, die Gebühren aller
  Treffer werden addiert.
- Regeln 1–99 sind zufällig (fester Startwert): Bereiche für Alter und Betrag, bei 60 % ein Land, bei 50 % ein
  Kundentyp, Gebühr = Regelnummer. Regel 100 greift immer (Gebühr 1.000), damit die Summe nie leer ist. Im Schnitt
  treffen außer ihr etwa 2 weitere Regeln.
- Erzeugt von [load/gen-pricing-dmn.py](load/gen-pricing-dmn.py): eine DMN-Datei pro Engine und dieselben Regeln als
  `load/scenario-c-rules.json`. Daraus rechnet k6 für jede Anfrage die richtige Gebühr nach. Eine Anfrage zählt nur,
  wenn genau diese Gebühr zurückkommt.
- Aufrufe wie in Szenario A, nur mit Prozess `ScenarioC` und den vier Eingaben.

## Starten

Voraussetzungen: Docker Desktop (8 CPU, 32 GB), `kubectl`, Java 21 + Maven. k3d lädt `cluster.sh` selbst nach `bin/`.

```bash
./cluster.sh   # Cluster anlegen, Kafgres-Image bauen/importieren, Kafgres starten
./smoke.sh     # Rauchtest: Postgres, Kafka-Protokoll, Load Balancer über 2 Pods, k6

# Apps und Images bauen (Beispiel CIB seven; Operaton, Flowable, Kogito SB genauso)
(cd apps/cibseven && mvn -q package -DskipTests)
docker build -f apps/Dockerfile.springboot -t bench-cibseven:1.0.0 apps/cibseven
# Kogito Quarkus: erst native (ersetzt target/), dann JVM daneben
(cd apps/kogito && mvn -q clean package -DskipTests -Dquarkus.native.enabled=true -Dquarkus.native.container-build=true \
   && mvn -q package -DskipTests)
docker build -f apps/kogito/Dockerfile.jvm -t bench-kogito-jvm:1.0.0 apps/kogito
docker build -f apps/Dockerfile.native  -t bench-kogito-native:1.0.0 apps/kogito
bin/k3d image import -c bench bench-cibseven:1.0.0 bench-kogito-jvm:1.0.0 bench-kogito-native:1.0.0   # usw.

SMOKE_ONLY=1 ./scenario-a.sh cibseven camunda8   # nur prüfen, ob die Engines korrekt antworten
./scenario-a.sh cibseven operaton flowable kogito-jvm kogito-jvm-kafka kogito-sb kogito-native kogito-native-kafka camunda8
./scenario-a.sh --db-cpu 2 --replicas 1,2,4 cibseven   # andere Staffelung: CPUs für Kafgres, Replica-Stufen
./scenario-a.sh --history none cibseven   # ohne History, nur der Laufzeitzustand (Standard: full)
RUN_TAG=iterfix ./scenario-a.sh kogito-jvm-kafka   # Nachmessung getrennt ablegen: results/history-full-iterfix/
./scenario-a.sh --scenario c cibseven   # Szenario C (DMN-Tabelle), results/scenario-c-history-full/
ENGINE_CPU=3500m ENGINE_MEM=8Gi RUN_TAG=c8max ./scenario-a.sh --replicas 1 camunda8   # Sonderlauf: mehr Ressourcen pro Broker (nur Camunda 8)

bin/k3d cluster delete bench   # alles wieder weg
```

Ingress von außen: `curl -H 'Host: <engine>.bench.local' http://127.0.0.1:8081/`

## Ablauf von `scenario-a.sh`

```
./scenario-a.sh [--db-cpu 4] [--replicas 1,2,3] [--history full|none] [--scenario a|c] <engine …>
│   nur am Netzteil, sonst Abbruch
│   prüft vorher, ob Kafgres + größte Stufe × 1 CPU + k6 + System in den Cluster passen, sonst Abbruch
│   setzt die CPUs von Kafgres (Request = Limit)
│   schreibt die ConfigMap `history` (bei none: History-Schalter der Engines, siehe Offenlegung)
│
└─ für jede Engine nacheinander:
   │
   ├─ 1. Testaufruf (smoke)
   │     Kafgres neu starten (leere DB)
   │     → Engine starten (1 Pod; Camunda 8 über k8s/camunda8/start.sh)
   │        nicht bereit nach 300 s → Fehler aus dem Log zeigen, Pod löschen, nächste Engine
   │     → 1 Prozessstart über Traefik → kommt counter = 3 zurück?
   │     → Engine löschen
   │     (SMOKE_ONLY=1: hier Schluss, nächste Engine)
   │
   └─ 2. Messung (bench.sh, mit caffeinate gegen den Ruhezustand)
         für jede Replica-Stufe aus --replicas (Standard 1, 2, 3):
         │  Kafgres neu starten (leere DB)
         │  1 Pod starten ─────────────► Startzeit
         │  auf N Pods skalieren ──────► Zeit fürs Hochskalieren
         │    (Camunda 8: alle N Broker gleichzeitig, nur eine Startzeit)
         │  60 s Leerlauf ─────────────► RAM im Leerlauf
         │
         └─ für 10, 25, 50, 100 VUs:
               k6-Pod: 60 s Aufwärmen + 60 s Messung ─► Durchsatz, p50/p95/p99
               nach 90 s ──────────────────────────────► RAM und CPU unter Last (Engine-Pods + Kafgres)
         → alles nach results/history-<full|none>/<engine>.jsonl
         → Engine löschen (auch bei Abbruch)
```

Eine Anfrage läuft so durch den Cluster:

```
 k6 (VUs) ──POST──► Traefik ──► Engine-Pod 1 … N ──SQL / Kafka──► Kafgres
          ◄─counter = 3──        je 1 CPU / 2 GB                   --db-cpu (4) / 2 GB
```

## Offenlegung

Diese Punkte gehören zu jeder Veröffentlichung der Zahlen:

**Messumgebung**
- Alles auf einem MacBook (M1 Max), Docker Desktop mit 8 CPU / 32 GB, ein Kubernetes-Knoten. Zahlen sind relativ.
- Lastgenerator, Load Balancer, Datenbank und Engines teilen sich dieselben 8 CPU. Standard: Kafgres 4 CPU,
  Replicas 1/2/3 mit je 1 CPU, bei 3 Replicas sind also 7 CPU fest vergeben. Traefik (ohne Limit), k6 und k3s
  teilen sich den Rest. Werte der größten Stufe zeigen deshalb eher die Grenze der Maschine als die der Engine.
  Jede `results/history-<full|none>/<engine>.jsonl` beginnt mit einer `config`-Zeile (DB-CPUs, Engine-CPU,
  History, Replica-Stufen; die History steht erst ab dem Lauf ohne History darin).
- Ein erster Lauf mit Kafgres auf 2 CPU zeigte bei CIB seven und Operaton die Datenbank als Grenze: Kafgres lief
  voll (2 von 2 CPU), die Engine-Pods nur halb ausgelastet; ab 2 Replicas kein Zuwachs mehr (ca. 730–950/s).
- Gemessen nur am Netzteil, mit `caffeinate` gegen den Ruhezustand, ohne andere Docker-Container.
- Jede Messreihe startet mit leerer Datenbank. 60 s Aufwärmen vor 60 s Messung, weil 15 s bei frisch gestarteten
  JVMs nicht reichten (erster Lauf mit 10 VUs war deutlich zu niedrig).

**Unterschiede zwischen den Engines**
- **History: Ziel ist eine vollständige Spur (`full`), Camunda 8 kann das nicht.** Gemessen pro Prozessinstanz:

  | Was festgehalten wird | CIB seven, Operaton (`full`) | Flowable (`full`) | Kogito (Prozess-Events) | Camunda 8 (RDBMS-Exporter) |
  |---|---|---|---|---|
  | Prozess Start/Ende | 1 Zeile `act_hi_procinst` | 1 Zeile | 2 Status-Events | Zeile in `PROCESS_INSTANCE` |
  | Durchlaufene Knoten | 5 Zeilen `act_hi_actinst` | 9 Zeilen (inkl. Sequenzflüsse) | 10 Knoten-Events (Ein-/Austritt) | Zeilen in `FLOW_NODE_INSTANCE` (nicht gezählt) |
  | **Jede Variablen-Änderung einzeln** | **4 Zeilen `act_hi_detail`** | **4 Zeilen `act_hi_detail`** | **4 Variablen-Events** (`counter` 0, 1, 2, 3) | **nein** |
  | Speicherweg | SQL, synchron in derselben Transaktion | SQL, synchron | Kafka (Kafgres), Topic `kogito-processinstances-events`; Quarkus: Antwort wartet auf die Bestätigung durch Kafka (siehe Abweichungen), Spring Boot: nicht geprüft | SQL, **asynchron** über den Exporter |

  Die Kogito-Zahlen sind mit `kogito-native-kafka` gezählt, die anderen mit je einem Testaufruf.

- **Zweiter Lauf ohne History (`--history none`):** Gespeichert wird nur, was die Engine zum Ausführen braucht. Die
  Schalter kommen als Umgebungsvariablen aus der ConfigMap `history` (`envFrom`), die Images bleiben gleich:

  | Engine | Einstellung bei `none` | Geprüft: was nach 5 Instanzen in Kafgres steht |
  |---|---|---|
  | CIB seven, Operaton | `history-level: none` | 0 Zeilen in `act_hi_*` |
  | Flowable | `history-level: activity` (**nicht** none) | 5 Prozess-, 45 Aktivitäts-, 5 Variablenzeilen (Endstand), 0 in `act_hi_detail` |
  | Kogito (alle 5) | Prozess-Events aus (`kogito.events.processinstances/processdefinitions/usertasks.enabled=false`) | 0 Prozess-Events; 1 Prozessdefinitions-Event beim Start (der Schalter `processdefinitions.enabled` greift nicht, nicht geprüft warum) |
  | Camunda 8 | kein Secondary Storage (`CAMUNDA_DATA_SECONDARYSTORAGE_TYPE=none`), nur Profil `broker` | 0 Tabellen |

  - Flowable bleibt bei `activity`, weil seine REST-API die Variablen einer beendeten Instanz aus der History liest:
    Mit `none` läuft der Prozess durch, die Antwort enthält aber keinen `counter`, die Prüfung auf `counter = 3`
    wäre unmöglich. `activity` ist die kleinste Stufe, mit der das geht.
  - Camunda 8 startet ohne Secondary Storage nur ohne Operate/Tasklist/Identity (sie brauchen es und brechen den
    Start ab). Bei `full` laufen diese Webapps im selben Pod mit, bei `none` nicht.
  - Kogito Quarkus behält den blockierenden Versand (`errors.propagate`), er hat ohne Events nichts zu tun.
  - Die Kafka-Persistenz der Kafka-Varianten bleibt, sie ist der Laufzeitzustand.

  **Camunda 8 im Detail:**
  - Der eigentliche Zustand liegt im Zeebe-Log (Event-Sourcing, RocksDB-Snapshots) auf der Pod-Platte. Dort entsteht
    zwar jede Variablen-Änderung als eigener Datensatz, aber das Log wird nach Export und Snapshot aufgeräumt und ist
    keine abfragbare Historie.
  - Die abfragbare Historie (Operate/REST-Suche) schreibt der RDBMS-Exporter nach Postgres. Die Tabelle `VARIABLE`
    hat `VAR_KEY` als Primärschlüssel: eine Variable wird einmal eingefügt und bei jeder Änderung überschrieben
    (`INSERT`, dann `UPDATE`). Am Ende steht nur der letzte Wert (`counter = 3`). Eine Tabelle mit jeder einzelnen
    Änderung (wie `act_hi_detail`) gibt es nicht; das entspricht dem Niveau `audit` der C7-Engines.
  - Der Exporter arbeitet asynchron: Die Antwort auf `awaitCompletion` wartet nicht darauf, dass die Historie in
    Postgres steht.
  - Jede Änderung dauerhaft ablegen könnte nur ein zusätzlicher Elasticsearch-/OpenSearch-Exporter, der die rohen
    Zeebe-Datensätze speichert. Den gibt es in diesem Aufbau nicht (keine Suchmaschine im Cluster); nicht getestet.
  - Folge: Camunda 8 schreibt pro Instanz weniger Historie als die anderen Engines und hat dadurch einen Vorteil
    beim Durchsatz.
- **Laufzeit-Persistenz ist etwas anderes als die Audit-Spur:** Kogitos JDBC- bzw. Kafka-Persistenz (`kogito.process`)
  speichert nur den Zustand laufender Instanzen und entfernt ihn am Ende, wie die `ACT_RU_*`-Tabellen der C7-Engines.
- **Arbeit pro Instanz:** Die Audit-Spur geht bei Kogito als Kafka-Nachrichten raus, bei den C7-Engines und
  Flowable als SQL in Postgres. Das ist ähnlicher Inhalt, aber unterschiedlich teure Arbeit; der Vergleich zeigt
  Engine plus Speicherweg, nicht die Engine allein.
- **Task-Typ:** CIB seven, Operaton, Flowable nutzen JUEL-Expressions, Kogito Java-Script-Tasks, Camunda 8
  FEEL-Script-Tasks. Alle drei werden von der Engine selbst ausgeführt, ohne externe Worker.
- **Java:** alle Engines Java 21, **Camunda 8 Java 25** (offizielles Image, unverändert inkl. Compact Object Headers).
  CIB seven 2.2 unterstützt offiziell nur bis Java 21.
  Camunda 8 läuft nativ auf arm64, nicht emuliert (geprüft am 19.11.2026): Das Tag `camunda/camunda:8.10.9` ist ein
  Multi-Arch-Image (amd64 + arm64), lokal liegt die arm64-Variante. Im Cluster (Node `arm64`) meldet ein Pod mit
  diesem Image `uname -m` = `aarch64` und `OpenJDK 64-Bit Server VM, 25.0.5+-minimos-r0`; die `java`-Binärdatei ist
  ein AArch64-ELF.
- **Packaging:** CIB seven, Operaton, Flowable als eigene schlanke Spring-Boot-Apps (Engine + REST, ohne Webapps),
  Camunda 8 als offizielles Komplett-Image (inkl. Operate/Tasklist-Backend).
- **Skalierung:** Die anderen Engines skalieren über zustandslose Kopien hinter Traefik. Camunda 8 skaliert über
  Broker und Partitionen (N Broker = N Partitionen, Replikationsfaktor 1), alle Broker starten gleichzeitig.
- **Kafka-Persistenz:** nur Kogito auf Quarkus (das Addon gibt es nicht für Spring Boot). Kafgres spricht das
  Kafka-Protokoll, ist aber kein Apache Kafka.
- **CIB seven und Operaton schreiben ihre History zweimal:** Am Prozessende setzt die Engine (Standard-Strategie
  `end` der History-Bereinigung) per `UPDATE … set REMOVAL_TIME_` die Löschzeit in 15 History-Tabellen. Jede der
  11 History-Zeilen pro Instanz wird also eingefügt und gleich wieder geändert. Flowable und Kogito kennen diesen
  Schritt nicht. Gemessen mit `pg_stat_user_tables` (INSERTs = UPDATEs je Tabelle); Standardverhalten, nicht verändert.

**Abweichungen von den Standard-Einstellungen**
- Alle Engines: Datenbank zeigt auf Kafgres statt auf die eingebaute Standard-DB.
- REST-APIs ohne Authentifizierung. Bei Camunda 8 dafür ausdrücklich abgeschaltet
  (`CAMUNDA_SECURITY_AUTHENTICATION_UNPROTECTEDAPI=true`, Authorizations aus).
- History-Level `full` für CIB seven, Operaton und Flowable, ausdrücklich gesetzt. Bei CIB seven und Operaton ist das
  auch der Standard des Spring-Boot-Starters (die Engine selbst hätte `audit`), bei Flowable eine Abweichung (Standard
  `audit`). Grund: Kogito hält mit seinen Prozess-Events ebenfalls jede Variablen-Änderung fest.
- Kogito: JDBC- bzw. Kafka-Persistenz eingeschaltet (Standard wäre nur im Speicher), dazu das Addon für
  Prozess-Events nach Kafka (`kie-addons-quarkus-events-process` bzw. `kie-addons-springboot-events-process-kafka`).
  Die Topics legt ein Init-Container in Kafgres an.
- Kogito Quarkus (JDBC): Tabellen über Quarkus' eigenes Flyway statt `kie.flyway` (dessen Klassenpfad-Scan
  funktioniert im Native-Image nicht), für JVM und Native gleich. Flyway auf 11.11.2 festgelegt (die Version, gegen
  die Quarkus 3.27.2 gebaut ist), sonst bricht der Native-Build ab.
- Kogito Spring Boot: Spring-Boots eigene Flyway-Autokonfiguration aus, die Tabellen legt Kogito selbst an.
- Kogito Quarkus: Kafka-Producer mit `acks=all` und `enable.idempotence=true` (Standard des Kafka-Clients und von
  Kogito Spring Boot) statt SmallRye-Standard `acks=1` ohne Idempotenz. Mit `acks=1` beantwortete Kafgres unter Last
  manche Schreibanfragen nie (`REQUEST_TIMED_OUT`, Kafgres dabei fast ohne CPU-Last); der Producer wiederholte
  endlos. Das allein behob die Ausfälle aber nicht, siehe nächster Punkt.
- Kogito Quarkus: `kogito.events.processinstances.errors.propagate=true`, d. h. die Prozess-Events werden blockierend
  gesendet und die REST-Antwort wartet, bis Kafka sie bestätigt hat. Standard ist „abschicken und vergessen“: Unter
  Dauerlast nahm Kafgres die Events langsamer ab, als Kogito sie erzeugte, die wartenden Nachrichten sammelten sich
  unbegrenzt im Heap (Heap-Histogramm: 39.000 → 291.000 Nachrichten in 40 s, Heap 494 von 494 MB), danach nur noch
  Full GCs, Hänger bis 60 s und Fehler. Keine Pod-Neustarts, kein OOMKilled. Mit der Einstellung blieb der Speicher
  stabil, dafür kostet jeder Request die Wartezeit auf Kafgres. Das entspricht den C7-Engines und Flowable, die ihre
  History synchron vor der Antwort schreiben. Kogito SB lief ohne diese Einstellung stabil (wie es sendet, ist nicht
  geprüft).

**Szenario C (DMN-Tabelle)**
- Eine Tabelle, drei Dialekte. CIB seven, Operaton, Kogito und Camunda 8 bekommen FEEL mit Bereichen wie
  `[18..40]`. Flowable kennt diese Bereiche nicht, seine Tabelle hat deshalb 6 statt 4 Spalten (`>= 18` und `<= 40`
  getrennt). Die Treffer sind dieselben.
- CIB seven und Operaton verlangen auch für die Entscheidung eine History-Aufbewahrungsdauer
  (`camunda:historyTimeToLive="P1D"`), sonst lehnen sie das Deployment ab (`ENGINE-12018`). Sie schreiben bei voller
  History jede Entscheidung mit Ein- und Ausgaben in die History.
- Kogito: `fee` ist eine Integer-Variable. Mit `BigDecimal` oder `Object` scheitert die Codegenerierung der
  Persistenz.
- Kogito JVM Kafka und Native Kafka laufen mit dem Iterator-Fix (siehe „Kogito Kafka mit Iterator-Fix“).
- Für Szenario C wurden alle Images neu gebaut. Sie enthalten jetzt beide Szenarien, die Kogito- und Flowable-Images
  zusätzlich ihre DMN-Engine. Die für Szenario A gemessenen Images liegen lokal als `:1.0.0-a`. Ein neuer Lauf von
  Szenario A mit `:1.0.0` misst also nicht exakt dieselben Images (Kogito JVM: 15–20 MiB mehr RAM im Leerlauf).

## Ergebnisse Szenario A (History voll)

Versuchsprotokoll mit Aufbau, Vorgeschichte und Erkenntnissen: [versuche/2026-11-15-mit-history.md](versuche/2026-11-15-mit-history.md).

Lauf vom 15./16.11.2026: Kafgres 4 CPU, jeder Engine-Pod 1 CPU / 2 GB, Replicas 1/2/3, je Stufe 60 s Messung nach
60 s Aufwärmen. Kogito Quarkus (4 Varianten) am 16.11. mit blockierendem Event-Versand nachgemessen (siehe
Erkenntnisse). Rohdaten in `results/history-full/<engine>.jsonl`. ⚠ = Stufe nicht verwertbar (Anteil korrekter Antworten unter
99 % oder p95 über 2 s). Lokaler Cluster, die Werte sind nur untereinander vergleichbar.

**1 Replica** – Durchsatz/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 806 · 54 | 816 · 73 | 699 · 133 | 650 · 297 |
| Operaton | 782 · 58 | 764 · 77 | 665 · 158 | 582 · 332 |
| Flowable | 631 · 58 | 595 · 90 | 418 · 280 | 384 · 613 |
| Kogito SB | 743 · 76 | 750 · 86 | 712 · 140 | 651 · 300 |
| Kogito JVM | 77 · 145 | 326 · 121 | 352 · 201 | 338 · 407 |
| Kogito JVM Kafka | 66 · 182 | 253 · 132 | 483 · 128 | 23 · 5.925 ⚠ |
| Kogito Native | 79 · 136 | 253 · 126 | 256 · 234 | 253 · 460 |
| Kogito Native Kafka | 64 · 176 | 206 · 191 | 349 · 182 | 1.374 · 224 ⚠ 10 % ok |
| Camunda 8 | 244 · 86 | 275 · 118 | 291 · 199 | 2.153 · 96 ⚠ 3 % ok |

**2 Replicas** – Durchsatz/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 1.532 · 14 | 1.641 · 37 | 1.567 · 63 | 1.361 · 190 |
| Operaton | 1.441 · 19 | 1.419 · 49 | 1.464 · 77 | 1.225 · 255 |
| Flowable | 1.301 · 35 | 1.100 · 76 | 966 · 177 | 817 · 461 |
| Kogito SB | 1.152 · 41 | 1.108 · 74 | 1.053 · 154 | 1.028 · 290 |
| Kogito JVM | 78 · 144 | 197 · 142 | 382 · 205 | 423 · 586 |
| Kogito JVM Kafka | 70 · 161 | 169 · 168 | 403 · 156 | 577 · 218 |
| Kogito Native | 71 · 163 | 185 · 150 | 357 · 225 | 555 · 309 |
| Kogito Native Kafka | 74 · 146 | 170 · 171 | 415 · 156 | 617 · 237 |
| Camunda 8 | 410 · 74 | 509 · 94 | 505 · 198 | 516 · 267 |

**3 Replicas** – Durchsatz/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 1.630 · 9 | 1.628 · 25 | 1.518 · 55 | 1.434 · 168 |
| Operaton | 1.608 · 9 | 1.630 · 26 | 1.494 · 54 | 1.458 · 165 |
| Flowable | 1.904 · 12 | 1.810 · 49 | 1.554 · 120 | 1.415 · 305 |
| Kogito SB | 1.284 · 39 | 1.886 · 57 | 2.210 · 73 | 1.348 · 425 |
| Kogito JVM | 68 · 188 | 185 · 168 | 414 · 136 | 634 · 338 |
| Kogito JVM Kafka | 64 · 181 | 139 · 221 | 254 · 245 | 428 · 301 |
| Kogito Native | 77 · 148 | 208 · 131 | 374 · 169 | 522 · 406 |
| Kogito Native Kafka | 70 · 160 | 160 · 178 | 298 · 200 | 546 · 235 |
| Camunda 8 | 551 · 52 | 687 · 81 | 751 · 148 | 768 · 252 |

**Start, Scale-out, RAM** (je Pod)

| Engine | Start 1. Pod | Scale-out +1 Pod | RAM Leerlauf | RAM unter Last (max) |
|---|---:|---:|---:|---:|
| CIB seven | 9,9–10,1 s | 9,0 s | 248–256 MiB | 439 MiB |
| Operaton | 9,7–10,7 s | 8,9–10,0 s | 247–268 MiB | 443 MiB |
| Flowable | 8,7–8,8 s | 7,8–7,9 s | 189–211 MiB | 339 MiB |
| Kogito SB | 11,1–12,2 s | 10,1–11,0 s | 225–231 MiB | 595 MiB |
| Kogito JVM | 5,1–6,0 s | 5,0–6,2 s | 146–156 MiB | 308 MiB |
| Kogito JVM Kafka | 4,1–5,2 s | 3,9–4,1 s | 151–158 MiB | 1499 MiB |
| Kogito Native | 2,0–3,0 s | 1,9–3,0 s | 19–22 MiB | 132 MiB |
| Kogito Native Kafka | 2,0–3,0 s | 2,0 s | 27–31 MiB | 1172 MiB |
| Camunda 8 | 21,9–33,6 s | – (alle Broker zugleich) | 484–496 MiB | 1970 MiB |

Start = bis der erste Pod bereit ist, Scale-out = bis ein weiterer Pod bereit ist (je Replica-Stufe gemessen).
Camunda 8 startet alle Broker gleichzeitig; die Startwerte gelten für 1/2/3 Broker. RAM laut `kubectl top`.

## Ergebnisse Szenario A ohne History

Versuchsprotokoll mit Aufbau, Prüfung und Erkenntnissen: [versuche/2026-11-16-ohne-history.md](versuche/2026-11-16-ohne-history.md).

Lauf vom 16.11.2026 mit `--history none`, sonst wie oben (Kafgres 4 CPU, Replicas 1/2/3, 60 s Aufwärmen + 60 s
Messung). Gespeichert wird nur der Laufzeitzustand, Einstellungen siehe Offenlegung. Rohdaten in
`results/history-none/<engine>.jsonl`. ⚠ wie oben.

¹ Flowable mit `history-level: activity`, nicht none (siehe Offenlegung).
² Camunda 8 ohne Secondary Storage und ohne Webapps (Profil `broker`); mit History liefen Operate/Tasklist im Pod mit.

**1 Replica** – Durchsatz/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 1.661 · 37 | 1.686 · 54 | 1.647 · 88 | 1.663 · 111 |
| Operaton | 1.369 · 70 | 1.481 · 80 | 1.364 · 93 | 1.299 · 184 |
| Flowable ¹ | 674 · 49 | 599 · 89 | 532 · 202 | 495 · 499 |
| Kogito SB | 925 · 70 | 908 · 84 | 891 · 103 | 758 · 287 |
| Kogito JVM | 1.620 · 60 | 1.781 · 72 | 1.863 · 81 | 1.804 · 96 |
| Kogito JVM Kafka | 470 · 28 | 582 · 3 ⚠ 3 % ok | 23 · 3.593 ⚠ | 47 · 3.504 ⚠ |
| Kogito Native | 977 · 69 | 1.372 · 80 | 1.351 · 90 | 1.263 · 112 |
| Kogito Native Kafka | 505 · 23 | 30 · 1.200 | 37 · 2.403 ⚠ | 49 · 3.304 ⚠ |
| Camunda 8 ² | 290 · 74 | 282 · 127 | 326 · 182 | 2.693 · 87 ⚠ 3 % ok |

**2 Replicas** – Durchsatz/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 2.607 · 16 | 2.754 · 41 | 3.137 · 52 | 3.438 · 74 |
| Operaton | 2.319 · 21 | 2.519 · 44 | 2.630 · 65 | 2.656 · 94 |
| Flowable ¹ | 1.163 · 38 | 1.170 · 65 | 1.180 · 124 | 1.101 · 309 |
| Kogito SB | 1.773 · 36 | 1.846 · 64 | 1.768 · 85 | 1.670 · 198 |
| Kogito JVM | 2.707 · 6 | 2.654 · 45 | 3.112 · 51 | 3.036 · 81 |
| Kogito JVM Kafka | 491 · 27 | 1.080 · 33 | 31 · 4.193 ⚠ | 33 · 8.577 ⚠ |
| Kogito Native | 2.409 · 10 | 2.747 · 49 | 3.035 · 65 | 3.090 · 86 |
| Kogito Native Kafka | 511 · 24 | 1.171 · 28 | 47 · 2.630 ⚠ | 52 · 2.905 ⚠ |
| Camunda 8 ² | 490 · 54 | 572 · 84 | 643 · 163 | 667 · 222 |

**3 Replicas** – Durchsatz/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 3.248 · 8 | 3.934 · 22 | 4.620 · 34 | 4.601 · 63 |
| Operaton | 2.989 · 8 | 3.319 · 25 | 3.668 · 48 | 3.522 · 75 |
| Flowable ¹ | 1.894 · 11 | 1.845 · 37 | 1.804 · 82 | 1.592 · 271 |
| Kogito SB | 2.653 · 8 | 2.596 · 37 | 2.732 · 65 | 2.326 · 161 |
| Kogito JVM | 3.332 · 5 | 3.768 · 18 | 3.741 · 44 | 4.612 · 55 |
| Kogito JVM Kafka | 410 · 34 | 806 · 48 | 1.218 · 73 | 32 · 7.847 ⚠ |
| Kogito Native | 3.827 · 6 | 4.552 · 19 | 4.531 · 41 | 4.737 · 63 |
| Kogito Native Kafka | 468 · 29 | 975 · 37 | 668 · 52 ⚠ 96 % ok | 42 · 5.263 ⚠ |
| Camunda 8 ² | 777 · 32 | 876 · 71 | 733 · 178 | 815 · 316 ⚠ 48 % ok |

**Start, Scale-out, RAM** (je Pod)

| Engine | Start 1. Pod | Scale-out +1 Pod | RAM Leerlauf | RAM unter Last (max) |
|---|---:|---:|---:|---:|
| CIB seven | 10,0–12,4 s | 10,0–12,1 s | 251–263 MiB | 427 MiB |
| Operaton | 11,3–11,9 s | 9,8–10,0 s | 249–263 MiB | 425 MiB |
| Flowable ¹ | 8,8–8,9 s | 8,0–8,9 s | 188–205 MiB | 337 MiB |
| Kogito SB | 11,2–12,2 s | 11,0 s | 213–219 MiB | 342 MiB |
| Kogito JVM | 4,1–5,1 s | 4,0–5,0 s | 147–154 MiB | 268 MiB |
| Kogito JVM Kafka | 4,1–6,1 s | 5,0–7,2 s | 147–151 MiB | 1702 MiB |
| Kogito Native | 2,0 s | 1,9–3,0 s | 18–21 MiB | 197 MiB |
| Kogito Native Kafka | 2,0–3,0 s | 2,0 s | 26–29 MiB | 1941 MiB |
| Camunda 8 ² | 14,8–16,0 s | – (alle Broker zugleich) | 413–423 MiB | 2011 MiB |

**Mit gegen ohne History** – bester gültiger Durchsatz/s je Replica-Stufe (über alle VU-Stufen)

| Engine | 1 Replica | 2 Replicas | 3 Replicas |
|---|---:|---:|---:|
| CIB seven | 816 → **1.686** (×2,1) | 1.641 → **3.438** (×2,1) | 1.630 → **4.620** (×2,8) |
| Operaton | 782 → **1.481** (×1,9) | 1.464 → **2.656** (×1,8) | 1.630 → **3.668** (×2,3) |
| Flowable ¹ | 631 → **674** (×1,1) | 1.301 → **1.180** (×0,9) | 1.904 → **1.894** (×1,0) |
| Kogito SB | 750 → **925** (×1,2) | 1.152 → **1.846** (×1,6) | 2.210 → **2.732** (×1,2) |
| Kogito JVM | 352 → **1.863** (×5,3) | 423 → **3.112** (×7,4) | 634 → **4.612** (×7,3) |
| Kogito JVM Kafka | 483 → **470** (×1,0) | 577 → **1.080** (×1,9) | 428 → **1.218** (×2,8) |
| Kogito Native | 256 → **1.372** (×5,4) | 555 → **3.090** (×5,6) | 522 → **4.737** (×9,1) |
| Kogito Native Kafka | 349 → **505** (×1,4) | 617 → **1.171** (×1,9) | 546 → **975** (×1,8) |
| Camunda 8 ² | 291 → **326** (×1,1) | 516 → **667** (×1,3) | 768 → **876** (×1,1) |

Der Vergleich nimmt je Stufe den höchsten Durchsatz aller VU-Stufen ohne ⚠; die beiden Werte können aus
verschiedenen VU-Stufen stammen. Kogito Native Kafka bei 1 Replica × 25 VUs (30/s, p95 1,2 s) ist formal gültig,
aber schon der Einbruch.

## Kogito Kafka mit Iterator-Fix

Versuchsprotokoll: [versuche/2026-11-16-iterator-fix.md](versuche/2026-11-16-iterator-fix.md).

Die beiden Kafka-Varianten mit korrigierter `KafkaProcessInstances` (RocksDB-Iteratoren geschlossen, siehe
Erkenntnisse) am 16./17.11.2026 komplett nachgemessen, mit und ohne History, sonst wie die Hauptläufe. „Wie
ausgeliefert“ sind die Werte aus den Tabellen oben (Kogito 10.2.0 unverändert). Rohdaten in
`results/history-full-iterfix/` und `results/history-none-iterfix/`. ⚠ wie oben.
Images: `bench-kogito-{jvm,native}-kafka:1.0.0` enthalten seitdem den Fix (aus `apps/kogito-kafka`), die
ausgelieferte Fassung liegt lokal als `:1.0.0-original`.

#### Mit History

**1 Replica** – Durchsatz/s · p95 ms

| Variante | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, wie ausgeliefert | 66 · 182 | 253 · 132 | 483 · 128 | 23 · 5.925 ⚠ |
| Kogito JVM Kafka, mit Fix | 70 · 159 | 257 · 131 | 468 · 149 | 516 · 240 |
| Kogito Native Kafka, wie ausgeliefert | 64 · 176 | 206 · 191 | 349 · 182 | 1.374 · 224 ⚠ 10 % ok |
| Kogito Native Kafka, mit Fix | 65 · 174 | 277 · 113 | 479 · 133 | 507 · 228 |

**2 Replicas** – Durchsatz/s · p95 ms

| Variante | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, wie ausgeliefert | 70 · 161 | 169 · 168 | 403 · 156 | 577 · 218 |
| Kogito JVM Kafka, mit Fix | 71 · 167 | 180 · 153 | 429 · 143 | 642 · 200 |
| Kogito Native Kafka, wie ausgeliefert | 74 · 146 | 170 · 171 | 415 · 156 | 617 · 237 |
| Kogito Native Kafka, mit Fix | 72 · 153 | 177 · 155 | 416 · 144 | 386 · 431 |

**3 Replicas** – Durchsatz/s · p95 ms

| Variante | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, wie ausgeliefert | 64 · 181 | 139 · 221 | 254 · 245 | 428 · 301 |
| Kogito JVM Kafka, mit Fix | 70 · 156 | 167 · 166 | 316 · 176 | 585 · 208 |
| Kogito Native Kafka, wie ausgeliefert | 70 · 160 | 160 · 178 | 298 · 200 | 546 · 235 |
| Kogito Native Kafka, mit Fix | 69 · 161 | 157 · 180 | 289 · 195 | 518 · 258 |

**RAM unter Last (max je Pod)**

| Variante | 1 Replica | 2 Replicas | 3 Replicas |
|---|---:|---:|---:|
| Kogito JVM Kafka, wie ausgeliefert | 1.499 MiB | 1.229 MiB | 706 MiB |
| Kogito JVM Kafka, mit Fix | 325 MiB | 280 MiB | 267 MiB |
| Kogito Native Kafka, wie ausgeliefert | 937 MiB | 1.172 MiB | 677 MiB |
| Kogito Native Kafka, mit Fix | 290 MiB | 144 MiB | 70 MiB |

#### Ohne History

**1 Replica** – Durchsatz/s · p95 ms

| Variante | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, wie ausgeliefert | 470 · 28 | 582 · 3 ⚠ 3 % ok | 23 · 3.593 ⚠ | 47 · 3.504 ⚠ |
| Kogito JVM Kafka, mit Fix | 547 · 21 | 1.408 · 20 | 2.370 · 40 | 2.260 · 84 |
| Kogito Native Kafka, wie ausgeliefert | 505 · 23 | 30 · 1.200 | 37 · 2.403 ⚠ | 49 · 3.304 ⚠ |
| Kogito Native Kafka, mit Fix | 528 · 23 | 1.376 · 23 | 1.628 · 68 | 1.609 · 98 |

**2 Replicas** – Durchsatz/s · p95 ms

| Variante | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, wie ausgeliefert | 491 · 27 | 1.080 · 33 | 31 · 4.193 ⚠ | 33 · 8.577 ⚠ |
| Kogito JVM Kafka, mit Fix | 519 · 25 | 1.176 · 30 | 1.628 · 45 | 3.934 · 49 |
| Kogito Native Kafka, wie ausgeliefert | 511 · 24 | 1.171 · 28 | 47 · 2.630 ⚠ | 52 · 2.905 ⚠ |
| Kogito Native Kafka, mit Fix | 518 · 25 | 1.215 · 29 | 2.040 · 38 | 2.947 · 58 |

**3 Replicas** – Durchsatz/s · p95 ms

| Variante | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| Kogito JVM Kafka, wie ausgeliefert | 410 · 34 | 806 · 48 | 1.218 · 73 | 32 · 7.847 ⚠ |
| Kogito JVM Kafka, mit Fix | 450 · 31 | 910 · 39 | 1.427 · 53 | 2.556 · 60 |
| Kogito Native Kafka, wie ausgeliefert | 468 · 29 | 975 · 37 | 668 · 52 ⚠ 96 % ok | 42 · 5.263 ⚠ |
| Kogito Native Kafka, mit Fix | 472 · 30 | 1.347 · 28 | 2.447 · 32 | 2.583 · 68 |

**RAM unter Last (max je Pod)**

| Variante | 1 Replica | 2 Replicas | 3 Replicas |
|---|---:|---:|---:|
| Kogito JVM Kafka, wie ausgeliefert | 766 MiB | 1.454 MiB | 1.702 MiB |
| Kogito JVM Kafka, mit Fix | 324 MiB | 326 MiB | 321 MiB |
| Kogito Native Kafka, wie ausgeliefert | 572 MiB | 1.350 MiB | 1.941 MiB |
| Kogito Native Kafka, mit Fix | 330 MiB | 311 MiB | 162 MiB |

Mit Fix keine Stufe unter 99 % korrekt, kein p95 über 0,5 s, Speicher höchstens 330 MiB pro Pod (ausgeliefert bis
1.941 MiB); 14 von 48 Stufen waren ausgeliefert nicht verwertbar. Mit History bestimmt unterhalb von 100 VUs das
Warten auf die Event-Bestätigung den Takt, daher kaum Unterschied. Ohne History wird JVM Kafka mit 1 Pod zur
schnellsten Kogito-Variante (2.370/s gegen 1.863/s mit JDBC).

## Ergebnisse Szenario C (History voll)

Versuchsprotokoll: [versuche/2026-11-17-szenario-c-dmn.md](versuche/2026-11-17-szenario-c-dmn.md).

Lauf vom 17.11.2026, Aufbau wie Szenario A: Kafgres 4 CPU, jeder Engine-Pod 1 CPU / 2 GB, Replicas 1/2/3, je Stufe
60 s Messung nach 60 s Aufwärmen. Rohdaten in `results/scenario-c-history-full/<engine>.jsonl`. ⚠ wie oben.
¹ mit Iterator-Fix; verglichen wird mit deren Nachmessung, nicht mit den ausgelieferten Werten.

**1 Replica** – Durchsatz/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 81 · 196 | 73 · 596 | 76 · 1.207 | 78 · 2.512 ⚠ |
| Operaton | 423 · 73 | 418 · 100 | 367 · 277 | 245 · 902 |
| Flowable | 345 · 80 | 290 · 178 | 227 · 487 | 233 · 1.002 |
| Kogito SB | 457 · 85 | 602 · 93 | 523 · 194 | 434 · 484 |
| Kogito JVM | 96 · 125 | 272 · 136 | 276 · 224 | 279 · 387 |
| Kogito Native | 93 · 120 | 220 · 173 | 246 · 251 | 248 · 452 |
| Kogito JVM Kafka ¹ | 80 · 144 | 328 · 96 | 581 · 102 | 562 · 217 |
| Kogito Native Kafka ¹ | 77 · 147 | 304 · 105 | 439 · 154 | 473 · 267 |
| Camunda 8 | 215 · 92 | 280 · 122 | 381 · 313 ⚠ | 1.787 · 103 ⚠ |

**2 Replicas** – Durchsatz/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 193 · 132 | 170 · 406 | 170 · 960 | 156 · 2.286 ⚠ |
| Operaton | 688 · 36 | 740 · 69 | 708 · 180 | 562 · 581 |
| Flowable | 746 · 60 | 636 · 99 | 499 · 340 | 504 · 735 |
| Kogito SB | 1.162 · 53 | 1.180 · 70 | 1.130 · 121 | 1.128 · 296 |
| Kogito JVM | 103 · 106 | 250 · 110 | 478 · 176 | 535 · 330 |
| Kogito Native | 100 · 109 | 237 · 116 | 443 · 174 | 472 · 396 |
| Kogito JVM Kafka ¹ | 89 · 123 | 219 · 127 | 537 · 112 | 492 · 330 |
| Kogito Native Kafka ¹ | 88 · 128 | 217 · 127 | 542 · 108 | 798 · 150 |
| Camunda 8 | 333 · 80 | 401 · 149 | 480 · 215 | 1.238 · 270 ⚠ |

**3 Replicas** – Durchsatz/s · p95 ms

| Engine | 10 VUs | 25 VUs | 50 VUs | 100 VUs |
|---|---:|---:|---:|---:|
| CIB seven | 263 · 103 | 245 · 380 | 246 · 866 | 255 · 1.724 |
| Operaton | 814 · 20 | 818 · 51 | 862 · 96 | 881 · 325 |
| Flowable | 1.144 · 29 | 1.006 · 84 | 803 · 271 | 704 · 667 |
| Kogito SB | 1.699 · 23 | 1.287 · 84 | 1.673 · 76 | 1.648 · 264 |
| Kogito JVM | 102 · 107 | 259 · 106 | 538 · 100 | 801 · 204 |
| Kogito Native | 103 · 106 | 260 · 104 | 527 · 104 | 761 · 218 |
| Kogito JVM Kafka ¹ | 85 · 132 | 192 · 154 | 369 · 156 | 594 · 213 |
| Kogito Native Kafka ¹ | 83 · 134 | 189 · 153 | 336 · 179 | 576 · 230 |
| Camunda 8 | 392 · 72 | 458 · 135 | 641 · 199 | 695 · 252 |

Camunda 8 bei 3 Replicas × 100 VUs: 99,8 % korrekt, knapp über der Grenze.

**Bester gültiger Durchsatz je Replica-Stufe, Szenario A → C** (wie oben: höchster Wert aller VU-Stufen ohne ⚠)

| Engine | 1 Replica | 2 Replicas | 3 Replicas |
|---|---:|---:|---:|
| CIB seven | 816 → **81** (×0,10) | 1.641 → **193** (×0,12) | 1.630 → **263** (×0,16) |
| Operaton | 782 → **423** (×0,54) | 1.464 → **740** (×0,51) | 1.630 → **881** (×0,54) |
| Flowable | 631 → **345** (×0,55) | 1.301 → **746** (×0,57) | 1.904 → **1.144** (×0,60) |
| Kogito SB | 750 → **602** (×0,80) | 1.152 → **1.180** (×1,02) | 2.210 → **1.699** (×0,77) |
| Kogito JVM | 352 → **279** (×0,79) | 423 → **535** (×1,26) | 634 → **801** (×1,26) |
| Kogito Native | 256 → **248** (×0,97) | 555 → **472** (×0,85) | 522 → **761** (×1,46) |
| Kogito JVM Kafka ¹ | 516 → **581** (×1,13) | 642 → **537** (×0,84) | 585 → **594** (×1,01) |
| Kogito Native Kafka ¹ | 507 → **473** (×0,93) | 416 → **798** (×1,92) | 518 → **576** (×1,11) |
| Camunda 8 | 291 → **280** (×0,96) | 516 → **480** (×0,93) | 768 → **695** (×0,91) |

**RAM pro Pod**, höchster Wert unter Last, Szenario A → C

| Engine | 1 Replica | 2 Replicas | 3 Replicas | Leerlauf, 1 Replica |
|---|---:|---:|---:|---:|
| CIB seven | 439 → 506 MiB | 428 → 486 MiB | 393 → 467 MiB | 248 → 259 MiB |
| Operaton | 443 → 479 MiB | 432 → 456 MiB | 403 → 411 MiB | 268 → 265 MiB |
| Flowable | 339 → 366 MiB | 316 → 352 MiB | 328 → 358 MiB | 203 → 214 MiB |
| Kogito SB | 582 → 495 MiB | 595 → 619 MiB | 579 → 615 MiB | 230 → 251 MiB |
| Kogito JVM | 308 → 367 MiB | 293 → 328 MiB | 277 → 298 MiB | 153 → 169 MiB |
| Kogito Native | 132 → 131 MiB | 98 → 80 MiB | 76 → 75 MiB | 22 → 23 MiB |
| Kogito JVM Kafka ¹ | 325 → 379 MiB | 280 → 343 MiB | 267 → 301 MiB | 153 → 176 MiB |
| Kogito Native Kafka ¹ | 290 → 266 MiB | 144 → 131 MiB | 70 → 89 MiB | 30 → 33 MiB |
| Camunda 8 | 1.920 → 1.709 MiB | 1.846 → 1.785 MiB | 1.970 → 1.567 MiB | 484 → 499 MiB |

## Erkenntnisse

Was beim Aufbau und Messen gefunden wurde, mit dem Weg dahin. „Nicht geprüft“ heißt: Vermutung, nicht gemessen.

**Datenbank als Grenze (CIB seven, Operaton)**
- Lauf mit Kafgres auf 2 CPU: CIB seven und Operaton kamen ab 2 Replicas nicht über ca. 730–950/s hinaus.
  Diagnose bei 4 Replicas × 50 VUs (`pg_stat_activity` 2× pro Sekunde, `kubectl top`, `pg_stat_user_tables`):
  Kafgres 1.985–1.992m von 2.000m CPU, Engine-Pods nur 330–500m von 1.000m. Wartegründe der aktiven Verbindungen:
  ≈ 62 % `LWLock: BufferContent` (Gerangel um dieselben Seiten bei INSERT/UPDATE auf `ACT_HI_ACTINST` und
  `ACT_HI_DETAIL`), ≈ 20 % CPU, ≈ 12 % WAL beim COMMIT, **0 echte Zeilensperren**. Keine Sperre zwischen den Replicas,
  sondern zu viel Schreibarbeit für 2 Kerne.
- Ursache der Schreibarbeit: die Removal Time der History-Bereinigung (Strategie `end`, Standard). Am Prozessende
  `UPDATE … set REMOVAL_TIME_` in 15 History-Tabellen, jede der 11 History-Zeilen pro Instanz wird eingefügt und
  gleich wieder geändert (INSERTs = UPDATEs je Tabelle). Flowable schreibt mehr Zeilen (15), ändert sie aber nicht.
  Standard belassen; mit `history-removal-time-strategy: start` fielen die UPDATEs weg (nicht gemessen).
- Mit Kafgres auf 4 CPU: CIB seven 806 → 1.532 → 1.630/s bei 1/2/3 Replicas (10 VUs), Operaton ähnlich. Von 2 auf
  3 Replicas kaum Zuwachs; dass wieder die Datenbank die Grenze ist, ist nicht geprüft.
- Flowable skaliert im selben Lauf fast linear (631 → 1.301 → 1.904/s bei 10 VUs) und liegt mit 3 Replicas vorn;
  bei 1 Replica ist es die langsamste der drei. Kogito SB erreicht mit 3 Replicas × 50 VUs den Höchstwert des
  Laufs (2.210/s), bei 100 VUs fällt es auf 1.348/s zurück (nicht geprüft, warum).

**Kogito Quarkus: Ausfälle unter Last**
- Bild: je nach Stufe 0 % korrekte Antworten, Hänger bis 60 s (Timeout) oder zehntausende schnelle Fehler pro
  Sekunde; sprunghaft, nicht mit der Last steigend. Alle vier Quarkus-Varianten, Kogito SB nicht.
- Erster Befund: Der SmallRye-Producer lief mit `acks=1` ohne Idempotenz (Kogito SB: `acks=all`, idempotent). Kafgres
  beantwortete damit manche Schreibanfragen nie (`REQUEST_TIMED_OUT`, Kafgres dabei fast ohne CPU-Last). Auf
  `acks=all` + Idempotenz umgestellt. **Das reichte nicht:** Der nächste volle Lauf zeigte dieselben Ausfälle (ein
  kurzer Test mit 1 Replica und zwei Laststufen hatte das nicht aufgedeckt).
- Eigentliche Ursache (Pod-Status, Health, Speicher alle 3 s, GC-Log, Heap-Histogramm mit `jcmd`): keine
  Pod-Neustarts, kein OOMKilled, Readiness immer `UP`. Aber der Heap (494 MB = 25 % von 2 GiB) lief voll:
  24 MB → 327 MB → 494 MB in rund 80 s, danach eine Full GC nach der anderen (je ≈ 0,5 s). Im Heap wartende
  Event-Nachrichten 38.856 → 291.143 in 40 s, erzeugt von Kogitos `ReactiveMessageEmitter`. Die Events kommen in
  Kafgres vollständig an (≈ 16 pro Instanz), nur langsamer, als Kogito sie erzeugt; der Standard „abschicken und
  vergessen“ puffert ohne Grenze.
- Abhilfe: `kogito.events.processinstances.errors.propagate=true` (blockierender Versand). Test mit 1 Replica:
  Kogito JVM 329/s, p95 96 ms, Speicher stabil bei ≈ 236 Mi; Kogito Native 272/s, stabil bei ≈ 70 Mi; jeweils
  100 % korrekt.
- Folge im vollen Lauf: alle vier Varianten fast überall 100 % korrekt, aber an die Wartezeit gebunden. Bei 10 VUs
  schaffen alle vier nur 64–79/s (p50 ≈ 130 ms pro Request), egal ob 1, 2 oder 3 Replicas. Der Durchsatz steigt mit
  den VUs (bis ≈ 630/s), nicht mit den Replicas: Die Pods warten, statt zu rechnen. Die Werte zeigen damit vor allem,
  wie schnell Kafgres Kafka-Schreibanfragen bestätigt, nicht die Engine. Warum eine Bestätigung so lange dauert
  (z. B. ein Sammelintervall in Kafgres), ist nicht geprüft; ebenso nicht, ob die ≈ 16 Events pro Instanz
  nacheinander gesendet werden.
- Zum Vergleich: Im allerersten Lauf (anderer Aufbau, Events abschicken und vergessen) lag Kogito JVM bei rund
  1.800/s mit 1 Replica. Das ging nur, weil niemand auf die Events wartete, und hielt unter Dauerlast nicht.
- **Die beiden Kafka-Varianten** wachsen auch mit blockierendem Versand weiter: Kogito JVM Kafka bis 1.499 MiB pro
  Pod (1 Replica, 50 VUs), danach bei 100 VUs Einbruch auf 23/s mit p95 5,9 s; Kogito Native Kafka bis 1.172 MiB,
  bei 1 Replica × 100 VUs nur 10 % korrekte Antworten. Mit mehr Replicas verteilt sich die Last und es reicht.
  Ein zweiter Speicherfresser, vermutlich die Kafka-Streams-Persistenz; nicht geprüft. Die JDBC-Varianten bleiben
  unter 310 MiB (JVM) bzw. 132 MiB (Native).

**Kogito Quarkus im Quellcode (Kogito 10.2.0, Source-JARs aus Maven Central) und Nachtests am 16.11.2026**
- Event-Versand (`AbstractMessagingEventPublisher`, `ReactiveMessagingEventPublisher`): Standard ist **ein
  Kafka-Datensatz pro Event, nacheinander**. Mit `errors.propagate=true` wartet `sendMessageAndAwait` bei jedem
  der ≈ 16 Events einer Instanz auf die Bestätigung, bevor das nächste rausgeht. Dazu wartet der Kafka-Client 4.0
  vor jedem Senden standardmäßig `linger.ms` = 5 ms. 16 × (5 ms + Bestätigung) passt zum festen Sockel von
  ≈ 100–130 ms pro Request. Kogito kennt `kogito.events.grouping=true` (`GroupingMessagingEventPublisher`): alle
  Events einer Transaktion als **ein** Datensatz (`MultipleProcessInstanceDataEvent`, anderes Nachrichtenformat
  für Empfänger). Der Kanal ist ausdrücklich mit `@OnOverflow(UNBOUNDED_BUFFER)` deklariert, das erklärt den
  unbegrenzten Puffer beim Standard „abschicken und vergessen“.
  - Bestätigt in Kafgres (`kafgres_producer_batches.appended_at`): Die Events einer Instanz kommen einzeln im
    Abstand von ≈ 12 ms an, 16 Datensätze pro Instanz.
  - Nachtest Kogito JVM, mit History, 1 Replica, `kogito.events.grouping=true` (als Umgebungsvariable): 1 Datensatz
    pro Instanz, alle Antworten korrekt, Speicher ≤ 258 MiB. Zwei Läufe:

    | VUs | ohne Bündelung (Hauptlauf) | mit Bündelung, Lauf 1 | Lauf 2 |
    |---:|---:|---:|---:|
    | 10 | 77/s · p50 ≈ 128 ms | 461/s · p50 17 ms | 511/s · p50 12 ms |
    | 25 | 326/s · p95 121 ms | 919/s · p95 56 ms | 680/s · p95 61 ms |
    | 50 | 352/s · p95 201 ms | 913/s · p95 88 ms | 652/s · p95 126 ms |

    Der Sockel verschwindet, Kogito wird 3- bis 6-mal so schnell. Die zwei Läufe streuen bei 25/50 VUs stark (nicht
    geprüft, warum; Lauf 1 kurz vor einem Docker-Absturz). Für die Hauptläufe **nicht** übernommen, weil sich das
    Nachrichtenformat ändert.
- Kafka-Persistenz (`KafkaProcessInstances`, `KafkaPersistenceUtils`):
  - Der Zustand liegt in einer **GlobalKTable** (`kogito-store`, RocksDB): Jede Replica liest das ganze Topic
    `kogito.process` in ihren eigenen Store, mit einem einzigen Global-Thread. Mehr Replicas teilen sich also nicht
    die Arbeit, jede macht alle.
  - Jede Schreibaktion wartet synchron (`producer.send(...).get()`); pro beendeter Instanz zwei Datensätze
    (Löschmarker + Event-Liste).
  - Alle Instanzen eines Prozesses teilen sich **einen** Schlüssel `events-<Prozess-ID>` mit der Liste ihrer
    Wartezustände. Er wird pro Instanz gelesen, geändert und ganz neu geschrieben: alles auf einer Partition, und
    gleichzeitige Requests überschreiben sich gegenseitig.
  - **`clearEventTypes` und `waitingForEventType` öffnen per `prefixScan` einen RocksDB-Iterator und schließen ihn
    nie.** `clearEventTypes` läuft bei jeder beendeten Instanz. Offene RocksDB-Iteratoren halten nativen Speicher
    (außerhalb des Java-Heaps) fest. **Als Ursache des Einbruchs belegt:** Nachtest Kogito JVM Kafka, mit History,
    1 Replica, direkt nacheinander mit dem Original und mit einer korrigierten Kopie der Klasse
    (`apps/kogito-kafka/src/main/java/org/kie/kogito/persistence/kafka/KafkaProcessInstances.java`, Iteratoren per
    try-with-resources geschlossen; laut Class-Loading-Log lädt die JVM die Kopie aus dem App-JAR):

    | VUs | Original | RAM | mit Fix | RAM |
    |---:|---:|---:|---:|---:|
    | 10 | 68/s · p95 169 ms | 274 MiB | 66/s · p95 169 ms | 218 MiB |
    | 25 | 298/s · p95 106 ms | 873 MiB | 328/s · p95 94 ms | 239 MiB |
    | 50 | 489/s · p95 129 ms | 1.620 MiB | 581/s · p95 103 ms | 271 MiB |
    | 100 | **25/s · p95 5.603 ms ⚠**, 1 Neustart **OOMKilled** | 306 MiB | **571/s · p95 219 ms** | 322 MiB |

    Der Fehler steckt auch im aktuellen `main` von `apache/incubator-kie-kogito-runtimes` (Datei unverändert seit
    05/2025); ein Issue oder PR dazu gibt es nicht (gesucht in `incubator-kie-issues` und `kogito-runtimes`, nicht im
    alten Red-Hat-Jira). Die Hauptläufe sind mit dem Original gemessen; vollständige Nachmessung mit Fix im Abschnitt
    „Kogito Kafka mit Iterator-Fix“ (wirkt auch im Native-Image: Speicher bleibt flach).
  - `remove` wartet nach dem Löschen in einer Schleife mit `Thread.sleep(100)`, bis der Store die Löschung zeigt.

**Ohne History**
- CIB seven und Operaton schaffen ohne History etwa das Doppelte und skalieren jetzt auch mit der dritten Replica
  weiter (CIB seven 1.686 → 3.438 → 4.620/s). Mit History lagen beide ab 2 Replicas bei rund 1.600/s. Die
  History-Schreibarbeit in Kafgres war also die Grenze, nicht die Engine. Ohne History liegt CIB seven durchgehend
  15–25 % vor Operaton; mit History lagen beide gleichauf. Warum, ist nicht geprüft.
- Kogito JVM und Native mit JDBC werden 5- bis 9-mal so schnell (bis 4.612 bzw. 4.737/s mit 3 Replicas) und
  skalieren sauber. Mit History bremste sie das Warten auf die Kafka-Bestätigung von Kafgres (≈ 130 ms pro Request,
  siehe oben), nicht die Engine.
- Kogito JVM Kafka und Native Kafka brechen auch ohne Events ein: bei 1 Replica schon ab 25 VUs, bei 3 Replicas
  ab 50–100 VUs (23–52/s, p95 2,4–8,6 s). Speicher bis 1,7 bzw. 1,9 GiB pro Pod, danach fällt er plötzlich auf
  ≈ 250 MiB (vermutlich Pod-Neustart, nicht geprüft). Damit liegt das Problem bei der Kafka-Persistenz selbst, nicht beim Event-Versand.
  Ursache inzwischen belegt: der nicht geschlossene RocksDB-Iterator in Kogito (OOMKilled), siehe oben; mit Fix
  bis 2.370/s bei 1 Pod.
- Kogito SB gewinnt 20–60 %, Camunda 8 10–30 %, Flowable mit `activity` nichts (es schreibt weiter 11 History-Zeilen
  pro Instanz, nur die 4 Änderungsdetails fallen weg).
- Camunda 8 hat bei 3 Brokern × 100 VUs nur 48 % korrekte Antworten (mit History: 100 %). Ursache nicht geprüft.

**Camunda 8**
- 1 Broker bei 100 VUs: 97 % der Antworten sind schnelle Fehler (2.153 Antworten/s, davon 3 % korrekt). Vermutlich
  der eingebaute Überlastschutz (Backpressure) von Zeebe; nicht geprüft. Ab 2 Brokern 100 % korrekt.
- RAM unter Last 1,6–1,97 GiB von 2 GiB pro Broker, also nah am Limit.
- Kurztest am 17.11.2026, Szenario A mit History, **1 Broker mit allen freien Ressourcen**: 3,5 CPU / 8 GiB statt
  1 CPU / 2 GiB, Kafgres weiter 4 CPU, Zeebe-Einstellungen auf Standard
  (`ENGINE_CPU=3500m ENGINE_MEM=8Gi RUN_TAG=c8max ./scenario-a.sh --replicas 1 camunda8`, Rohdaten
  `results/history-full-c8max/`):

  | VUs | 1 CPU / 2 GiB (Hauptlauf) | 3,5 CPU / 8 GiB | RAM |
  |---:|---:|---:|---:|
  | 10 | 245/s · p95 86 ms | 537/s · p95 24 ms | 2.210 MiB |
  | 25 | 275/s · p95 118 ms | 554/s · p95 52 ms | 1.670 MiB |
  | 50 | 291/s · p95 199 ms | 554/s · p95 101 ms | 3.536 MiB |
  | 100 | ⚠ 3,5 % korrekt | ⚠ 5,5 % korrekt (5.940 Antworten/s) | 5.344 MiB |

  3,5-mal so viel CPU bringt etwa den doppelten Durchsatz, danach eine feste Grenze bei ≈ 554/s: Mehr VUs
  verlängern nur die Wartezeit (p50 18 → 44 → 89 ms). Bei 100 VUs bleibt der Einbruch, er liegt also nicht am
  1-CPU-Limit. Vermutete Grenze: die eine Partition (ein Broker verarbeitet seine Partition nacheinander) bzw. der
  Überlastschutz; nicht geprüft, ebenso nicht, wie viel der 3,5 CPU Zeebe tatsächlich genutzt hat. Startzeit
  11,6 s statt ≈ 22 s.
- Gleicher Kurztest mit **3 Brokern, die 3,5 CPU gleich verteilt** (je 1.166m / 8 GiB, `RUN_TAG=c8max3`, Rohdaten
  `results/history-full-c8max3/`), diesmal mit CPU-Last aus `kubectl top` (ein Wert nach 90 s je Stufe):

  | VUs | 3 × 1 CPU / 2 GiB (Hauptlauf) | 3 × 1.166m / 8 GiB | CPU je Broker | Kafgres-CPU |
  |---:|---:|---:|---:|---:|
  | 10 | 551/s · p95 52 ms | 500/s · p95 56 ms | 1.021–1.044m | 132m |
  | 25 | 687/s · p95 81 ms | 710/s · p95 77 ms | 1.111–1.115m | 238m |
  | 50 | 751/s · p95 148 ms | 722/s · p95 167 ms | 1.137–1.156m | 198m |
  | 100 | 768/s · p95 252 ms | 719/s · p95 251 ms | 1.131–1.155m | 248m |

  Ab 25 VUs laufen alle drei Broker mit 95–99 % ihres CPU-Limits, Kafgres nutzt höchstens 248m von 4.000m: Die
  Grenze ist die CPU der Broker, nicht die Datenbank. Trotzdem bringen die 17 % mehr CPU pro Broker keinen höheren
  Durchsatz als im Hauptlauf (≈ 720/s gegen ≈ 750/s, im Rahmen der Streuung; warum, nicht geprüft). Alle Stufen
  100 % korrekt, auch bei 100 VUs. Mit denselben 3,5 CPU liefern 3 Broker also ≈ 30 % mehr als 1 Broker (≈ 720
  gegen ≈ 554/s) und brechen bei 100 VUs nicht ein. Partition-Replikation ist 1, jeder Broker arbeitet nur seine
  eigene Partition ab.

**Szenario C: DMN-Tabelle mit 100 Regeln**
- Alle 9 Engines rechnen richtig: In jeder Stufe ohne ⚠ kam bei 100 % der Anfragen genau die Gebühr zurück, die k6
  aus denselben Regeln nachrechnet (einzige Ausnahme Camunda 8 mit 3 Brokern × 100 VUs: 99,8 %).
- **CIB seven fällt auf ein Zehntel** (816 → 81/s bei 1 Replica) und bleibt bei 1 Replica fest bei ≈ 78/s, egal
  wie viele VUs; die p95 wächst mit (bis 2,5 s). Operaton, ebenfalls Camunda-7-Fork mit derselben DMN-Datei, schafft
  423/s. Diagnose am 17.11. (1 Replica, 25 VUs): Engine-Pod 999m von 1.000m CPU, Kafgres nur 252m, also kein
  Datenbank-Engpass. Profil mit dem Java Flight Recorder (623 Stichproben in 40 s): 64 % der CPU-Zeit in
  `org.camunda.feel.FeelEngine.rootContext` → `BuiltinFunctions.<init>`. Die FEEL-Engine baut bei jedem Zellentest
  (bis zu 400 pro Anfrage) ihre ganze Tabelle eingebauter Funktionen neu auf. CIB seven 2.2.0 bringt
  `feel-engine 1.19.3` mit, Operaton 2.2.1 `feel-engine 1.22.1`.
- Quellcode-Vergleich (Source-JARs von Maven Central): In 1.19.3 ist der Grundkontext eine Methode,
  `private def rootContext(): EvalContext = EvalContext.create(… new BuiltinFunctions(clock, valueMapper) …)`, und
  `evaluate` ruft sie bei jeder Auswertung auf. In 1.22.1 ist er ein Feld, `private val rootContext`, einmal beim
  Erzeugen der Engine gebaut und dann wiederverwendet. Das ist der einzige Unterschied in `FeelEngine.scala`. Die
  Korrektur steckt ab **1.19.4** (Patch-Update derselben Reihe) und ab 1.20.1; 1.20.0 hat noch den alten Stand.
- **Gegenmessung belegt es** (17.11.2026, Szenario C, 1 Replica, sonst unverändert): CIB seven mit
  `feel-engine` 1.19.6 statt 1.19.3, sonst gleiches Image (`bench-cibseven:1.0.0-feel1196`, in
  `apps/cibseven/pom.xml` per `dependencyManagement` überschrieben; Aufruf `ENGINE_TAG=1.0.0-feel1196
  RUN_TAG=feel1196 ./scenario-a.sh --replicas 1 --scenario c cibseven`, Rohdaten
  `results/scenario-c-history-full-feel1196/`):

  | VUs | FEEL 1.19.3 (ausgeliefert) | FEEL 1.19.6 | Operaton (FEEL 1.22.1) | CPU Engine · Kafgres (1.19.6) |
  |---:|---:|---:|---:|---:|
  | 10 | 81/s · p95 196 ms | **442/s** · p95 52 ms | 423/s · p95 73 ms | 992m · 1.125m |
  | 25 | 73/s · p95 596 ms | **422/s** · p95 101 ms | 418/s · p95 100 ms | 991m · 1.575m |
  | 50 | 76/s · p95 1.207 ms | **390/s** · p95 244 ms | 367/s · p95 277 ms | 999m · 1.583m |
  | 100 | 78/s · p95 2.512 ms ⚠ | **358/s** · p95 538 ms | 245/s · p95 902 ms | 991m · 1.469m |

  Mit dem Patch-Update wird CIB seven 4,6- bis 5,8-mal so schnell und liegt gleichauf mit Operaton, bei 100 VUs
  sogar vorn. Alle Antworten korrekt. Der Engine-Pod bleibt an seinem 1-CPU-Limit, jetzt aber mit Regelarbeit
  statt Funktionstabellen. Der Einbruch in Szenario C ist also kein Problem von CIB seven selbst, sondern der
  ausgelieferten FEEL-Version. Die Haupttabellen oben bleiben mit dem ausgelieferten Stand (1.19.3); 2 und 3
  Replicas mit 1.19.6 sind nicht gemessen.
- Operaton und Flowable verlieren etwa die Hälfte (×0,5–0,6). Woran genau (Auswertung der Tabelle, History der
  Entscheidung), ist nicht geprüft.
- **Kogito verliert kaum oder wird sogar schneller**: Kogito JVM mit 3 Replicas 634 → 801/s, Native 522 → 761/s.
  Mit History bestimmt bei Kogito Quarkus das Warten auf die Event-Bestätigung den Takt (siehe oben); Szenario C hat
  einen Knoten statt drei und damit vermutlich weniger Events pro Instanz (nicht gezählt). Bei 10 VUs bleibt der
  bekannte Sockel von ≈ 100/s unabhängig von den Replicas.
- Kogito SB liegt mit 3 Replicas vorn (1.699/s), Flowable folgt mit 1.144/s.
- Camunda 8 verliert 4–9 %. Ungültige Stufen schon ab 50 VUs bei 1 Broker (61 % korrekt) und bei 2 Brokern × 100 VUs
  (27 %); in Szenario A nur bei 1 Broker × 100 VUs. Ob wieder Backpressure, ist nicht geprüft (k6 speichert nur
  richtig/falsch, nicht den HTTP-Status).
- Kosten der DMN-Engine im Speicher: Kogito JVM 15–20 MiB mehr im Leerlauf, 20–60 MiB mehr unter Last; Startzeiten
  praktisch gleich (CIB seven und Operaton ≈ 2–3 s länger).

**Aufbau und Messverfahren**
- Ein Lauf im Akkubetrieb wurde ungültig (Mac im Ruhezustand). Seitdem Abbruch ohne Netzteil und `caffeinate`.
- 15 s Aufwärmen waren für frisch gestartete JVMs zu kurz (erste Stufe zu niedrig), jetzt 60 s.
- CIB seven und Operaton haben dieselben `ACT_*`-Tabellennamen: Ohne frische Datenbank startete der Testaufruf von
  CIB seven den Prozess von Operaton. Seitdem startet jeder Testaufruf auf leerer Datenbank.
- Kafgres meldete sich über den lokalen Socket bereit, bevor es per TCP erreichbar war; das Anlegen der Topics im
  Init-Container schlug fehl. Readiness jetzt per TCP.
- Lauf ohne History, erster Testaufruf: Flowable antwortete mit `history-level: none` ohne Variablen (`"variables":[]`,
  aber `ended: true`), weil die REST-API die Variablen beendeter Instanzen aus der History holt. Lösung: `activity`.
  Camunda 8 startete mit `SECONDARYSTORAGE_TYPE=none` nicht (Spring-Fehler beim Operate-JSON-Konverter, fehlender
  `ObjectMapper`); mit Profil `broker` (ohne Webapps) läuft es und antwortet korrekt.
- Zählfehler bei Kafka-Datensätzen in Kafgres: `kafgres_log` und `kafgres_partitions.next_offset` bleiben in
  Kafgres 0.3.1 leer bzw. auf 0, auch wenn Datensätze ankommen. Gezählt wird mit dem High Watermark aus
  `kafgres_partition_offsets('<topic>')`. Die erste Prüfung „Kogito ohne History schickt 0 Events“ lief mit der
  falschen Abfrage und wurde am 16.11. mit der richtigen wiederholt (Ergebnis siehe Offenlegung).
- k6 ohne CPU-Request bekam automatisch 2 CPU reserviert und passte bei 4 Replicas nicht mehr in den Cluster;
  jetzt 250m Request.

## Stand

- [x] Schritt 1: Cluster, Kafgres, Ingress, k6-Rauchtest
- [x] Szenario A aufgebaut: 9 Engines, alle antworten im Testaufruf (`SMOKE_ONLY=1`) korrekt mit `counter = 3`
- [x] Szenario A gemessen, alle 9 Engines, Kafgres 4 CPU, Replicas 1/2/3 (siehe Ergebnisse; der Lauf mit Kafgres
      2 CPU und 1/2/4 ist verworfen)
- [x] Szenario A ohne History gemessen (`--history none`, alle 9 Engines)
- [x] Kogito Kafka mit Iterator-Fix nachgemessen (mit und ohne History)
- [x] Szenario C (DMN-Tabelle, 100 Regeln, COLLECT + SUM) gemessen, alle 9 Engines, History voll
- [x] CIB seven in Szenario C mit `feel-engine` 1.19.6 gegengemessen (1 Replica): Einbruch behoben
- [ ] Offen in Szenario C: Fehlerursache Camunda 8 ab 50 VUs
- [ ] Offen in Szenario A: Wartezeit der Kafka-Bestätigung bei Kogito Quarkus
- [ ] Lastspitze mit Autoscaling
- [ ] Szenario B (KYC über Kafka mit User Task)
- [ ] Ergebnisse an die Animation übergeben

## Lizenz

Apache License 2.0, siehe [LICENSE](LICENSE). `apps/kogito-kafka/src/main/java/org/kie/kogito/persistence/kafka/KafkaProcessInstances.java`
ist eine geänderte Kopie aus Apache KIE (Kogito 10.2.0) und behält ihren Apache-Lizenzkopf.
