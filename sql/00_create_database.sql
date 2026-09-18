-- ============================================================================
-- 00_create_database.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：创建 KFC_DB；已存在时明确报错停止；校验兼容级别不低于 130；切换到 KFC_DB
-- 依赖：无，必须是全量部署的第一个脚本
-- 依据：docs/stage1-three-person-implementation-plan.md 第 1 节与全局约束
-- 说明：不使用 DROP DATABASE；对象已存在时明确报错并停止，避免覆盖已验收数据
-- ============================================================================

-- 批次 1：数据库已存在时明确报错并停止
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
IF DB_ID(N'KFC_DB') IS NOT NULL
BEGIN
    THROW 50000, N'KFC_DB 已存在：为避免覆盖已验收数据，部署停止；如需重建请人工确认后处理。', 1;
END;
GO

-- 批次 2：CREATE DATABASE 必须是独立批次（该语句不能与其他语句同批执行）
CREATE DATABASE KFC_DB;
GO

-- 批次 3：切换到 KFC_DB，并校验兼容级别（OPENJSON 要求 >= 130）
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

USE KFC_DB;
GO

DECLARE @compatibility_level INT;

SELECT @compatibility_level = compatibility_level
FROM sys.databases
WHERE name = N'KFC_DB';

IF @compatibility_level IS NULL
BEGIN
    THROW 50000, N'KFC_DB 创建后无法读取兼容级别，请检查部署权限。', 1;
END;

IF @compatibility_level < 130
BEGIN
    THROW 50000, N'KFC_DB 兼容级别低于 130，OPENJSON 不可用；请升级 SQL Server 实例后重试。', 1;
END;

PRINT N'KFC_DB 创建完成，兼容级别 = ' + CAST(@compatibility_level AS NVARCHAR(10));
GO
