# Versuch: Szenario B, DMN-Tabelle mit 100 Regeln

**Datum:** 17.11.2026, 09:56–14:15 · **Befehl:** `./scenario-a.sh --db-cpu 4 --replicas 1,2,3 --history full
--scenario b cibseven operaton flowable kogito-jvm kogito-jvm-kafka kogito-sb kogito-native kogito-native-kafka
camunda8` · **Rohdaten:** [results/scenario-b-history-full/](../results/scenario-b-history-full/) · **Vergleich:**
Szenario A mit History, [results/history-full/](../results/history-full/) (Protokoll
[2026-11-15-mit-history.md](2026-11-15-mit-history.md)); für die beiden Kafka-Varianten
[results/history-full-iterfix/](../results/history-full-iterfix/) (Protokoll
[2026-11-16-iterator-fix.md](2026-11-16-iterator-fix.md))

## Frage

Szenario A misst fast nur den Prozess-Overhead: drei Tasks, die einen Zähler erhöhen. Wie ändern sich Durchsatz,
Latenz und Speicher, wenn ein Prozess echte Regelarbeit macht? Gewünscht war eine „etwas kompliziertere“
DMN-Tabelle mit etwa 100 Zeilen.

## Aufbau

- Prozess `ScenarioB`: Start → Business Rule Task → Ende. Szenario A bleibt unverändert.
- Entscheidung `Pricing` mit 100 Regeln, Hit Policy **COLLECT mit Aggregation SUM**. Gewählt wurde „wie FIRST,
  aber COLLECT“: Statt beim ersten Treffer aufzuhören, wird jede Anfrage gegen alle 100 Regeln geprüft und die
  Gebühren aller Treffer werden addiert.
- Eingaben: `age` (18–99), `amount` (0–100.000), `country` (DE, AT, CH, FR, NL), `customerType` (standard, premium,
  business, student), bei jeder Anfrage zufällig.
- Regeln 1–99 zufällig mit festem Startwert 42: Bereich für Alter und Betrag, bei 60 % ein Land, bei 50 % ein
  Kundentyp, Gebühr = Regelnummer. Regel 100 greift immer (Gebühr 1.000). Ohne sie wäre die Summe bei null Treffern
  leer. Selbsttest über 10.000 Zufallsanfragen: 74 % treffen außer Regel 100 mindestens eine weitere Regel, im
  Schnitt etwa 2.
- [load/gen-pricing-dmn.py](../load/gen-pricing-dmn.py) erzeugt die Tabelle für jede Engine und dieselben Regeln als
  `load/scenario-b-rules.json`. [load/scenario-b.js](../load/scenario-b.js) rechnet daraus pro Anfrage die richtige
  Gebühr; nur genau diese zählt als korrekt.
- Testaufruf vor jeder Engine: Alter 65, Betrag 30.000, FR, business → Gebühr 1.254. Alle 9 Engines lieferten 1.254.
- Rahmen wie in Szenario A mit History: Kafgres 4 CPU / 2 GB, jeder Engine-Pod 1 CPU / 2 GB, Replicas 1/2/3,
  10/25/50/100 VUs, je 60 s Aufwärmen + 60 s Messung, jede Replica-Stufe auf leerer Datenbank. Die Kafka-Varianten
  laufen mit dem Iterator-Fix.
- Neu in den Skripten: `--scenario a|b` in `scenario-a.sh`, `SCENARIO` in `bench.sh`. Ergebnisse gehen nach
  `results/scenario-b-history-<stufe>/`, die config-Zeile hat ein Feld `scenario`.

### Pro Engine

| Engine | Tabelle | Aufruf im Prozess |
|---|---|---|
| CIB seven, Operaton | FEEL, `typeRef="integer"`, mit `camunda:historyTimeToLive="P1D"` an der Entscheidung | `camunda:decisionRef="Pricing"`, `mapDecisionResult="singleEntry"`, `resultVariable="fee"` |
| Flowable | eigener Dialekt: 6 Spalten (`>= x`, `<= y`, `== "DE"`), weil Flowable keine FEEL-Bereiche kennt | `serviceTask flowable:type="dmn"`, Feld `decisionTableReferenceKey=Pricing` |
| Kogito (alle 5) | FEEL, `typeRef="number"`, mit `inputData` und `informationRequirement` | Business Rule Task mit `implementation="http://www.jboss.org/drools/dmn"`, Ausgabe in Integer-Variable `fee` |
| Camunda 8 | FEEL, `typeRef="number"` | `zeebe:calledDecision decisionId="Pricing" resultVariable="fee"` |

