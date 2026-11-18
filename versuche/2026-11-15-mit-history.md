# Versuch: Szenario A mit voller History

**Datum:** 15./16.11.2026 – 5 Engines 16.11. 00:01–03:51, die 4 Kogito-Quarkus-Varianten nach einer Korrektur am
16.11. 10:09–12:15 nachgemessen · **Befehl:** `./scenario-a.sh --db-cpu 4 --replicas 1,2,3 <9 Engines>`
(`--history full` ist Standard) · **Rohdaten:** [results/history-full/](../results/history-full/) ·
**Folgeversuch:** [ohne History](2026-11-16-ohne-history.md)

## Frage

Wie schnell sind die 9 Engines bei gleichem Speicherumfang? Ziel war eine vollständige Spur: Jede
Variablen-Änderung wird einzeln festgehalten, so wie Kogito es mit seinen Prozess-Events tut. Gemessen werden
Durchsatz, p95, Skalierung mit 1/2/3 Replicas, Startzeit und RAM.

## Aufbau

Kafgres (Postgres 16 + Kafka-Protokoll) 4 CPU / 2 GB, jeder Engine-Pod 1 CPU / 2 GB (Request = Limit), Replicas
1/2/3, k6 mit 10/25/50/100 VUs, je 60 s Aufwärmen + 60 s Messung, jede Replica-Stufe auf leerer Datenbank. Alles
auf einem MacBook (M1 Max, Docker Desktop 8 CPU / 32 GB), am Netzteil mit `caffeinate`.

| Was festgehalten wird | CIB seven, Operaton (`full`) | Flowable (`full`) | Kogito (Prozess-Events) | Camunda 8 (RDBMS-Exporter) |
|---|---|---|---|---|
| Prozess Start/Ende | 1 Zeile `act_hi_procinst` | 1 Zeile | 2 Status-Events | Zeile in `PROCESS_INSTANCE` |
| Durchlaufene Knoten | 5 Zeilen `act_hi_actinst` | 9 Zeilen (inkl. Sequenzflüsse) | 10 Knoten-Events | Zeilen in `FLOW_NODE_INSTANCE` |
| Jede Variablen-Änderung einzeln | 4 Zeilen `act_hi_detail` | 4 Zeilen `act_hi_detail` | 4 Variablen-Events | **nein**, nur der letzte Wert |
| Speicherweg | SQL, synchron | SQL, synchron | Kafka (Kafgres); Quarkus wartet auf die Bestätigung, Spring Boot nicht geprüft | SQL, asynchron |

Camunda 8 kann mit offiziellen Mitteln keine einzelnen Änderungen speichern; Details in der README (Offenlegung).

## Was vorher schiefging

- **Erster Lauf mit Kafgres auf 2 CPU und Replicas 1/2/4 – verworfen.** CIB seven und Operaton kamen ab 2 Replicas
  nicht über ca. 730–950/s hinaus. Diagnose bei 4 Replicas × 50 VUs: Kafgres 1.985–1.992m von 2.000m CPU,
  Engine-Pods nur 330–500m. Wartegründe ≈ 62 % `LWLock: BufferContent`, ≈ 20 % CPU, ≈ 12 % WAL, 0 Zeilensperren:
  zu viel Schreibarbeit für 2 Kerne. Deshalb Kafgres auf 4 CPU und, damit es in 8 CPU passt, Replicas 1/2/3.
- **Kogito Quarkus fiel unter Last aus** (0 % korrekt, Hänger bis 60 s, zehntausende schnelle Fehler pro Sekunde).
  - Erster Verdacht: SmallRye-Producer mit `acks=1` ohne Idempotenz; Kafgres beantwortete manche Schreibanfragen
    nie. Auf `acks=all` + Idempotenz umgestellt – **das reichte nicht**, der nächste volle Lauf zeigte dieselben
    Ausfälle (der Kurztest mit 1 Replica und zwei Laststufen war zu kurz).
  - Eigentliche Ursache: Kogitos `ReactiveMessageEmitter` puffert Events ohne Grenze im Heap („abschicken und
    vergessen“). Heap 24 → 494 MB in 80 s, wartende Nachrichten 38.856 → 291.143 in 40 s, danach nur noch Full GCs.
    Keine Pod-Neustarts, kein OOMKilled.
  - Abhilfe: `kogito.events.processinstances.errors.propagate=true` (blockierender Versand). Die 4 Quarkus-Varianten
    wurden damit nachgemessen; die Werte unten stammen aus dieser Nachmessung.
- Ein Lauf im Akkubetrieb wurde ungültig (Ruhezustand), seitdem Abbruch ohne Netzteil. 15 s Aufwärmen waren für
  frische JVMs zu kurz, jetzt 60 s.

## Ergebnisse

⚠ = nicht verwertbar (unter 99 % korrekte Antworten oder p95 über 2 s).

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

