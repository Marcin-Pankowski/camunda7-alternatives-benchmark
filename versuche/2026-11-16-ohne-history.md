# Versuch: Szenario A ohne History

**Datum:** 16.11.2026, 13:22–17:39 · **Befehl:** `./scenario-a.sh --db-cpu 4 --replicas 1,2,3 --history none <9 Engines>`
· **Rohdaten:** [results/history-none/](../results/history-none/) · **Vergleichslauf:** mit voller History,
[results/history-full/](../results/history-full/) (15./16.11.2026)

## Frage

Wie viel kostet die History? Im Lauf mit voller History war bei CIB seven und Operaton die Datenbank die Grenze,
und Kogito Quarkus wartete pro Request auf die Kafka-Bestätigung seiner Prozess-Events. Ohne History bleibt nur
das, was die Engine zum Ausführen braucht.

## Aufbau

Gleich wie im Lauf mit History: Kafgres 4 CPU / 2 GB, jeder Engine-Pod 1 CPU / 2 GB, Replicas 1/2/3, k6 mit
10/25/50/100 VUs, je 60 s Aufwärmen + 60 s Messung, jede Replica-Stufe auf leerer Datenbank. Dieselben Images,
die History-Schalter kommen als Umgebungsvariablen aus der ConfigMap `history`.

| Engine | Einstellung | Geprüft: was nach 5 Instanzen in Kafgres steht |
|---|---|---|
| CIB seven, Operaton | `history-level: none` | 0 Zeilen in `act_hi_*` |
| Flowable | `history-level: activity` (**nicht** none) | 5 Prozess-, 45 Aktivitäts-, 5 Variablenzeilen, 0 in `act_hi_detail` |
| Kogito (alle 5) | Prozess-Events aus (`kogito.events.*.enabled=false`) | 0 Prozess-Events, 1 Prozessdefinitions-Event beim Start ¹ |
| Camunda 8 | `CAMUNDA_DATA_SECONDARYSTORAGE_TYPE=none`, Profil `broker` | 0 Tabellen |

¹ Erst mit einer falschen Abfrage gezählt (`kafgres_log` bleibt in Kafgres 0.3.1 leer); mit dem High Watermark aus
`kafgres_partition_offsets()` am 16.11. abends wiederholt (Kogito JVM Kafka). Der Schalter für
Prozessdefinitions-Events greift nicht; für die Messung unerheblich.

## Was beim Aufsetzen schiefging

- **Flowable** antwortete mit `history-level: none` ohne Variablen (`"variables":[]`, aber `ended: true`). Die
  REST-API holt die Variablen beendeter Instanzen aus der History. Entscheidung: `activity`, die kleinste Stufe, mit
  der die Prüfung auf `counter = 3` geht.
- **Camunda 8** startete ohne Secondary Storage nicht: Spring-Fehler beim JSON-Konverter von Operate (fehlender
  `ObjectMapper`). Operate, Tasklist und Identity brauchen den Speicher. Mit Profil `broker` (nur Engine + REST)
  läuft es und antwortet korrekt. Damit fehlen bei `none` auch die Webapps, die bei `full` im Pod mitlaufen.
- Die Kafka-Persistenz der Kafka-Varianten bleibt an: Sie ist der Laufzeitzustand, keine History.

## Ergebnisse

¹ Flowable mit `activity`. ² Camunda 8 ohne Secondary Storage und ohne Webapps.
⚠ = nicht verwertbar (unter 99 % korrekte Antworten oder p95 über 2 s).

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
verschiedenen VU-Stufen stammen.

## Erkenntnisse

1. **Bei CIB seven und Operaton war die History die Grenze.** Ohne History etwa doppelt so schnell, und sie skalieren
   auch mit der dritten Replica weiter (CIB seven 1.686 → 3.438 → 4.620/s). Mit History lagen beide ab 2 Replicas bei
   rund 1.600/s, Kafgres war ausgelastet (Diagnose im README, „Datenbank als Grenze“).
2. **CIB seven ist ohne History 15–25 % schneller als Operaton.** Mit History lagen beide gleichauf, weil beide an
   der Datenbank hingen. Warum, ist nicht geprüft.
3. **Kogito Quarkus mit JDBC ist ohne Events 5- bis 9-mal so schnell** (JVM bis 4.612/s, Native bis 4.737/s mit
   3 Replicas) und skaliert sauber, bei wenig Speicher (JVM ≤ 268 MiB, Native ≤ 197 MiB). Mit History bremste das
   Warten auf die Kafka-Bestätigung von Kafgres (≈ 130 ms pro Request), nicht die Engine.
4. **Die Kafka-Persistenz von Kogito bricht auch ohne Events ein.** JVM Kafka und Native Kafka: bei 1 Replica ab
   25 VUs, bei 3 Replicas ab 50–100 VUs nur noch 23–52/s mit p95 2,4–8,6 s. Speicher bis 1,7 bzw. 1,9 GiB pro Pod,
   dann plötzlich wieder ≈ 250 MiB (vermutlich Pod-Neustart, nicht geprüft). Der Event-Versand ist damit als
   Ursache ausgeschlossen. Nachtest am selben Abend: Ursache ist ein nicht geschlossener RocksDB-Iterator in
   Kogitos `KafkaProcessInstances` (OOMKilled; mit korrigierter Klasse stabil, siehe README „Erkenntnisse“).
5. **Kogito SB gewinnt 20–60 %, Camunda 8 10–30 %.** Kogito SB sendet seine Events offenbar ohne auf jede
   Bestätigung zu warten (nicht geprüft). Camunda 8 schreibt die History ohnehin asynchron über den Exporter.
6. **Flowable gewinnt mit `activity` nichts.** Es schreibt weiter 11 History-Zeilen pro Instanz, nur die
   4 Änderungsdetails fallen weg. Kein fairer Vergleich „ohne History“ für Flowable.
7. **Camunda 8 bei 3 Brokern × 100 VUs: nur 48 % korrekte Antworten** (mit History 100 %). Ursache nicht geprüft.
8. **Startzeiten unverändert** (Camunda 8 schneller, 15–16 s statt 22–34 s, weil die Webapps fehlen).

## Offene Punkte

- ~~Pod-Neustarts / OOMKilled bei den Kogito-Kafka-Varianten prüfen~~ – erledigt: OOMKilled, Ursache offener RocksDB-Iterator (README).
- Flowable wirklich ohne History messen (bräuchte einen eigenen REST-Endpunkt, der `counter` ohne History zurückgibt).
- Fehlerantworten von Camunda 8 bei 3 × 100 VUs ansehen.