Zusätzliche Abhängigkeiten: Kogito Quarkus `drools-quarkus-decisions`, Kogito SB
`drools-decisions-spring-boot-starter`, Flowable `flowable-spring-boot-starter-dmn`,
`flowable-dmn-engine-configurator` und `flowable-dmn-spring-configurator` (8.0.0). Alle Images neu gebaut; die für
Szenario A gemessenen liegen als `:1.0.0-a` daneben. Nach dem Umbau lieferte Szenario A bei allen 9 Engines weiter
`counter = 3`.

## Was beim Aufsetzen schiefging

- Kogito: Mit `BigDecimal` oder `Object` als Typ der Variable `fee` scheiterte die Codegenerierung der Persistenz
  (Protobuf). Mit `Integer` läuft es.
- Flowable: Erst `NoClassDefFoundError` für `DmnEngineConfigurator`, dann für `SpringDmnEngineConfigurator`; beide
  Module fehlten im Starter. Danach scheiterte der DMN-Parser (StAX) an einem XML-Kommentar vor dem Wurzelelement.
  Der Kommentar steht in Flowables Datei jetzt innerhalb von `<definitions>`.
- CIB seven und Operaton lehnten das Deployment ab (`ENGINE-12018`): Auch die Entscheidung braucht eine
  History-Aufbewahrungsdauer.
- Generator: Ein `<=` in einem `label`-Attribut war ungültiges XML; die Spalten heißen jetzt „age min“/„age max“.
- Der erste Testaufruf lief mit allen Engines als ein Wort, weil zsh `$E` nicht an Leerzeichen trennt. Wiederholt
  mit `bash -c`.
- Der Rechner wurde vor dem Lauf neu gestartet. Docker und der Cluster wurden neu gestartet, eine liegen gebliebene
  Flowable-Deployment gelöscht. Danach Lauf ohne Unterbrechung, am Netzteil.

## Ergebnisse

Alle Tabellen stehen im README unter „Ergebnisse Szenario B (History voll)“. Kurzfassung, bester gültiger Durchsatz
je Replica-Stufe (Anfragen/s, Szenario A → B):

| Engine | 1 Replica | 2 Replicas | 3 Replicas |
|---|---:|---:|---:|
| CIB seven | 816 → 81 | 1.641 → 193 | 1.630 → 263 |
| Operaton | 782 → 423 | 1.464 → 740 | 1.630 → 881 |
| Flowable | 631 → 345 | 1.301 → 746 | 1.904 → 1.144 |
| Kogito SB | 750 → 602 | 1.152 → 1.180 | 2.210 → 1.699 |
| Kogito JVM | 352 → 279 | 423 → 535 | 634 → 801 |
| Kogito Native | 256 → 248 | 555 → 472 | 522 → 761 |
| Kogito JVM Kafka (Fix) | 516 → 581 | 642 → 537 | 585 → 594 |
| Kogito Native Kafka (Fix) | 507 → 473 | 416 → 798 | 518 → 576 |
| Camunda 8 | 291 → 280 | 516 → 480 | 768 → 695 |

Nicht verwertbar (⚠): CIB seven 1 und 2 Replicas × 100 VUs (p95 2,5 bzw. 2,3 s); Camunda 8 1 Broker × 50 VUs (61 %
korrekt), 1 × 100 (4 %) und 2 × 100 (27 %). Die anderen 103 von 108 Stufen: 100 % korrekt, außer Camunda 8
3 × 100 mit 99,8 %.

## Erkenntnisse

1. **Alle Engines rechnen die Tabelle richtig.** In den gültigen Stufen kamen rund 3 Millionen gemessene
   Zufallsanfragen mit der richtigen Gebühr zurück, über drei DMN-Dialekte. Die wenigen falschen Antworten (Camunda
   8 unter Überlast) sind keine Rechenfehler, die Ursache ist aber nicht geprüft.
