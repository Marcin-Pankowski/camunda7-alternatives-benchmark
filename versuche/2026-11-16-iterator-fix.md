# Versuch: Kogito Kafka mit Iterator-Fix nachgemessen

**Datum:** 16./17.11.2026, 22:23–00:16 · **Befehl:** `RUN_TAG=iterfix ./scenario-a.sh --db-cpu 4 --replicas 1,2,3
--history full|none kogito-jvm-kafka kogito-native-kafka` · **Rohdaten:**
[results/history-full-iterfix/](../results/history-full-iterfix/), [results/history-none-iterfix/](../results/history-none-iterfix/)
· **Vergleich „wie ausgeliefert“:** [results/history-full/](../results/history-full/) (Protokoll
[2026-11-15-mit-history.md](2026-11-15-mit-history.md)), [results/history-none/](../results/history-none/) (Protokoll
[2026-11-16-ohne-history.md](2026-11-16-ohne-history.md))

## Frage

Beide Kogito-Varianten mit Kafka-Persistenz brachen in den Hauptläufen ein (mit History ab 100 VUs, ohne History
schon ab 25–50 VUs), mit Speicher bis 1,9 GiB pro Pod und OOMKilled. Ein Nachtest mit 1 Replica hatte einen nicht
geschlossenen RocksDB-Iterator in Kogitos `KafkaProcessInstances` als Ursache belegt (README, „Erkenntnisse“).
Offen war: Wie sehen die vollständigen Läufe (Replicas 1/2/3, mit und ohne History) mit dem Fix aus, und wirkt die
korrigierte Klasse auch im Native-Image?

## Aufbau

- Gleich wie die Hauptläufe: Kafgres 4 CPU / 2 GB, jeder Engine-Pod 1 CPU / 2 GB, Replicas 1/2/3, k6 mit
  10/25/50/100 VUs, je 60 s Aufwärmen + 60 s Messung, jede Replica-Stufe auf leerer Datenbank.
- Einziger Unterschied: `apps/kogito-kafka` enthält eine Kopie von
  `org.kie.kogito.persistence.kafka.KafkaProcessInstances` (Kogito 10.2.0), in der beide `prefixScan`-Iteratoren
  per try-with-resources geschlossen werden. Gleicher Klassenname, daher ersetzt sie die Klasse aus dem Addon.
  Geprüft: Die Klasse liegt im App-JAR; die JVM lädt sie laut Class-Loading-Log von dort (Nachtest vom 16.11.).
- Images `bench-kogito-jvm-kafka:1.0.0` und `bench-kogito-native-kafka:1.0.0` mit dem Fix neu gebaut. Die
  ausgelieferten Images liegen als `:1.0.0-original` daneben.
- Neu in `bench.sh`: `RUN_TAG=<tag>` schreibt nach `results/history-<stufe>-<tag>/`, damit die Hauptläufe
  unangetastet bleiben.

## Was beim Aufsetzen schiefging

- Die Kette brach einmal nach erfolgreichem Build ab, weil meine eigene Prüfung falsch war: `unzip -l … | grep -q`
  unter `set -o pipefail` meldet einen Fehler, sobald `grep` nach dem ersten Treffer aufhört zu lesen (SIGPIPE beim
  Schreiber). Durch `grep … >/dev/null` ersetzt, die Builds nicht wiederholt.
- Die Rohdatei des ausgelieferten Native-Kafka-Laufs mit History ist nach 1 Replica × 100 VUs kaputt (RAM-Zeile ohne
  Werte, weil der Pod weg war); für 2 und 3 Replicas gibt es dort Werte nur aus der Tabelle im README.

## Ergebnisse

Durchsatz/s · p95 ms. ⚠ = Stufe nicht verwertbar (unter 99 % korrekte Antworten oder p95 über 2 s).

### Mit History

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

### Ohne History

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

Smoke-Test vor jedem Lauf: `counter = 3` bei allen vier Läufen. Startzeiten unverändert (JVM 4–5 s, Native 2–3 s).

## Erkenntnisse

1. **Der Fix beseitigt den Einbruch vollständig.** Mit Fix keine Stufe unter 99 % korrekten Antworten, kein p95 über
   0,5 s, kein Neustart. Wie ausgeliefert waren 14 von 48 Stufen nicht verwertbar.
2. **Der Speicher bleibt flach, auch im Native-Image.** Native Kafka mit Fix höchstens 330 MiB pro Pod (ausgeliefert
   bis 1.941 MiB), JVM Kafka höchstens 326 MiB (ausgeliefert bis 1.702 MiB). Damit ist auch belegt, dass die
   korrigierte Klasse im Native-Image wirkt; geprüft nur über das Verhalten, nicht über den Inhalt des Images.
3. **Mit History ändert sich unterhalb der Einbruchsgrenze wenig.** Bei 10–50 VUs liegen beide Fassungen nahe
   beieinander (Streuung ±15 %), weil das Warten auf die Kafka-Bestätigung der Prozess-Events (≈ 100–130 ms pro
   Request) den Takt vorgibt, nicht die Persistenz. Der Fix zählt dort erst ab 100 VUs (JVM 23 → 516/s, Native
   10 % → 100 % korrekt).
4. **Ohne History werden die Kafka-Varianten mit Fix zu den schnellsten Kogito-Varianten bei 1 Replica.** JVM Kafka
   bis 2.370/s, Native Kafka bis 1.628/s mit 1 Pod; Kogito JVM mit JDBC lag ohne History bei höchstens 1.863/s. Mit
   2 Replicas bis 3.934/s (JVM) bzw. 2.947/s (Native).
5. **Mehr Replicas helfen der Kafka-Persistenz nur begrenzt.** JVM Kafka ohne History bei 100 VUs: 2.260 → 3.934 →
   2.556/s mit 1/2/3 Pods. Passt zur GlobalKTable: Jede Replica liest das ganze Topic `kogito.process` in ihren
   eigenen Store, die Arbeit verteilt sich nicht. Warum 3 Pods langsamer sind als 2, ist nicht geprüft.
6. **Ausreißer nicht geprüft:** Native Kafka mit Fix und History bei 2 Replicas × 100 VUs langsamer als mit 1 Replica
   (386 gegen 507/s, p95 431 ms); ohne History tritt das nicht auf.

## Offene Punkte

- Issue und PR an Apache KIE (Texte liegen vor, warten auf Freigabe).
- Bleibt die korrigierte Klasse dauerhaft in `apps/kogito-kafka`? Dann sollten die Hauptergebnisse für die
  Kafka-Varianten in beiden Fassungen gezeigt werden (so jetzt im README).
