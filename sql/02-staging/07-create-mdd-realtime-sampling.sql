USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Persistent deterministic MDD/TRIAS realtime sampling configuration.

    The target identity is deliberately the current static warehouse
    StopId.  The selected values are parent-station StopPointRefs, matching
    the already validated Köln Hbf collection convention.  A parent request
    returns the source stop-event observations for that interchange while
    keeping one logical TRIAS request per scheduled Collector execution.

    SamplingSlot is the fixed, auditable rotation.  A target may appear in
    more than one slot to receive a higher sampling frequency.
*/
IF OBJECT_ID(N'ctl.MddRealtimeSamplingTarget', N'U') IS NULL
BEGIN
    CREATE TABLE ctl.MddRealtimeSamplingTarget
    (
        SamplingTargetId INT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_ctl_MddRealtimeSamplingTarget PRIMARY KEY,
        StopPointRef NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL,
        TargetName NVARCHAR(200) NOT NULL,
        NumberOfResults TINYINT NOT NULL
            CONSTRAINT DF_ctl_MddRealtimeSamplingTarget_NumberOfResults DEFAULT (5),
        IsEnabled BIT NOT NULL
            CONSTRAINT DF_ctl_MddRealtimeSamplingTarget_IsEnabled DEFAULT (1),
        Notes NVARCHAR(1000) NULL,
        CreatedAtUtc DATETIME2(0) NOT NULL
            CONSTRAINT DF_ctl_MddRealtimeSamplingTarget_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_ctl_MddRealtimeSamplingTarget_NumberOfResults
            CHECK (NumberOfResults BETWEEN 1 AND 100)
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'ctl.MddRealtimeSamplingTarget')
      AND name = N'UX_ctl_MddRealtimeSamplingTarget_StopPointRef'
)
BEGIN
    CREATE UNIQUE INDEX UX_ctl_MddRealtimeSamplingTarget_StopPointRef
        ON ctl.MddRealtimeSamplingTarget (StopPointRef);
END;
GO

IF OBJECT_ID(N'ctl.MddRealtimeSamplingSlot', N'U') IS NULL
BEGIN
    CREATE TABLE ctl.MddRealtimeSamplingSlot
    (
        SamplingSlot SMALLINT NOT NULL
            CONSTRAINT PK_ctl_MddRealtimeSamplingSlot PRIMARY KEY,
        SamplingTargetId INT NOT NULL,
        CONSTRAINT FK_ctl_MddRealtimeSamplingSlot_Target
            FOREIGN KEY (SamplingTargetId)
            REFERENCES ctl.MddRealtimeSamplingTarget (SamplingTargetId),
        CONSTRAINT CK_ctl_MddRealtimeSamplingSlot_Positive
            CHECK (SamplingSlot > 0)
    );
END;
GO

CREATE OR ALTER PROCEDURE ctl.uspGetMddRealtimeSamplingTarget
    @AtUtc DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @AtUtc IS NULL
    BEGIN
        SET @AtUtc = CONVERT(DATETIME2(0), SYSUTCDATETIME());
    END;
    ELSE
    BEGIN
        SET @AtUtc = CONVERT(DATETIME2(0), @AtUtc);
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM ctl.MddRealtimeSamplingSlot AS sampling_slot
        INNER JOIN ctl.MddRealtimeSamplingTarget AS sampling_target
            ON sampling_target.SamplingTargetId = sampling_slot.SamplingTargetId
        WHERE sampling_target.IsEnabled = 1
    )
    BEGIN
        THROW 51001, 'No enabled MDD realtime sampling slots are configured.', 1;
    END;

    DECLARE @EpochUtc DATETIME2(0) = CONVERT(DATETIME2(0), '19700101');
    DECLARE @BucketStartUtc DATETIME2(0) = DATEADD
    (
        MINUTE,
        (DATEDIFF(MINUTE, @EpochUtc, @AtUtc) / 5) * 5,
        @EpochUtc
    );
    DECLARE @BucketNumber BIGINT = DATEDIFF_BIG(MINUTE, @EpochUtc, @BucketStartUtc) / 5;

    ;WITH EnabledSlots AS
    (
        SELECT
            sampling_slot.SamplingSlot,
            sampling_slot.SamplingTargetId,
            sampling_target.StopPointRef,
            sampling_target.TargetName,
            sampling_target.NumberOfResults,
            sampling_target.Notes,
            ROW_NUMBER() OVER (ORDER BY sampling_slot.SamplingSlot) AS SlotOrdinal,
            COUNT_BIG(*) OVER () AS EnabledSlotCount
        FROM ctl.MddRealtimeSamplingSlot AS sampling_slot
        INNER JOIN ctl.MddRealtimeSamplingTarget AS sampling_target
            ON sampling_target.SamplingTargetId = sampling_slot.SamplingTargetId
        WHERE sampling_target.IsEnabled = 1
    )
    SELECT TOP (1)
        @AtUtc AS RequestedAtUtc,
        @BucketStartUtc AS SamplingBucketUtc,
        @BucketNumber AS SamplingBucketNumber,
        SamplingSlot,
        EnabledSlotCount AS SamplingSlotCount,
        SamplingTargetId,
        StopPointRef,
        TargetName,
        NumberOfResults,
        Notes
    FROM EnabledSlots
    WHERE SlotOrdinal = (@BucketNumber % EnabledSlotCount) + 1
    ORDER BY SamplingSlot;
