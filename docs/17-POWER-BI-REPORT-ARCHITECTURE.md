# Power BI Report Architecture

## Report page inventory and order

```text
00 - Template
01 - Executive Overview
02 - Reliability
03 - Routes & Lines
04 - Stations & Stops
05 - Time Analysis
06 - Data Quality & Collector Health
07 - Situation & Platform Evidence
08 - Methodology
90 - Legacy QA - Model & Reliability
91 - Legacy QA - Evidence & Consolidation
92 - Legacy QA - Data Quality & Collector
```

`00 - Template` is the authoritative Design System / Component Library reference page. Pages `01` through `08` are the final portfolio report architecture. Pages `90` through `92` preserve earlier validation/prototype evidence and are not final analytical report pages.

## Common page convention

```text
Canvas: 1280 x 720
Display mode: FitToPage

Title:
X=32
Y=24
W=1216
H=58

Subtitle:
X=32
Y=90
W=1216
H=36

Main analytical content begins approximately at:
Y=150
```

## Page purposes

### 01 - Executive Overview

Top-level portfolio overview combining static network context with validated realtime Sampling Panel evidence.

### 02 - Reliability

Analysis of continuous Observed Estimated Delay metrics such as average, median and P95.

### 03 - Routes & Lines

Future comparison of scheduled service context and observed reliability by mode and route.

### 04 - Stations & Stops

Future Parent Station and Stop Position reliability analysis for sampled locations.

### 05 - Time Analysis

Future analysis by Service Date, weekday and time of day.

### 06 - Data Quality & Collector Health

Matching quality, coverage, consolidation quality and Collector health.

### 07 - Situation & Platform Evidence

Contextual situation associations and platform evidence without claiming causality.

### 08 - Methodology

Data sources, matching methodology, consolidation, Sampling Panel scope, metric definitions and analytical limitations.

## Future analytical layout zones

Future pages may use the approved Design System components for:

```text
KPI summary zone
Primary analysis zone
Secondary analysis/detail zone
Filter/context zone
Scope/methodology note zone
```

These analytical visuals are not created as part of this corrective task.

## Future Chat mapping

```text
01 Executive Overview
→ Chat 08

02 Reliability
→ Chat 09

03 Routes & Lines
→ Chat 10

04 Stations & Stops
→ Chat 11

05 Time Analysis
→ Chat 12

06 Data Quality & Collector Health
→ Chat 13

07 Situation & Platform Evidence
→ Chat 14

08 Methodology
→ Chat 15
```

Report-wide navigation, Sync Slicers, Drill-through, Bookmarks and interaction behavior belong to **Chat 16**, not Chat 07.

## Semantic guardrails

```text
Observed Estimated Delay != Actual Delay

Do not invent an On-Time threshold.

Situation Evidence does not prove causality.

Platform Unknown != Platform Unchanged.

StaticCoverageMissing and Unresolved remain Data Quality states.

Do not invent cancellation or departure KPIs.

The seven realtime locations are a Sampling Panel,
not full Cologne realtime network coverage.
```
