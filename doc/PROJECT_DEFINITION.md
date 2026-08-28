# Cologne Public Transport Intelligence

## Project Definition

### 1. Project Goal

The goal of this project is to build an end-to-end **Data Analytics and Business Intelligence solution for public transport in Cologne (Köln), Germany**.

The project will combine scheduled and realtime public transport data to answer a central analytical question:

> **How reliable and efficient is Cologne's public transport network, where do delays and disruptions occur, what are their likely causes, and what improvements could have the greatest operational impact?**

The final solution should demonstrate practical skills in:

- SQL Server
- Data modeling
- ETL / ELT
- Data quality
- GTFS
- Realtime transport data
- Analytical SQL
- Root-cause analysis
- Power BI
- KPI design
- Data visualization
- Business recommendations
- Technical documentation

---

## 2. Geographic Scope

The primary geographic scope is:

**Köln (Cologne), Germany**

The project deliberately focuses on one city rather than attempting to analyze the entire NRW transport network.

This allows the analysis to go deeper into:

- individual routes
- stops and stations
- transport modes
- time periods
- delays
- cancellations
- disruptions
- reliability patterns
- possible causes

Düsseldorf or another NRW city may later be used as a **benchmark**, but it is not part of the initial core scope.

---

## 3. Transport Scope

The project should include the public transport modes serving Cologne that are available and sufficiently represented in the selected data sources.

Expected modes include:

```text
Regional Rail
RE

Regional Rail
RB

S-Bahn

Stadtbahn / Light Rail / Tram

Bus

Other relevant public transport modes
if present in the source data
```

The exact list must be determined from the actual GTFS data rather than assumed in advance.

---

## 4. Data Sources

### 4.1 Scheduled Transport Data

Primary scheduled data:

**GTFS**

Expected entities include:

```text
Agency
Routes
Trips
Stops
StopTimes
Calendar
CalendarDates
FeedInfo
```

GTFS will provide the foundation for analyzing:

- scheduled services
- routes
- stops
- trips
- frequency
- service calendars
- scheduled travel times
- transport modes

---

### 4.2 Deutsche Bahn Realtime Data

The **DB Timetables API** will be used where appropriate for railway realtime information.

Relevant information includes:

```text
Planned arrival
Actual/changed arrival

Planned departure
Actual/changed departure

Arrival delay
Departure delay

Cancellation

Planned platform
Changed platform

Train
Line
Station
```

The previously developed NRW project has already validated the technical feasibility of this source.

---

### 4.3 Urban Transport Realtime Data

For Bus / Stadtbahn and other urban transport services, appropriate realtime sources such as **VRS GTFS-RT** should be investigated and integrated where practical.

This should be treated as a separate source from the DB railway realtime pipeline.

---

### 4.4 Disruption Data

Where reliable data is available, additional disruption information should be considered.

Examples:

```text
Störung
Bauarbeiten
Service interruption
Station disruption
Elevator outage
Escalator outage
Platform changes
Other operational messages
```

These datasets may later contribute to root-cause analysis.

---

## 5. Main Business Questions

The project should ultimately answer questions such as:

### Network

- How large is Cologne's public transport network?
- Which transport modes operate in Cologne?
- Which routes and stops carry the largest scheduled service volume?
- How does service frequency vary throughout the day?

### Reliability

- What percentage of services operate on time?
- What is the average and median delay?
- How severe are delays?
- Which routes are least reliable?
- Which stations/stops are delay hotspots?

### Time

How does performance change by:

```text
Hour
Peak / Off-Peak
Day of Week
Weekday / Weekend
Month
```

### Transport Mode

How does reliability compare between:

```text
Rail
S-Bahn
Stadtbahn
Bus
```

### Cancellation

- Which routes experience the most cancellations?
- When do cancellations occur?
- Are cancellations concentrated at particular locations?

### Delay Propagation

Where technically possible:

- Does a train arrive late and leave even later?
- Does delay propagate through subsequent stops?
- Which services recover from delays?
- Which services accumulate delays?

### Infrastructure / Operations

Investigate relationships between:

```text
Platform changes
Construction
Operational disruptions
Station problems
Service interruptions
```

and transport performance.

---

## 6. Root-Cause Analysis

The project should go beyond displaying delay statistics.

A major objective is to identify **likely contributing factors**.

Potential categories:

```text
Construction / Bauarbeiten

Operational disruption / Störung

Upstream delay

Platform change

Infrastructure issue

Cancellation

Station-related disruption

Unknown / insufficient evidence
```

An important analytical rule:

> **Correlation must not automatically be presented as causation.**

When the available data cannot prove a cause, the dashboard/report should describe it as an association or likely contributing factor.

This makes the analysis more defensible.

---

## 7. KPIs

Candidate KPIs include:

```text
Total Scheduled Services

Observed Services

On-Time %

Average Arrival Delay

Median Arrival Delay

Average Departure Delay

P95 Delay

Delayed Services %

Severely Delayed Services %

Cancellation Rate

Platform Change Rate

Service Frequency

Average Headway

Reliability Score
```