Start = bis der erste Pod bereit ist, Scale-out = bis ein weiterer Pod bereit ist. Camunda 8 startet alle Broker
gleichzeitig, die Startwerte gelten für 1/2/3 Broker. Bei Kogito Native Kafka fehlt der RAM-Wert für
1 Replica × 100 VUs (`kubectl top` lieferte nichts).

**Bester gültiger Durchsatz/s je Replica-Stufe**

| Engine | 1 Replica | 2 Replicas | 3 Replicas | Faktor 1→3 |
|---|---:|---:|---:|---:|
| Flowable | 631 | 1.301 | 1.904 | 3,0× |
| Kogito SB | 750 | 1.152 | 2.210 | 2,9× |
| Camunda 8 | 291 | 516 | 768 | 2,6× |
| Operaton | 782 | 1.464 | 1.630 | 2,1× |
| CIB seven | 816 | 1.641 | 1.630 | 2,0× |
| Kogito Native | 256 | 555 | 522 | 2,0× |
| Kogito JVM | 352 | 423 | 634 | 1,8× |
| Kogito Native Kafka | 349 | 617 | 546 | 1,6× |
| Kogito JVM Kafka | 483 | 577 | 428 | 0,9× |

## Erkenntnisse

1. **CIB seven und Operaton hängen an der Datenbank.** Beide fast gleichauf, deutlicher Zuwachs nur bis 2 Replicas.
   Ursache der Schreibarbeit: Die Removal Time der History-Bereinigung (Standard-Strategie `end`) setzt am
   Prozessende per `UPDATE` die Löschzeit in 15 History-Tabellen – jede History-Zeile wird eingefügt und gleich
   wieder geändert. Standard belassen; `history-removal-time-strategy: start` würde das vermeiden (nicht gemessen).
   Dass bei 4 CPU wieder die Datenbank die Grenze ist, bestätigt erst der Folgeversuch ohne History (dort doppelt
   so schnell und weiter skalierend).
2. **Flowable skaliert fast linear** (631 → 1.301 → 1.904/s) und liegt mit 3 Replicas vor CIB seven und Operaton,
   obwohl es mehr History-Zeilen schreibt (15 statt 11, aber ohne nachträgliche UPDATEs). Bei 1 Replica ist es
   die langsamste der drei.
3. **Kogito SB hat den Höchstwert des Laufs** (2.210/s bei 3 Replicas × 50 VUs), fällt bei 100 VUs aber auf
   1.348/s zurück (nicht geprüft, warum). RAM unter Last bis 595 MiB.
4. **Kogito Quarkus ist stabil, aber an die Kafka-Bestätigung gebunden.** Mit blockierendem Versand bei 10 VUs nur
   64–79/s (≈ 130 ms pro Request), egal ob 1, 2 oder 3 Replicas; der Durchsatz steigt mit den VUs, nicht mit den
   Replicas. Die Werte zeigen vor allem, wie schnell Kafgres Kafka-Schreibanfragen bestätigt. Warum das so lange
   dauert, ist nicht geprüft (Kandidaten: Sammelintervall in Kafgres, `linger.ms` = 5 ms bei kafka-clients 4.0,
   nacheinander gesendete Events).
5. **Die Kafka-Varianten von Kogito fressen Speicher.** JVM Kafka bis 1.499 MiB pro Pod, Einbruch bei
   1 Replica × 100 VUs (23/s, p95 5,9 s); Native Kafka bei 1 Replica × 100 VUs nur 10 % korrekt. Ab 2 Replicas
   reicht es. Vermutlich die Kafka-Streams-Persistenz (nicht geprüft; der Folgeversuch ohne Events zeigt denselben
   Einbruch).
6. **Kogito Native startet in 2–3 s mit ≈ 20 MiB**, Kogito JVM in 4–6 s mit ≈ 150 MiB; die Spring-Boot-Engines
   brauchen 9–12 s und 190–270 MiB, Camunda 8 22–34 s und ≈ 490 MiB.
7. **Camunda 8 ist am langsamsten, skaliert aber gleichmäßig** (291 → 516 → 768/s). Bei 1 Broker × 100 VUs sind
   97 % der Antworten schnelle Fehler, vermutlich Backpressure von Zeebe (nicht geprüft). RAM unter Last
   1,6–1,97 GiB von 2 GiB, nah am Limit; Operate/Tasklist laufen im selben Pod mit.

## Offene Punkte

- Wartezeit der Kafka-Bestätigung bei Kogito Quarkus.
- Speicherwachstum der Kogito-Kafka-Varianten (Kafgres oder Kafka Streams?).
- Fehlerantworten von Camunda 8 bei 1 Broker × 100 VUs.
- Einbruch von Kogito SB bei 3 Replicas × 100 VUs.
- CIB seven/Operaton mit `history-removal-time-strategy: start` messen.
