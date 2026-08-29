IF XACT_STATE() <> 0
BEGIN
    ROLLBACK TRANSACTION;
END;
GO

USE master;
GO

/*
    Development-workstation configuration.

    This project rebuilds a replaceable analytical warehouse and does not use
    transaction-log backups. SIMPLE recovery allows committed log space to be
    reused between ETL batches. Production recovery policy must be decided by
    the database administrator and must not be changed by this script.
*/
IF DB_ID(N'CologneTransitIntelligence') IS NULL
BEGIN
    THROW 50020, 'Database CologneTransitIntelligence does not exist.', 1;
END;
GO

ALTER DATABASE CologneTransitIntelligence SET RECOVERY SIMPLE;
GO

USE CologneTransitIntelligence;
GO

CHECKPOINT;
GO

SELECT
    database_property.RecoveryModel,
    CONVERT(DECIMAL(12, 2), log_space.total_log_size_in_bytes / 1048576.0) AS TotalLogSizeMB,
    CONVERT(DECIMAL(12, 2), log_space.used_log_space_in_bytes / 1048576.0) AS UsedLogSizeMB,
    CONVERT(DECIMAL(6, 2), log_space.used_log_space_in_percent) AS UsedLogPercent
FROM
(
    SELECT recovery_model_desc AS RecoveryModel
    FROM sys.databases
    WHERE name = DB_NAME()
) AS database_property
CROSS JOIN sys.dm_db_log_space_usage AS log_space;
GO
