# Realtime Monitoring — Approved 50-Station Baseline

Status: APPROVED

Roadmap Item:
2 — Register Final 50 as official baseline

Source analysis:
sql/05-analytics/06-analyze-realtime-monitoring-candidates.sql

Source analysis SHA256:
14a66e7d2ba1dd44c9a36a1dbb61ade3e7fed253d1e17722904624486e1bdf92

Station count:
50

Tier A:
10 stations — proposed 10-minute interval

Tier B:
20 stations — proposed 15-minute interval

Tier C:
20 stations — proposed 30-minute interval

**Planning baseline status:** The intervals documented here are APPROVED PLANNING BASELINE VALUES. They are NOT yet active Collector configuration.

Roadmap Item 1 selected and validated these 50 stations using the approved read-only station-scoring analysis.

This document freezes that approved result so later Collector, compatibility-testing, configuration, analytics and Power BI work all use the same station population.

Registration of the baseline does NOT activate the stations and does NOT modify realtime collection.

| Rank | ParentStationId | ParentStationName | Tier | Sampling Interval |
| ---: | --- | --- | --- | --- |
| 1 | de:05315:19201 | Köln Bf Mülheim | Tier A | 10 min |
| 2 | de:05315:11110 | Köln Heumarkt | Tier A | 10 min |
| 3 | de:05315:11212 | Köln Breslauer Platz/Hbf | Tier A | 10 min |
| 4 | de:05315:19211 | Köln Mülheim Wiener Platz | Tier A | 10 min |
| 5 | de:05315:11201 | Köln Hbf | Tier A | 10 min |
| 6 | de:05315:11901 | Köln Messe/Deutz Bf | Tier A | 10 min |
| 7 | de:05315:14201 | Köln Bf Ehrenfeld | Tier A | 10 min |
| 8 | de:05315:17701 | Köln Wahn S-Bahn | Tier A | 10 min |
| 9 | de:05315:11801 | Köln Hansaring | Tier A | 10 min |
| 10 | de:05315:13701 | Köln Bf Lövenich | Tier A | 10 min |
| 11 | de:05315:16101 | Köln Chorweiler | Tier B | 15 min |
| 12 | de:05315:19614 | Köln Leuchterstr. | Tier B | 15 min |
| 13 | de:05315:19711 | Köln Keupstr. | Tier B | 15 min |
| 14 | de:05315:15201 | Köln Geldernstr./Parkgürtel | Tier B | 15 min |
| 15 | de:05315:19713 | Köln Mülheim Berliner Str. | Tier B | 15 min |
| 16 | de:05315:17301 | Köln Bf Porz | Tier B | 15 min |
| 17 | de:05315:13708 | Köln Weiden Zentrum | Tier B | 15 min |
| 18 | de:05315:14611 | Köln Bocklemünd | Tier B | 15 min |
| 19 | de:05315:13702 | Köln Weiden West | Tier B | 15 min |
| 20 | de:05315:11511 | Köln Barbarossaplatz | Tier B | 15 min |
| 21 | de:05315:13213 | Köln Berrenrather Str./Gürtel | Tier B | 15 min |
| 22 | de:05315:11513 | Köln Süd Bf | Tier B | 15 min |
| 23 | de:05315:19501 | Köln Dellbrück S-Bahn | Tier B | 15 min |
| 24 | de:05315:15501 | Köln Longerich S-Bahn | Tier B | 15 min |
| 25 | de:05315:19801 | Köln Stammheim S-Bahn | Tier B | 15 min |
| 26 | de:05315:16601 | Köln Worringen S-Bahn | Tier B | 15 min |
| 27 | de:05315:19511 | Köln Dellbrück Hauptstr. | Tier B | 15 min |
| 28 | de:05315:18001 | Köln Trimbornstr. | Tier B | 15 min |
| 29 | de:05315:13111 | Köln Weißhausstr. | Tier B | 15 min |
| 30 | de:05315:19851 | Köln Stammheimer Ring | Tier B | 15 min |
| 31 | de:05315:13501 | Köln Müngersdorf Technologiepark S-Bahn | Tier C | 30 min |
| 32 | de:05315:15001 | Köln Nippes S-Bahn | Tier C | 30 min |
| 33 | de:05315:19101 | Köln Buchforst S-Bahn | Tier C | 30 min |
| 34 | de:05315:11111 | Köln Neumarkt | Tier C | 30 min |
| 35 | de:05315:19233 | Köln Danzierstr. | Tier C | 30 min |
| 36 | de:05315:18401 | Köln Frankfurter Str. | Tier C | 30 min |
| 37 | de:05315:11907 | Köln Bf Deutz/Messe LANXESS arena | Tier C | 30 min |
| 38 | de:05315:12552 | Köln Meschenich Kirche | Tier C | 30 min |
| 39 | de:05315:11411 | Köln Chlodwigplatz | Tier C | 30 min |
| 40 | de:05315:11710 | Köln Friesenplatz | Tier C | 30 min |
| 41 | de:05315:11810 | Köln Ebertplatz | Tier C | 30 min |
| 42 | de:05315:14211 | Köln Venloer Str./Gürtel | Tier C | 30 min |
| 43 | de:05315:11610 | Köln Rudolfplatz | Tier C | 30 min |
| 44 | de:05315:17311 | Köln Porz Markt | Tier C | 30 min |
| 45 | de:05315:13411 | Köln Aachener Str./Gürtel | Tier C | 30 min |
| 46 | de:05315:15011 | Köln Neusser Str./Gürtel | Tier C | 30 min |
| 47 | de:05315:11311 | Köln Severinstr. | Tier C | 30 min |
| 48 | de:05315:19613 | Köln Am Emberg | Tier C | 30 min |
| 49 | de:05315:12711 | Köln Rodenkirchen Bf | Tier C | 30 min |
| 50 | de:05315:15511 | Köln Longericher Str. | Tier C | 30 min |

The 50 stations above define the approved future realtime-monitoring panel. They are not activated by this document. The currently active Collector configuration remains unchanged until the dedicated configuration rollout roadmap item.

## Approved Tier Rules

- Ranks 1–10: Tier A — 10-minute proposed interval
- Ranks 11–30: Tier B — 15-minute proposed interval
- Ranks 31–50: Tier C — 30-minute proposed interval

## Baseline Change Control

Future changes to station membership, station rank, Tier, or sampling interval must be intentional and reviewed separately.

Later Collector/configuration work must consume this baseline rather than silently recomputing or replacing it.
