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

The project is currently in the **static GTFS ingestion stage**. A current VRS GTFS feed has been downloaded and profiled, confirming substantial multimodal coverage for Cologne across tram/light rail, rail, and bus services. The initial SQL Server database, raw staging, bulk-load, indexing, and validation scripts are now defined but have not yet been executed against the target SQL Server instance.

Realtime ingestion, transformation models, the analytical warehouse, and Power BI dashboards have not yet been completed.

## Documentation

- [Project Definition](docs/PROJECT_DEFINITION.md)
- [Initial VRS GTFS Data Profile](docs/01_VRS_GTFS_DATA_PROFILE.md)
- [SQL Server Implementation Guide](sql/README.md)