The exact definitions and thresholds must be documented.

For example, we must explicitly define what the project considers:

```text
On Time
Minor Delay
Moderate Delay
Severe Delay
```

rather than selecting arbitrary thresholds without explanation.

---

## 8. Data Architecture

Proposed architecture:

```text
             DATA SOURCES
                  |
        +---------+---------+
        |                   |
        v                   v
      GTFS            Realtime APIs
                        DB / VRS
        |                   |
        +---------+---------+
                  |
                  v
               STAGING
                  |
                  v
            WORKING LAYER
                  |
        Cleaning / Matching
        Normalization
        Classification
                  |
                  v
           DATA WAREHOUSE
                  |
          Star Schema / Facts
                  |
                  v
          ANALYTICAL VIEWS
                  |
                  v
              POWER BI
                  |
                  v
        INSIGHTS & RECOMMENDATIONS
```

SQL Server remains the analytical database.

---

## 9. Proposed Database Layers

Keep clear separation of responsibilities:

```text
stg
```

Raw/staging source data.

```text
wrk
```

Transformation, matching, normalization and intermediate calculations.

```text
dw
```

Dimensions, facts and reporting-ready warehouse objects.

```text
cfg
```

Configuration where necessary.

This preserves useful architectural lessons from the previous NRW project.

---

## 10. Power BI Deliverable

The final project should not consist of dozens of disconnected dashboards.

A focused analytical report of approximately **5–8 strong pages** is preferable.

Potential structure:

### Page 1 — Executive Overview

Overall health of Cologne public transport.

### Page 2 — Network & Service

Routes, stops, modes and service frequency.

### Page 3 — Reliability

Delay distribution and core reliability KPIs.

### Page 4 — Delay Hotspots

Problematic routes, stops and time periods.

### Page 5 — Mode Comparison

Compare:

```text
Rail
S-Bahn
Stadtbahn
Bus
```

### Page 6 — Disruptions & Causes

Disruptions and likely contributing factors.

### Page 7 — Deep Dive

Detailed investigation of important problem areas.

### Page 8 — Recommendations

Evidence-based findings and proposed improvements.

The exact page count can change if fewer pages tell the story better.

---

## 11. Recommendations

The project must finish with actionable conclusions rather than only charts.

A recommendation should follow:

```text
Problem
   ↓
Evidence
   ↓
Likely Cause
   ↓
Operational Impact
   ↓
Recommendation
```

Recommendations must remain within what the data can reasonably support.

---

## 12. Portfolio Deliverables

The finished GitHub repository should contain at least:

```text
README.md

docs/
    PROJECT_DEFINITION.md
    DATA_SOURCES.md
    ARCHITECTURE.md
    DATA_MODEL.md
    DATA_QUALITY.md
    REALTIME_PIPELINE.md
    ANALYSIS_AND_FINDINGS.md

sql/
    staging/
    working/
    warehouse/
    analytics/

collector/
    realtime collection scripts

powerbi/
    Power BI project/report

images/
    architecture
    data model
    dashboard screenshots
```

We do **not** need to create all these documents at the beginning. Documentation should grow with the implementation.

---

## 13. Definition of Done

The project is considered **complete** when all of the following are true:

**Data**

Scheduled multimodal Cologne data is successfully modeled.

**Realtime**

Reliable realtime observations exist for the transport modes where an appropriate realtime source is available.

**Warehouse**

A validated analytical data warehouse exists.

**Quality**

Important data-quality tests have been performed and documented.

**Analysis**

Major reliability problems and patterns have been identified.

**Root Cause**

Likely causes or contributing factors have been investigated where evidence exists.

**Power BI**

A polished analytical report tells the complete story.

**Recommendations**

The project provides evidence-based recommendations.

**Documentation**

Another technical person can understand the architecture, sources, assumptions and analytical methodology from GitHub.

**Portfolio**

The project can be explained clearly in approximately **5–10 minutes during an interview**.

---

## 14. Explicit Non-Goals

To prevent scope creep, the first version will **not** attempt to:

- Analyze all NRW cities.
- Collect realtime data from every German station.
- Predict delays with machine learning.
- Build a passenger mobile application.
- Create a realtime operational control system.
- Solve route optimization.
- Build dozens of dashboards.
- Integrate every available transport API.

These can become future extensions.

---

## 15. Project Strategy

The development strategy is:

```text
Breadth:
One city

Coverage:
Multiple public transport modes

Depth:
High

Analysis:
Schedule
+
Realtime
+
Disruptions
+
Root Cause
+
Recommendations
```

The guiding principle is:

> **One city deeply analyzed is more valuable for this portfolio project than an entire region analyzed superficially.**

---

## Final Project Vision

The final portfolio should demonstrate the complete analytical journey:

**Raw public transport data → SQL data engineering → data warehouse → realtime integration → data quality → Power BI → problem discovery → root-cause investigation → actionable recommendation.**