END;
GO

/*
    Reproducible seed derived from the current dw.DimStop and scheduled-stop
    coverage inspection.  The target rows use current parent-station StopIds;
    no display-name-only or invented MDD mapping is stored.

    Slots 1-10 form a 50-minute cycle at the existing five-minute cadence:

        1 Hbf, 2 Mülheim, 3 Heumarkt, 4 Ehrenfeld, 5 Porz Markt,
        6 Hbf, 7 Mülheim, 8 Heumarkt, 9 Worringen, 10 Rodenkirchen.

    Hbf, Mülheim, and Heumarkt receive two slots because they are high-value
    multimodal interchanges with broad scheduled route/mode coverage.
*/
BEGIN TRANSACTION;

DECLARE @SeedTarget TABLE
(
    StopPointRef NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL PRIMARY KEY,
    TargetName NVARCHAR(200) NOT NULL,
    NumberOfResults TINYINT NOT NULL,
    IsEnabled BIT NOT NULL,
    Notes NVARCHAR(1000) NULL
);

INSERT INTO @SeedTarget
(
    StopPointRef,
    TargetName,
    NumberOfResults,
    IsEnabled,
    Notes
)
VALUES
(
    N'de:05315:11201',
    N'Köln Hbf',
    5,
    1,
    N'Central rail reference; current static coverage includes S-Bahn, Regional Express (RE), and Regional Bahn (RB). The parent StopPointRef is the existing validated Collector convention.'
),
(
    N'de:05315:19201',
    N'Köln Bf Mülheim',
    5,
    1,
    N'East Cologne multimodal interchange; current static coverage includes Stadtbahn / Tram, S-Bahn, RE, RB, and Urban Bus (KVB), with high scheduled service volume.'
),
(
    N'de:05315:14201',
    N'Köln Bf Ehrenfeld',
    5,
    1,
    N'West Cologne rail/bus interchange; current static coverage includes S-Bahn, RE, RB, and Urban Bus (KVB), adding distinct western geography.'
),
(
    N'de:05315:11110',
    N'Köln Heumarkt',
    5,
    1,
    N'Inner-city surface and central bus interchange; current static coverage includes Stadtbahn / Tram, Urban Bus (KVB), and Regional / Other Bus.'
),
(
    N'de:05315:17311',
    N'Köln Porz Markt',
    5,
    1,
    N'Southeast Cologne urban interchange; current static coverage includes Stadtbahn / Tram and Urban Bus (KVB), extending beyond railway hubs.'
),
(
    N'de:05315:16601',
    N'Köln Worringen S-Bahn',
    5,
    1,
    N'North Cologne edge target; current static coverage includes S-Bahn, Regional / Other Bus, and Urban Bus (KVB). SEV presence is treated as opportunistic, not a selection requirement.'
),
(
    N'de:05315:12711',
    N'Köln Rodenkirchen Bf',
    5,
    1,
    N'South/southwest Cologne urban interchange; current static coverage includes Stadtbahn / Tram and Urban Bus (KVB), adding geographic diversity.'
);

UPDATE sampling_target
SET
    TargetName = seed.TargetName,
    NumberOfResults = seed.NumberOfResults,
    IsEnabled = seed.IsEnabled,
    Notes = seed.Notes
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
INNER JOIN @SeedTarget AS seed
    ON seed.StopPointRef = sampling_target.StopPointRef;

INSERT INTO ctl.MddRealtimeSamplingTarget
(
    StopPointRef,
    TargetName,
    NumberOfResults,
    IsEnabled,
    Notes
)
SELECT
    seed.StopPointRef,
    seed.TargetName,
    seed.NumberOfResults,
    seed.IsEnabled,
    seed.Notes
FROM @SeedTarget AS seed
WHERE NOT EXISTS
(
    SELECT 1
    FROM ctl.MddRealtimeSamplingTarget AS sampling_target
    WHERE sampling_target.StopPointRef = seed.StopPointRef
);

DELETE FROM ctl.MddRealtimeSamplingSlot;

DECLARE @SeedSlot TABLE
(
    SamplingSlot SMALLINT NOT NULL PRIMARY KEY,
    StopPointRef NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
);

INSERT INTO @SeedSlot
(
    SamplingSlot,
    StopPointRef
)
VALUES
    (1, N'de:05315:11201'),
    (2, N'de:05315:19201'),
    (3, N'de:05315:11110'),
    (4, N'de:05315:14201'),
    (5, N'de:05315:17311'),
    (6, N'de:05315:11201'),
    (7, N'de:05315:19201'),
    (8, N'de:05315:11110'),
    (9, N'de:05315:16601'),
    (10, N'de:05315:12711');

INSERT INTO ctl.MddRealtimeSamplingSlot
(
    SamplingSlot,
    SamplingTargetId
)
SELECT
    seed_slot.SamplingSlot,
    sampling_target.SamplingTargetId
FROM @SeedSlot AS seed_slot
INNER JOIN ctl.MddRealtimeSamplingTarget AS sampling_target
    ON sampling_target.StopPointRef = seed_slot.StopPointRef;

UPDATE sampling_target
SET IsEnabled = 0
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
WHERE NOT EXISTS
(
    SELECT 1
    FROM @SeedTarget AS seed
    WHERE seed.StopPointRef = sampling_target.StopPointRef
);

COMMIT TRANSACTION;
GO