2. **CIB seven bricht ein, weil seine FEEL-Engine die eingebauten Funktionen bei jedem Zellentest neu aufbaut.**
   Nachtest nach dem Lauf, 1 Replica × 25 VUs (64/s, p95 684 ms): Engine-Pod 999m von 1.000m CPU, Kafgres 252m. In
   `pg_stat_activity` nur kurze Abfragen (Entscheidungsdefinition nach Schlüssel, History-INSERTs). Java Flight
   Recorder über 40 s, 623 Stichproben: 434 im Aufruf der Entscheidung, davon 398 (64 % aller Stichproben) in
   `org.camunda.feel.FeelEngine.rootContext` → `org.camunda.feel.impl.interpreter.BuiltinFunctions.<init>`, also im
   Aufbau der Funktionstabelle (Scala-Maps, `BitmapIndexedMapNode.concat`). Das geschieht pro
   `evaluateSimpleUnaryTests`, also für jede Eingabezelle jeder geprüften Regel. Die Datenbank war nicht die Grenze.
   CIB seven 2.2.0 enthält `feel-engine-1.19.3-scala-shaded.jar`, Operaton 2.2.1 `feel-engine-1.22.1.jar`.
   Quellcode-Vergleich danach: In 1.19.3 ist `rootContext` eine Methode (`private def rootContext()`), die bei jeder
   Auswertung `new BuiltinFunctions(…)` erzeugt; in 1.22.1 ein einmal gebautes Feld (`private val rootContext`).
   Sonst ist `FeelEngine.scala` gleich. Korrigiert ab 1.19.4 und 1.20.1 (1.20.0 noch alt).
   Gegenmessung am Abend mit `feel-engine` 1.19.6 (pom-Override, Image `bench-cibseven:1.0.0-feel1196`, 1 Replica,
   Rohdaten `results/scenario-b-history-full-feel1196/`): 442 / 422 / 390 / 358 pro Sekunde bei 10 / 25 / 50 / 100
   VUs statt 81 / 73 / 76 / 78, p95 52–538 ms, alle Antworten korrekt. Damit gleichauf mit Operaton (423 / 418 /
   367 / 245). Die Ursache ist belegt: die ausgelieferte FEEL-Version.
3. **Operaton und Flowable verlieren etwa die Hälfte**, skalieren aber mit den Replicas wie in Szenario A. Woran
   die Zeit geht, ist nicht geprüft (kein Profil).
4. **Kogito verliert wenig oder gewinnt.** Mit History wartet Kogito Quarkus auf die Bestätigung jedes Events durch
   Kafgres; Szenario B hat nur einen Knoten, vermutlich also weniger Events pro Instanz (nicht gezählt). Die
   DMN-Auswertung selbst fällt daneben nicht ins Gewicht. Der Sockel bei 10 VUs (≈ 100/s, egal wie viele Pods)
   bleibt.
5. **Kogito SB ist in Szenario B die schnellste Engine** (1.699/s mit 3 Replicas, p95 23 ms), vor Flowable
   (1.144/s) und Operaton (881/s).
6. **Camunda 8 verliert kaum (4–9 %), wird aber früher ungültig:** schon bei 1 Broker × 50 VUs und bei 2 Brokern ×
   100 VUs. Die Ursache ist nicht geprüft, weil k6 nur „richtig/falsch“ speichert.
7. **Speicher:** Die DMN-Engine kostet im Leerlauf 10–25 MiB pro Pod (Kogito JVM 153 → 169 MiB), unter Last bis zu
   60 MiB. Native-Images bleiben unter 135 MiB. Camunda 8 bleibt bei 1,6–1,8 GiB unter Last.

## Offene Punkte

- Erledigt: CIB seven mit `feel-engine` 1.19.6 gegengemessen (siehe Erkenntnis 2). Offen: ggf. Issue bei CIB seven,
  die FEEL-Version anzuheben (Text vorher zeigen); 2 und 3 Replicas mit 1.19.6.
- Camunda 8: HTTP-Status der falschen Antworten aufzeichnen (Backpressure oder Fehler).
- Offen, wie viel von Operatons und Flowables Verlust auf die Tabelle und wie viel auf die History der Entscheidung
  entfällt: Szenario B ohne History messen.
