# Cologne Public Transport Intelligence
<p align="center">
  <a href="https://commons.wikimedia.org/wiki/File:K%C3%B6ln_Hohenzollernbr%C3%BCcke.jpg">
    <img src="https://commons.wikimedia.org/wiki/Special:Redirect/file/K%C3%B6ln%20Hohenzollernbr%C3%BCcke.jpg?width=1600"
         alt="Cologne Cathedral and Hohenzollern Bridge across the Rhine"
         width="100%">
  </a>
  <br>
  <sub>Cologne Cathedral and Hohenzollern Bridge · Photo: Anne Offermanns ·
    <a href="https://creativecommons.org/licenses/by-sa/4.0/">CC BY-SA 4.0</a>
  </sub>
</p>

An end-to-end analytics project for understanding the reliability and performance of multimodal public transport in Cologne, Germany.

The project will combine static **GTFS** schedules with available **realtime data** and use **SQL Server** for data integration, transformation, and analytical modeling. **Power BI** will provide decision-focused reporting on delays, disruptions, service reliability, and operational patterns across Cologne's public transport network.

## Objectives

- Integrate and validate scheduled and realtime public transport data
- Measure delays, disruptions, reliability, and service-performance trends
- Categorize recurring operational problems and assess their impact
- Support evidence-based root-cause analysis without overstating causality
- Translate analytical findings into practical decision support for managers

## Planned Technology

- SQL Server
- Power BI
- GTFS and GTFS Realtime or other available realtime sources
- Supporting data-collection and ETL components

## Project Status

The current VRS GTFS snapshot has been loaded successfully into SQL Server and validated against independently profiled source counts. The load batch is marked `Validated`, with source row counts reconciled and critical integrity checks passed.

The first transformation milestone defines a reproducible Cologne boundary and classifies Cologne-serving routes into Stadtbahn/Tram, S-Bahn, RE, RB, urban bus, regional bus, and rail-replacement service categories. The static analytical warehouse has been materialized and validated. Reporting views are prepared for a first Power BI scheduled-service baseline covering network scope, modes, routes, stops, stations, and daily planned trips.

Realtime ingestion and realtime performance facts have not yet been completed. The SQL semantic model, reviewed DAX measures, report theme, and build guide are ready for the first Power BI scheduled-baseline report.

## Documentation

Read the project documentation in this order:

1. [Project Definition](docs/01-PROJECT-DEFINITION.md)
2. [Data Sources and Initial GTFS Profile](docs/02-DATA-SOURCES-AND-GTFS-PROFILE.md)
3. [Cologne Scope and Mode Classification](docs/03-COLOGNE-SCOPE-AND-MODE-CLASSIFICATION.md)
4. [Data Architecture](docs/04-DATA-ARCHITECTURE.md)
5. [Database Design and SQL Server Implementation](docs/05-DATABASE-DESIGN-AND-SQL-IMPLEMENTATION.md)
6. [Static GTFS Analytical Warehouse Model](docs/06-STATIC-GTFS-WAREHOUSE-MODEL.md)
7. [Static Analytics and Power BI Baseline](docs/07-STATIC-ANALYTICS-AND-POWER-BI-BASELINE.md)
8. [Power BI Static Baseline Build Guide](docs/08-POWER-BI-STATIC-BASELINE-BUILD-GUIDE.md)

Component entry points remain available in the [SQL](sql/README.md), [Power BI](powerbi/README.md), and [local data](data/README.md) directories.
