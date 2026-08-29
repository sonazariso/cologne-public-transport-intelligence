USE CologneTransitIntelligence;
GO

/* Create non-unique indexes only after the initial bulk load. */

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsAgency') AND name = N'IX_GtfsAgency_AgencyId')
    CREATE INDEX IX_GtfsAgency_AgencyId ON stg.GtfsAgency (AgencyId);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsRoutes') AND name = N'IX_GtfsRoutes_RouteId')
    CREATE INDEX IX_GtfsRoutes_RouteId ON stg.GtfsRoutes (RouteId) INCLUDE (AgencyId, RouteType, RouteShortName);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsTrips') AND name = N'IX_GtfsTrips_TripId')
    CREATE INDEX IX_GtfsTrips_TripId ON stg.GtfsTrips (TripId) INCLUDE (RouteId, ServiceId, ShapeId);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsTrips') AND name = N'IX_GtfsTrips_RouteId')
    CREATE INDEX IX_GtfsTrips_RouteId ON stg.GtfsTrips (RouteId) INCLUDE (TripId);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsStops') AND name = N'IX_GtfsStops_StopId')
    CREATE INDEX IX_GtfsStops_StopId ON stg.GtfsStops (StopId) INCLUDE (StopName, LocationType, ParentStation);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsStopTimes') AND name = N'IX_GtfsStopTimes_TripId')
    CREATE INDEX IX_GtfsStopTimes_TripId ON stg.GtfsStopTimes (TripId) INCLUDE (StopId, StopSequence);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsStopTimes') AND name = N'IX_GtfsStopTimes_StopId')
    CREATE INDEX IX_GtfsStopTimes_StopId ON stg.GtfsStopTimes (StopId) INCLUDE (TripId);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsCalendar') AND name = N'IX_GtfsCalendar_ServiceId')
    CREATE INDEX IX_GtfsCalendar_ServiceId ON stg.GtfsCalendar (ServiceId);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsCalendarDates') AND name = N'IX_GtfsCalendarDates_ServiceId')
    CREATE INDEX IX_GtfsCalendarDates_ServiceId ON stg.GtfsCalendarDates (ServiceId, ServiceDate);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.GtfsShapes') AND name = N'IX_GtfsShapes_ShapeId')
    CREATE INDEX IX_GtfsShapes_ShapeId ON stg.GtfsShapes (ShapeId, ShapePtSequence);
GO
