-- Inbound: DTW flight-driven demand signal for Plum Market (Gate A36).
-- Separate database from PlumDemo (the Grocery Demand Engine project) —
-- different data domain, no shared tables, kept isolated on purpose.

IF DB_ID(N'Inbound') IS NULL
BEGIN
    CREATE DATABASE Inbound;
END
GO
