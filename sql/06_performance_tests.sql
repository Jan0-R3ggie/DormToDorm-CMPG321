/* =====================================================================
   CMPG321 2026 - Group 36 (DormToDorm) - Phase 2
   Script 06: Query optimisation evidence. Each test runs the same logical
   query twice - once forced onto the base table (no supporting index /
   non-SARGable predicate) and once as designed - and reports logical reads.
   ===================================================================== */
USE DormToDorm_RideDB;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

PRINT '=== T1a: one rider''s ordered trip history - forced clustered scan';
SELECT trip_id, request_timestamp, payment_method_id, trip_status
FROM ride.trip WITH (INDEX(pk_trip))
WHERE rider_id = 'R001248'
ORDER BY request_timestamp;
GO
PRINT '=== T1b: same query - seek on ix_trip_rider_time (already in order, no sort)';
SELECT trip_id, request_timestamp, payment_method_id, trip_status
FROM ride.trip
WHERE rider_id = 'R001248'
ORDER BY request_timestamp;
GO

PRINT '=== T2a: surge-friction cancellations per zone - forced clustered scan';
SELECT pickup_zone_id, COUNT(*) AS cancels
FROM ride.trip WITH (INDEX(pk_trip))
WHERE trip_status = 'Cancelled by Rider' AND cancellation_reason_id = 1
GROUP BY pickup_zone_id;
GO
PRINT '=== T2b: same query - filtered index ix_trip_not_completed';
SELECT pickup_zone_id, COUNT(*) AS cancels
FROM ride.trip
WHERE trip_status = 'Cancelled by Rider' AND cancellation_reason_id = 1
GROUP BY pickup_zone_id;
GO

PRINT '=== T3a: fare component totals - forced row-store clustered index';
SELECT payment_status, SUM(gross_fare_zar), SUM(tip_amount_zar), SUM(promo_discount_zar), SUM(surge_premium_zar)
FROM ride.trip_fare WITH (INDEX(pk_trip_fare))
GROUP BY payment_status;
GO
PRINT '=== T3b: same query - non-clustered columnstore (batch mode)';
SELECT payment_status, SUM(gross_fare_zar), SUM(tip_amount_zar), SUM(promo_discount_zar), SUM(surge_premium_zar)
FROM ride.trip_fare
GROUP BY payment_status;
GO

PRINT '=== T4a: requests in the 17:00 hour on Wednesdays - non-SARGable functions on the timestamp';
SELECT COUNT(*) FROM ride.trip
WHERE DATEPART(HOUR, request_timestamp) = 17
  AND DATEDIFF(DAY, CONVERT(DATETIME2(0), '19000101', 112), request_timestamp) % 7 = 2;
GO
PRINT '=== T4b: same predicate on the persisted computed columns - seek on ix_trip_calendar';
SELECT COUNT(*) FROM ride.trip
WHERE hour_of_day = 17 AND day_of_week_no = 3;
GO
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
